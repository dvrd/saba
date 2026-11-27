// Drain and stop driven over stdin while raw loopback clients hold work in
// every state a connection can be in: reading, in a handler, writing to a slow
// reader, parked on a WebSocket. The program keeps running after the join, so
// an exit never hides a socket that was not closed.
package saba_e2e_drain_test

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"
import harness "../../support/harness"

Server :: struct {
	p:      ^harness.Process,
	input:  ^os.File,
	port:   int,
	joined: bool,
}

launch :: proc(t: ^testing.T, binary: string, workers, milliseconds: int, web := "") -> (s: Server, ok: bool) {
	env := make([dynamic]string, context.temp_allocator)
	append(&env, fmt.tprintf("DRAIN_WORKERS=%d", workers), fmt.tprintf("DRAIN_MS=%d", milliseconds))
	if web != "" {
		append(&env, fmt.tprintf("DRAIN_WEB=%s", web))
	}
	s.p, s.input = harness.start_with_input(t, {binary}, env[:]) or_return
	s.port, ok = harness.ready(t, s.p)
	if !ok {
		finish(t, &s)
	}
	return
}

command :: proc(t: ^testing.T, s: ^Server, text: string) {
	harness.send_input(t, s.input, text)
}

// Polls capacity until the server has admitted the connection.
admitted :: proc(t: ^testing.T, s: ^Server) -> bool {
	deadline := time.tick_add(time.tick_now(), 3 * time.Second)
	for time.tick_since(deadline) < 0 {
		command(t, s, "c")
		line := harness.expect_line(t, s.p, "capacity ") or_return
		active, _ := strconv.parse_int(strings.fields(line, context.temp_allocator)[1])
		if active > 0 {
			return true
		}
		time.sleep(5 * time.Millisecond)
	}
	return testing.expect(t, false, "connection not admitted")
}

// A drain answers at once and the server stops being ready.
drain :: proc(t: ^testing.T, s: ^Server, key := "d", loc := #caller_location) -> bool {
	command(t, s, key)
	line := harness.expect_line(t, s.p, "drain ", loc = loc) or_return
	return testing.expectf(t, harness.last_field(line) == "false", "still ready after drain: %q", line, loc = loc)
}

join :: proc(t: ^testing.T, s: ^Server, loc := #caller_location) -> bool {
	line := harness.expect_line(t, s.p, "finished ", loc = loc) or_return
	testing.expectf(t, harness.last_field(line) == "true", "serve failed: %q", line, loc = loc) or_return
	command(t, s, "j")
	harness.expect_line(t, s.p, "joined", loc = loc) or_return
	s.joined = true
	return testing.expect(t, harness.running(s.p), "process exit must not conceal leaked sockets", loc = loc)
}

finish :: proc(t: ^testing.T, s: ^Server, loc := #caller_location) {
	if s.p == nil {
		return
	}
	if harness.running(s.p) {
		if !s.joined {
			command(t, s, "rs")
			join(t, s, loc)
		}
		command(t, s, "q")
		harness.exited_cleanly(t, s.p, 5 * time.Second, loc)
	}
	harness.stop(s.p)
	os.close(s.input)
	s.p = nil
}

// A connection made during the drain is refused, closed or answered 503.
reject_new_work :: proc(t: ^testing.T, s: ^Server) {
	extra, error := harness.dial(s.port, 700 * time.Millisecond)
	if error != nil {
		return
	}
	defer net.close(extra)
	if !harness.send_text(extra, "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n") {
		return
	}
	reply: [256]u8
	n, received := net.recv_tcp(extra, reply[:])
	if received == .Connection_Closed {
		return
	}
	testing.expectf(t, received == nil, "no answer to work during drain: %v", received)
	testing.expectf(t, n == 0 || strings.has_prefix(string(reply[:n]), "HTTP/1.1 503 "), "work admitted during drain: %q", string(reply[:n]))
}

