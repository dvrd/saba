package saba_core

import "base:intrinsics"
import rt "base:runtime"
import "core:log"
import "core:sync"
import "core:sys/posix"
import "core:thread"

// SIGTERM and SIGINT start a graceful drain of every running server in the
// process: listeners close, admitted requests finish, and serve returns once
// connections are gone or Server.drain_timeout has passed. The previous
// disposition is put back as soon as the first signal is seen, so a second
// signal terminates the process the ordinary way.
//
// A signal is only claimed while its disposition is the default one. A program
// that installs its own handler, or that was started with the signal ignored,
// keeps that behaviour; so does one that sets `disabled`. Such a program must
// not call drain_server or stop_server from the handler itself: both take locks
// and are not async-signal-safe. Forward the signal to a thread (a pipe, or
// sigwait) and call them there, which is what this file does.
Signal_Config :: struct {
	disabled: bool,
}

WATCHED_SIGNALS :: [2]posix.Signal{.SIGTERM, .SIGINT}

// One watch serves every server of a process. The handler only writes the
// signal number to a pipe; a thread reads it and requests the drains.
Signal_Watch :: struct {
	// Serializes start and stop of the thread; never taken by the thread.
	lifecycle:      sync.Mutex,
	// Guards the server list and the saved dispositions.
	mutex:          sync.Mutex,
	servers:        ^Server_Runtime,
	count:          int,
	reader, writer: posix.FD,
	worker:         ^thread.Thread,
	running:        bool,
	installed:      [2]bool,
	previous:       [2]posix.sigaction_t,
}

process_signal_watch: Signal_Watch
// Write end the handler uses; -1 while no handler is installed.
signal_pipe_writer: i32 = -1

signal_handler :: proc "c" (signal: posix.Signal) {
	descriptor := intrinsics.atomic_load(&signal_pipe_writer)
	if descriptor < 0 {
		return
	}
	value := [1]u8{u8(signal)}
	// The write end is nonblocking: a full pipe already holds a pending request.
	posix.write(posix.FD(descriptor), raw_data(value[:]), 1)
}

// Lists `runtime` for signal-driven drain. `claim` installs the process
// handlers; tests pass false and feed the pipe through signal_watch_notify.
// False means the watcher could not start and the server runs without it.
signal_watch_register :: proc(watch: ^Signal_Watch, runtime: ^Server_Runtime, claim: bool) -> bool {
	sync.lock(&watch.lifecycle)
	defer sync.unlock(&watch.lifecycle)

	if !watch.running && !signal_watch_start(watch) {
		return false
	}

	sync.lock(&watch.mutex)
	defer sync.unlock(&watch.mutex)

	if claim {
		signal_watch_claim_locked(watch)
	}

	if runtime.signal_watch != nil {
		return runtime.signal_watch == watch
	}
	runtime.signal_previous = nil
	runtime.signal_next = watch.servers
	if watch.servers != nil {
		watch.servers.signal_previous = runtime
	}
	watch.servers = runtime
	runtime.signal_watch = watch
	watch.count += 1

	return true
}

// Safe for a runtime that was never registered. Returns only after the watcher
// that listed `runtime` can no longer reach it.
signal_watch_unregister :: proc(runtime: ^Server_Runtime) {
	watch := runtime.signal_watch
	if watch == nil {
		return
	}
	sync.lock(&watch.lifecycle)
	defer sync.unlock(&watch.lifecycle)
	sync.lock(&watch.mutex)

	if runtime.signal_previous != nil {
		runtime.signal_previous.signal_next = runtime.signal_next
	} else {
		watch.servers = runtime.signal_next
	}
	if runtime.signal_next != nil {
		runtime.signal_next.signal_previous = runtime.signal_previous
	}
	runtime.signal_previous, runtime.signal_next = nil, nil
	runtime.signal_watch = nil
	watch.count -= 1
	last := watch.count == 0

	if last {
		signal_watch_restore_locked(watch)
	}
	sync.unlock(&watch.mutex)

	if last {
		signal_watch_stop(watch)
	}
}

// What the handler does, callable from ordinary code.
signal_watch_notify :: proc(watch: ^Signal_Watch, signal: posix.Signal) -> bool {
	value := [1]u8{u8(signal)}

	return posix.write(watch.writer, raw_data(value[:]), 1) == 1
}

