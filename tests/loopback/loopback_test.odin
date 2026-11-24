package saba_loopback_test

import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

// End-to-end coverage: each Python harness in tests/ builds a fixture server
// against the staged collection (ODIN and SABA_TEST_SHARED, exported by
// `task test`), drives it over loopback sockets and exits non-zero on the first
// broken expectation. Every harness is its own test here. A harness that needs
// a tool this machine lacks (python3, go, aioquic, openssl) exits with
// HARNESS_SKIP and is reported as a notice, not a failure; nothing is installed.
HARNESS_SKIP :: 77
HARNESS_TIMEOUT :: 4 * time.Minute
// Harnesses assert on wall-clock timing, so only a few run at once.
HARNESS_SLOTS :: 4
OUTPUT_TAIL :: 6000

gate: sync.Mutex
running: int

harness_enter :: proc() {
	for {
		sync.lock(&gate)
		if running < HARNESS_SLOTS {
			running += 1
			sync.unlock(&gate)
			return
		}
		sync.unlock(&gate)
		time.sleep(50 * time.Millisecond)
	}
}

harness_leave :: proc() {
	sync.lock(&gate)
	running -= 1
	sync.unlock(&gate)
}

run_harness :: proc(t: ^testing.T, script: string, arguments: ..string) {
	testing.set_fail_timeout(t, 10 * time.Minute)
	a := context.temp_allocator
	python := os.get_env("SABA_PYTHON", a)
	if python == "" {
		python = "python3"
	}
	_, _, _, located := os.process_exec({command = {python, "--version"}}, a)
	if located != nil {
		log.warnf("Skipping %s: %s is not available (%v). Set SABA_PYTHON.", script, python, located)
		return
	}
	if !testing.expectf(t, os.is_file(script), "%s not found from the test working directory", script) {
		return
	}

	capture, created := os.create_temp_file("", "saba-loopback-*.log")
	if !testing.expectf(t, created == nil, "could not create an output file: %v", created) {
		return
	}
	path := strings.clone(os.name(capture), a)
	defer os.remove(path)
	command := make([dynamic]string, a)
	append(&command, python, script)
	append(&command, ..arguments)

	harness_enter()
	process, started := os.process_start({command = command[:], stdout = capture, stderr = capture})
	if started != nil {
		harness_leave()
		os.close(capture)
		testing.expectf(t, false, "could not start %s: %v", script, started)
		return
	}

	state: os.Process_State
	timed_out := false
	deadline := time.tick_add(time.tick_now(), HARNESS_TIMEOUT)
	for {
		waited, error := os.process_wait(process, 250 * time.Millisecond)
		if error == nil {
			state = waited
			break
		}
		if error != .Timeout || time.tick_diff(time.tick_now(), deadline) <= 0 {
			timed_out = true
			_ = os.process_kill(process)
			_, _ = os.process_wait(process)
			break
		}
	}
	harness_leave()
	os.close(capture)

	output, _ := os.read_entire_file(path, a)
	text := string(output)
	if len(text) > OUTPUT_TAIL {
		text = text[len(text) - OUTPUT_TAIL:]
	}

	if timed_out {
		testing.expectf(t, false, "%s did not finish within %v:\n%s", script, HARNESS_TIMEOUT, text)
		return
	}
	if state.exit_code == HARNESS_SKIP {
		log.warnf("Skipping %s: %s", script, strings.trim_space(text))
		return
	}
	testing.expectf(t, state.exit_code == 0, "%s failed (exit %d):\n%s", script, state.exit_code, text)
}

@(test)
async_server :: proc(t: ^testing.T) {
	run_harness(t, "tests/async_server.py")
}

@(test)
cancellation :: proc(t: ^testing.T) {
	run_harness(t, "tests/cancellation.py")
}

@(test)
chunked_requests :: proc(t: ^testing.T) {
	run_harness(t, "tests/chunked_requests.py")
}

@(test)
conditional_assets :: proc(t: ^testing.T) {
	run_harness(t, "tests/conditional_assets.py")
}

@(test)
drain_observer :: proc(t: ^testing.T) {
	run_harness(t, "tests/drain_observer.py")
}

@(test)
drain_server :: proc(t: ^testing.T) {
	run_harness(t, "tests/drain_server.py")
}

@(test)
file_ranges :: proc(t: ^testing.T) {
	run_harness(t, "tests/file_ranges.py")
}

@(test)
http2 :: proc(t: ^testing.T) {
	run_harness(t, "tests/http2.py")
}

@(test)
http2_connect :: proc(t: ^testing.T) {
	run_harness(t, "tests/http2_connect.py")
}

@(test)
http2_multiplex :: proc(t: ^testing.T) {
	run_harness(t, "tests/http2_multiplex.py")
}

@(test)
http3_conformance :: proc(t: ^testing.T) {
	run_harness(t, "tests/http3_conformance.py")
}

@(test)
http3_connect :: proc(t: ^testing.T) {
	run_harness(t, "tests/http3_connect.py")
}

@(test)
http3_handshake :: proc(t: ^testing.T) {
	run_harness(t, "tests/http3_handshake.py")
}

@(test)
http3_idle :: proc(t: ^testing.T) {
	run_harness(t, "tests/http3_idle.py")
}

@(test)
http3_phases :: proc(t: ^testing.T) {
	run_harness(t, "tests/http3_phases.py")
}

@(test)
http3_shutdown :: proc(t: ^testing.T) {
	run_harness(t, "tests/http3_shutdown.py")
}

@(test)
http3_trailers :: proc(t: ^testing.T) {
	run_harness(t, "tests/http3_trailers.py")
}

@(test)
https80 :: proc(t: ^testing.T) {
	run_harness(t, "tests/https80.py")
}

@(test)
keep_alive :: proc(t: ^testing.T) {
	run_harness(t, "tests/keep_alive.py")
}

@(test)
keep_alive_core :: proc(t: ^testing.T) {
	run_harness(t, "tests/keep_alive.py", "--core")
}

@(test)
observability_timeout :: proc(t: ^testing.T) {
	run_harness(t, "tests/observability_timeout.py")
}

@(test)
offload :: proc(t: ^testing.T) {
	run_harness(t, "tests/offload.py")
}

@(test)
resources :: proc(t: ^testing.T) {
	run_harness(t, "tests/resources.py")
}

@(test)
streaming :: proc(t: ^testing.T) {
	run_harness(t, "tests/streaming.py")
}

@(test)
upgrade_core :: proc(t: ^testing.T) {
	run_harness(t, "tests/core/upgrade.py")
}

@(test)
websocket79 :: proc(t: ^testing.T) {
	run_harness(t, "tests/websocket79.py")
}