completed_body :: proc(t: ^testing.T, binary: string, workers: int) -> bool {
	s := launch(t, binary, workers, 1500) or_return
	defer finish(t, &s)
	conn, error := harness.dial(s.port)
	testing.expectf(t, error == nil, "connect: %v", error) or_return
	defer net.close(conn)
	harness.send_text(conn, "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\n\r\nab")
	admitted(t, &s) or_return
	drain(t, &s) or_return
	reject_new_work(t, &s)
	harness.send_text(conn, "cd")
	head, _ := harness.read_head(t, conn)
	testing.expectf(t, strings.has_prefix(head, "HTTP/1.1 200 "), "admitted request not answered: %q", head) or_return
	body, complete := harness.read_n(t, conn, 4)
	testing.expect(t, complete, "response body ended before admitted work completed")
	testing.expect_value(t, string(body), "abcd")
	join(t, &s) or_return
	testing.expect(t, harness.await_close(conn), "connection open after drain")
	extra, refused := harness.dial(s.port)
	if refused != nil {
		return true
	}
	defer net.close(extra)
	if harness.send_text(extra, "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n") {
		reply: [1]u8
		n, _ := net.recv_tcp(extra, reply[:])
		testing.expect(t, n == 0, "new work served after drain completed")
	}
	return true
}

stalled_reader :: proc(t: ^testing.T, binary: string, workers: int) -> bool {
	s := launch(t, binary, workers, 250) or_return
	defer finish(t, &s)
	conn, _ := harness.dial(s.port)
	defer net.close(conn)
	harness.send_text(conn, "GET /")
	admitted(t, &s) or_return
	started := time.tick_now()
	drain(t, &s) or_return
	time.sleep(120 * time.Millisecond)
	// A second request must not reset the first deadline.
	drain(t, &s) or_return
	join(t, &s) or_return
	elapsed := time.tick_since(started)
	testing.expectf(t, elapsed >= 150 * time.Millisecond && elapsed < 900 * time.Millisecond, "drain took %v", elapsed)
	return testing.expect(t, harness.await_close(conn), "stalled reader not closed")
}

shorter_deadline :: proc(t: ^testing.T, binary: string, workers: int) -> bool {
	s := launch(t, binary, workers, 1500) or_return
	defer finish(t, &s)
	conn, _ := harness.dial(s.port)
	defer net.close(conn)
	harness.send_text(conn, "GET /")
	admitted(t, &s) or_return
	started := time.tick_now()
	drain(t, &s) or_return
	// A later drain with a shorter budget wins.
	drain(t, &s, "f") or_return
	join(t, &s) or_return
	elapsed := time.tick_since(started)
	testing.expectf(t, elapsed < 800 * time.Millisecond, "shorter deadline ignored: %v", elapsed)
	return testing.expect(t, harness.await_close(conn), "stalled reader not closed")
}

active_handler :: proc(t: ^testing.T, binary: string, workers: int) -> bool {
	s := launch(t, binary, workers, 1500) or_return
	defer finish(t, &s)
	conn, _ := harness.dial(s.port)
	defer net.close(conn)
	harness.send_text(conn, "GET /hold HTTP/1.1\r\nHost: localhost\r\n\r\n")
	harness.expect_line(t, s.p, "holding") or_return
	drain(t, &s) or_return
	command(t, &s, "r")
	head, _ := harness.read_head(t, conn)
	testing.expectf(t, strings.has_prefix(head, "HTTP/1.1 200 "), "held request not answered: %q", head)
	join(t, &s) or_return
	return testing.expect(t, harness.await_close(conn), "connection open after drain")
}

backpressured_writer :: proc(t: ^testing.T, binary: string, workers: int) -> bool {
	s := launch(t, binary, workers, 200) or_return
	defer finish(t, &s)
	conn, _ := harness.dial(s.port)
	defer net.close(conn)
	_ = net.set_option(conn, .Receive_Buffer_Size, 1024)
	harness.send_text(conn, "GET /large HTTP/1.1\r\nHost: localhost\r\n\r\n")
	head, _ := harness.read_head(t, conn)
	testing.expectf(t, strings.has_prefix(head, "HTTP/1.1 200 "), "large response not started: %q", head)
	drain(t, &s) or_return
	join(t, &s) or_return
	return testing.expect(t, harness.await_close(conn), "slow reader not closed")
}