signal_watch_start :: proc(watch: ^Signal_Watch) -> bool {
	descriptors: [2]posix.FD
	if posix.pipe(&descriptors) != .OK {
		return false
	}

	for descriptor in descriptors {
		_ = posix.fcntl(descriptor, .SETFD, i32(posix.FD_CLOEXEC))
	}

	if flags := posix.fcntl(descriptors[1], .GETFL, 0); flags >= 0 {
		_ = posix.fcntl(descriptors[1], .SETFL, transmute(posix.O_Flags)flags + {.NONBLOCK})
	}

	watch.reader, watch.writer = descriptors[0], descriptors[1]
	// The thread outlives whichever caller happened to start it: keep its
	// bookkeeping out of that caller's allocator.
	context.allocator = rt.heap_allocator()
	watch.worker = thread.create_and_start_with_poly_data(watch, signal_watch_run)

	if watch.worker == nil {
		posix.close(descriptors[0])
		posix.close(descriptors[1])
		return false
	}
	watch.running = true

	return true
}

// Caller holds lifecycle and has already restored the dispositions.
signal_watch_stop :: proc(watch: ^Signal_Watch) {
	if intrinsics.atomic_load(&signal_pipe_writer) == i32(watch.writer) {
		intrinsics.atomic_store(&signal_pipe_writer, -1)
	}
	quit := [1]u8{0}
	posix.write(watch.writer, raw_data(quit[:]), 1)
	context.allocator = rt.heap_allocator()
	thread.join(watch.worker)
	thread.destroy(watch.worker)
	posix.close(watch.reader)
	posix.close(watch.writer)
	watch.worker = nil
	watch.running = false
}

signal_watch_run :: proc(watch: ^Signal_Watch) {
	for {
		value: [1]u8
		count := posix.read(watch.reader, raw_data(value[:]), 1)

		if count < 0 {
			if posix.errno() == .EINTR {
				continue
			}
			return
		}

		if count == 0 || value[0] == 0 {
			return
		}

		signal_watch_dispatch(watch, posix.Signal(value[0]))
	}
}

// Requests a drain of every listed server and hands the signals back to their
// previous disposition, so a repeated signal is not swallowed.
signal_watch_dispatch :: proc(watch: ^Signal_Watch, signal: posix.Signal) {
	sync.lock(&watch.mutex)
	defer sync.unlock(&watch.mutex)
	signal_watch_restore_locked(watch)

	for runtime := watch.servers; runtime != nil; runtime = runtime.signal_next {
		if sync.atomic_load(&runtime.signal_drained) {
			continue
		}
		sync.atomic_store(&runtime.signal_drained, true)
		context.logger = runtime.logger
		log.infof("Received %v: draining connections; a second signal stops the process immediately", signal)
		request_runtime_drain(runtime, 0)
	}
}

signal_watch_claim_locked :: proc(watch: ^Signal_Watch) {
	intrinsics.atomic_store(&signal_pipe_writer, i32(watch.writer))

	for signal, index in WATCHED_SIGNALS {
		if watch.installed[index] {
			continue
		}
		current: posix.sigaction_t
		if posix.sigaction(signal, nil, &current) != .OK {
			continue
		}
		// Somebody else already decided what this signal does.
		if .SIGINFO in current.sa_flags || rawptr(current.sa_handler) != rawptr(posix.SIG_DFL) {
			continue
		}
		action := posix.sigaction_t {
			sa_handler = signal_handler,
			sa_flags   = {.RESTART},
		}
		posix.sigemptyset(&action.sa_mask)

		if posix.sigaction(signal, &action, &watch.previous[index]) == .OK {
			watch.installed[index] = true
		}
	}
}

signal_watch_restore_locked :: proc(watch: ^Signal_Watch) {
	for signal, index in WATCHED_SIGNALS {
		if !watch.installed[index] {
			continue
		}
		watch.installed[index] = false
		current: posix.sigaction_t
		// Leave a handler that replaced ours after we were installed.
		if posix.sigaction(signal, nil, &current) == .OK && rawptr(current.sa_handler) == rawptr(signal_handler) {
			posix.sigaction(signal, &watch.previous[index], nil)
		}
	}
}
