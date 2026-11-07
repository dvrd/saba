package saba_core

import "core:sync"
import "core:time"
import async "shared:async"

DEFAULT_DRAIN_TIMEOUT :: 5 * time.Second
MAX_DRAIN_TIMEOUT :: 24 * time.Hour

Server_State :: enum {
	Stopped,
	Starting,
	Ready,
	Draining,
	Stopping,
}

// Endpoint publication is independent of readiness: a draining server may still
// own its address and admitted requests. The snapshot never extends its lifetime.
server_state :: proc(control: ^Server_Control) -> Server_State {
	if control == nil do return .Stopped
	sync.lock(&control._mutex)
	defer sync.unlock(&control._mutex)
	if !control._in_use do return .Stopped
	if control._runtime == nil {
		return .Stopping if control._ever_published else .Starting
	}
	if control._stop_requested || async.cancelled(&control._server.accept_task) do return .Stopping
	if server_is_draining(control._server) do return .Draining
	return .Ready
}

server_ready :: proc(control: ^Server_Control) -> bool {
	return server_state(control) == .Ready
}

// Nonblocking, safe from observers/handlers or a controlling thread. Zero uses
// Server.drain_timeout (then the five-second default). Repeated requests may
// shorten but never extend the deadline. stop_server still means immediate stop.
// Calls before publication are remembered. Arbitrary blocking handlers cannot
// be preempted; serve joins only after their callbacks return cooperatively.
drain_server :: proc(control: ^Server_Control, timeout: time.Duration = 0) -> bool {
	if control == nil || !drain_duration_valid(timeout) do return false
	sync.lock(&control._mutex)
	defer sync.unlock(&control._mutex)
	if control._stop_requested do return false
	control._drain_requested = true
	if timeout == 0 do control._drain_default_requested = true
	else if control._drain_timeout == 0 || timeout < control._drain_timeout {
		control._drain_timeout = timeout
	}
	if control._server != nil do request_runtime_drain(control._server, timeout)
	return true
}

@(private)
drain_duration_valid :: proc(timeout: time.Duration) -> bool {
	return timeout >= 0 && timeout <= MAX_DRAIN_TIMEOUT
}

@(private)
server_is_draining :: proc(runtime: ^Server_Runtime) -> bool {
	if runtime == nil do return false
	sync.lock(&runtime.drain_mutex)
	defer sync.unlock(&runtime.drain_mutex)
	return runtime.draining
}

@(private)
request_runtime_drain :: proc(runtime: ^Server_Runtime, timeout: time.Duration) {
	budget := timeout
	if budget == 0 do budget = runtime.config.drain_timeout
	if budget == 0 do budget = DEFAULT_DRAIN_TIMEOUT
	deadline := async.deadline_after(&runtime.executor, budget)
	sync.lock(&runtime.drain_mutex)
	if !runtime.draining || deadline.at < runtime.drain_deadline.at {
		runtime.draining = true
		runtime.drain_deadline = deadline
        if runtime.cancellation!=nil {
            at:=time.tick_add(time.tick_now(),budget)
            sync.atomic_store(&runtime.cancellation.drain_at,i64(time.tick_diff({},at)))
        }
	}
	sync.unlock(&runtime.drain_mutex)
	wake_keep_alive_connections(runtime)
	// The listener task closes its own socket, avoiding races with running accept.
	async.wake(&runtime.executor, &runtime.accept_task)
}

@(private)
drain_connections :: proc(runtime: ^Server_Runtime) -> async.Resume_Result {
	// This is the accept task itself, so close cannot race its socket operations.
	async.close(runtime.listener)
	sync.lock(&runtime.drain_mutex)
	deadline := runtime.drain_deadline
	sync.unlock(&runtime.drain_mutex)
	if sync.atomic_load(&runtime.active_connections) == 0 {
		shutdown_runtime(runtime)
		return .Done
	}
	err := async.sleep_until(&runtime.executor, deadline)
	if err.kind == .Pending do return .Waiting
	// Deadline expiry or runtime failure cancels residual readers/writers/WS.
	shutdown_runtime(runtime)
	return .Done
}

@(private)
drain_connection_finished :: proc(runtime: ^Server_Runtime) {
	if server_is_draining(runtime) do async.wake(&runtime.executor, &runtime.accept_task)
}