parked_websocket :: proc(t: ^testing.T, binary: string, workers: int) -> bool {
	web := harness.workdir(t, "drain-web")
	defer os.remove_all(web)
	s := launch(t, binary, workers, 200, web) or_return
	defer finish(t, &s)
	conn, _ := harness.dial(s.port)
	defer net.close(conn)
	harness.send_text(
		conn,
		"GET /__reload HTTP/1.1\r\nHost: localhost\r\n" +
		"Upgrade: websocket\r\nConnection: Upgrade\r\n" +
		"Sec-WebSocket-Version: 13\r\n" +
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n",
	)
	head, _ := harness.read_head(t, conn)
	testing.expectf(t, strings.has_prefix(head, "HTTP/1.1 101 "), "reload socket not upgraded: %q", head)
	drain(t, &s) or_return
	join(t, &s) or_return
	return testing.expect(t, harness.await_close(conn), "parked WebSocket not closed")
}

immediate_override :: proc(t: ^testing.T, binary: string, workers: int) -> bool {
	s := launch(t, binary, workers, 5000) or_return
	defer finish(t, &s)
	conn, _ := harness.dial(s.port)
	defer net.close(conn)
	harness.send_text(conn, "GET /")
	admitted(t, &s) or_return
	drain(t, &s) or_return
	started := time.tick_now()
	// A stop during a long drain ends it now.
	command(t, &s, "ss")
	join(t, &s) or_return
	elapsed := time.tick_since(started)
	testing.expectf(t, elapsed < 1500 * time.Millisecond, "stop waited for the drain: %v", elapsed)
	return testing.expect(t, harness.await_close(conn), "connection open after stop")
}

@(test)
drain_server :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 4 * time.Minute)
	work := harness.workdir(t, "drain")
	defer os.remove_all(work)
	binary, built := harness.build(t, "tests/e2e/drain/server", work)
	if !built {
		return
	}
	Check :: struct {
		name: string,
		run:  proc(t: ^testing.T, binary: string, workers: int) -> bool,
	}
	checks := []Check {
		{"completed_body", completed_body},
		{"stalled_reader", stalled_reader},
		{"shorter_deadline", shorter_deadline},
		{"active_handler", active_handler},
		{"backpressured_writer", backpressured_writer},
		{"parked_websocket", parked_websocket},
		{"immediate_override", immediate_override},
	}
	// One at a time: the checks bound how long a drain takes.
	for workers in ([]int{1, 4}) {
		for check in checks {
			before := testing.failed(t)
			check.run(t, binary, workers)
			testing.expectf(t, before || !testing.failed(t), "workers=%d: %s", workers, check.name)
		}
	}

	// A drain requested before serve publishes stops that serve at once, and
	// the same control serves again afterwards.
	p, started := harness.start(t, {binary}, {"DRAIN_PRESTART=1", "DRAIN_WORKERS=1"})
	if !started {
		return
	}
	defer harness.stop(p)
	harness.expect_line(t, p, "prestart drained", 5 * time.Second)
	testing.expect_value(t, harness.wait(p, 5 * time.Second), 0)
}

// The observer of a finishing request snapshots the metrics and drains the
// server from inside the callback.
@(test)
drain_from_observer :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 2 * time.Minute)
	work := harness.workdir(t, "drain-observer")
	defer os.remove_all(work)
	binary, built := harness.build(t, "tests/e2e/drain/observer", work)
	if !built {
		return
	}
	for workers in ([]int{1, 4}) {
		observe_once(t, binary, workers)
	}
}

observe_once :: proc(t: ^testing.T, binary: string, workers: int) -> bool {
	p, input := harness.start_with_input(t, {binary}, {fmt.tprintf("DRAIN_WORKERS=%d", workers)}) or_return
	defer {
		harness.stop(p)
		os.close(input)
	}
	port := harness.ready(t, p) or_return
	conn, error := harness.dial(port)
	testing.expectf(t, error == nil, "connect: %v", error) or_return
	harness.send_text(conn, "GET /ok HTTP/1.1\r\nHost: localhost\r\n\r\n")
	data, _ := harness.read_to_close(conn)
	response := string(data)
	testing.expectf(
		t,
		strings.has_prefix(response, "HTTP/1.1 200 ") && strings.has_suffix(response, "\r\n\r\nok"),
		"workers=%d: %q",
		workers,
		response,
	)
	line, _ := harness.expect_line(t, p, "observer ")
	testing.expect_value(t, line, "observer drain completed once")
	testing.expect(t, harness.running(p), "process exit must not hide socket cleanup")
	net.close(conn)
	harness.send_input(t, input, "q")
	return harness.exited_cleanly(t, p, 5 * time.Second)
}
