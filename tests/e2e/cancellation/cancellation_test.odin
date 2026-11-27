// Request lifetimes over raw sockets: a retained cancellation token outlives
// its request and the runtime, a late handler response is dropped exactly
// once, shutdown and drain reach a running cooperative handler on the only
// worker, and a peer reset cancels a retained context.
package saba_e2e_cancellation_test

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import harness "../../support/harness"

SERVER :: "tests/e2e/cancellation/server"

Server :: struct {
	process: ^harness.Process,
	input:   ^os.File,
	port:    int,
	stopped: string,
}

launch :: proc(t: ^testing.T, binary: string, budget := 0) -> (s: Server, ok: bool) {
	env := []string{fmt.tprintf("SABA_CANCEL_BUDGET_MS=%d", budget)}
	s.process, s.input = harness.start_with_input(t, {binary}, env) or_return
	s.port = harness.ready(t, s.process) or_return
	return s, true
}

dispose :: proc(s: ^Server) {
	harness.stop(s.process)
	if s.input != nil {
		os.close(s.input)
	}
	s^ = {}
}

// Stops (s) or drains (d) the server and returns its summary line: the drop
// count and each retained context's final status.
stop :: proc(t: ^testing.T, s: ^Server, mode := "s") -> (string, bool) {
	if s.stopped != "" {
		return s.stopped, true
	}
	if !harness.send_input(t, s.input, mode) || !harness.exited_cleanly(t, s.process) {
		return "", false
	}
	lines := harness.lines_with(s.process, "stopped")
	if !testing.expectf(t, len(lines) == 1, "no stopped line\n%s", harness.transcript(s.process)) {
		return "", false
	}
	s.stopped = lines[0]
	return s.stopped, true
}

exchange :: proc(t: ^testing.T, s: ^Server, path: string) -> (r: harness.Response, ok: bool) {
	conn := harness.connect(t, s.port) or_return
	defer net.close(conn)
	harness.send_text(conn, harness.request_wire(path))
	return harness.read_response(t, conn)
}

@(test)
cancellation :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 2 * time.Minute)
	work := harness.workdir(t, "cancellation")
	defer os.remove_all(work)
	binary, built := harness.build(t, SERVER, work)
	if !built {
		return
	}
	scenarios := []proc(t: ^testing.T, binary: string) -> bool {
		retained_token,
		late_response,
		shutdown_reaches_handler,
		drain_reaches_handler,
		peer_reset_cancels,
	}
	for scenario in scenarios {
		if !scenario(t, binary) {
			return
		}
	}
}

// A retained token survives repeated request-arena resets and runtime
// destruction.
retained_token :: proc(t: ^testing.T, binary: string) -> bool {
	s := launch(t, binary) or_return
	defer dispose(&s)
	{
		conn := harness.connect(t, s.port) or_return
		defer net.close(conn)
		harness.send_text(conn, harness.request_wire("/hold"))
		r := harness.read_response(t, conn) or_return
		testing.expect_value(t, string(r.body), "0") or_return
		for _ in 0 ..< 12 {
			harness.send_text(conn, harness.request_wire("/status"))
			r = harness.read_response(t, conn) or_return
			testing.expect_value(t, string(r.body), "0 Completed") or_return
		}
	}
	summary := stop(t, &s) or_return
	return testing.expect_value(t, summary, "stopped 0 Completed")
}

// A late handler response is rejected and its transferred continuation
// dropped exactly once. A handler that finished late answers 504: 408 would
// invite a replay.
late_response :: proc(t: ^testing.T, binary: string) -> bool {
	s := launch(t, binary, budget = 25) or_return
	defer dispose(&s)
	r := exchange(t, &s, "/late") or_return
	testing.expectf(t, r.status == 504 && len(r.body) == 0, "late handler: %d %q", r.status, r.body) or_return
	status := exchange(t, &s, "/status") or_return
	testing.expect_value(t, string(status.body), "1 Deadline") or_return
	summary := stop(t, &s) or_return
	return testing.expect_value(t, summary, "stopped 1 Deadline")
}

// Stopping (s) or draining (d) reaches a handler that runs on the only network
// worker until it is cancelled, and disposes of its response.
cooperative :: proc(t: ^testing.T, binary: string, mode: string) -> bool {
	s := launch(t, binary) or_return
	defer dispose(&s)
	conn := harness.connect(t, s.port) or_return
	defer net.close(conn)
	harness.send_text(conn, harness.request_wire("/cooperate"))
	harness.await_lines(t, s.process, "working", timeout = 3 * time.Second) or_return
	started := time.tick_now()
	summary := stop(t, &s, mode) or_return
	elapsed := time.tick_since(started)
	testing.expectf(t, elapsed < 2 * time.Second, "%s took %v", mode, elapsed) or_return
	testing.expect_value(t, summary, "stopped 1 Shutdown") or_return
	if mode == "s" {
		return harness.expect_closed(t, conn)
	}
	return true
}

shutdown_reaches_handler :: proc(t: ^testing.T, binary: string) -> bool {
	return cooperative(t, binary, "s")
}

drain_reaches_handler :: proc(t: ^testing.T, binary: string) -> bool {
	return cooperative(t, binary, "d")
}

// An observable peer failure cancels a retained context without observability
// enabled: the client stops reading a 4 MiB body, then resets.
peer_reset_cancels :: proc(t: ^testing.T, binary: string) -> bool {
	s := launch(t, binary) or_return
	defer dispose(&s)
	conn := harness.connect(t, s.port) or_return
	_ = net.set_option(conn, .Receive_Buffer_Size, i32(1024))
	harness.send_text(conn, harness.request_wire("/peer"))
	first: [1]u8
	if !testing.expect_value(t, harness.read_exact(conn, first[:]), harness.Read_Result.Ok) {
		net.close(conn)
		return false
	}
	harness.reset(conn)
	deadline := time.tick_add(time.tick_now(), 3 * time.Second)
	for {
		r := exchange(t, &s, "/status") or_return
		if string(r.body) == "0 Peer_Closed" || string(r.body) == "0 Failed" {
			break
		}
		if !testing.expectf(t, time.tick_since(deadline) < 0, "status stayed %q", r.body) {
			return false
		}
		time.sleep(10 * time.Millisecond)
	}
	summary := stop(t, &s) or_return
	return testing.expectf(
		t,
		strings.has_suffix(summary, " Peer_Closed") || strings.has_suffix(summary, " Failed"),
		"summary %q",
		summary,
	)
}
