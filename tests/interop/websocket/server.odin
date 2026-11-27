package saba_interop_websocket_test

import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"
import harness "../../support/harness"

SOURCE :: "tests/fixtures/apps/websocket_policy"

// The websocket_policy program, driven through its stdin: m prints METRICS,
// b probes the write readiness of the combined probe's socket, s stops, j
// joins the server thread and prints JOINED, q exits.
Server :: struct {
	p:      ^harness.Process,
	input:  ^os.File,
	port:   int,
	joined: bool,
}

Metrics :: struct {
	active, created, opened, closed, dropped, messages, queue_count, queue_bytes, out_limit: int,
	scope_bytes, scope_nodes, write_waits, partial_writes, writable_callbacks:                int,
	clean, unclean, close_timeouts, combined_timeouts:                                      int,
	valid:                                                                                  bool,
}

Joined :: struct {
	created, opened, closed, dropped, scope_bytes, scope_nodes, heap_bytes, tls_bytes, write_waits, partial_writes: int,
}

launch :: proc(t: ^testing.T, transport: string) -> (s: Server, ok: bool) {
	binary := harness.build_shared(t, SOURCE) or_return
	s.p, s.input, ok = harness.start_with_input(
		t,
		{binary, transport, harness.fixture("tls/rsa2048-valid.pem"), harness.fixture("tls/rsa2048.pem")},
	)
	if !ok {
		return
	}
	s.port, ok = harness.ready(t, s.p, 30 * time.Second)
	if !ok {
		release(&s)
	}
	return
}

command :: proc(t: ^testing.T, s: ^Server, text: string) -> bool {
	return harness.send_input(t, s.input, text)
}

fields :: proc(line, prefix: string) -> []string {
	return strings.fields(line[len(prefix):], context.temp_allocator)
}

number :: proc(text: string) -> int {
	value, _ := strconv.parse_int(text)
	return value
}

metrics :: proc(t: ^testing.T, s: ^Server) -> (m: Metrics, ok: bool) {
	command(t, s, "m") or_return
	line := harness.expect_line(t, s.p, "METRICS ", 20 * time.Second) or_return
	v := fields(line, "METRICS ")
	if !testing.expectf(t, len(v) == 19, "%s", line) {
		return
	}
	m = {
		active             = number(v[0]),
		valid              = v[1] == "true",
		created            = number(v[2]),
		opened             = number(v[3]),
		closed             = number(v[4]),
		dropped            = number(v[5]),
		messages           = number(v[6]),
		queue_count        = number(v[7]),
		queue_bytes        = number(v[8]),
		out_limit          = number(v[9]),
		scope_bytes        = number(v[10]),
		scope_nodes        = number(v[11]),
		write_waits        = number(v[12]),
		partial_writes     = number(v[13]),
		writable_callbacks = number(v[14]),
		clean              = number(v[15]),
		unclean            = number(v[16]),
		close_timeouts     = number(v[17]),
		combined_timeouts  = number(v[18]),
	}
	return m, true
}

wait_metrics :: proc(
	t: ^testing.T,
	s: ^Server,
	until: proc(m: Metrics) -> bool,
	timeout := 12 * time.Second,
	loc := #caller_location,
) -> (
	m: Metrics,
	ok: bool,
) {
	deadline := time.tick_add(time.tick_now(), timeout)
	for {
		m = metrics(t, s) or_return
		if until(m) {
			return m, true
		}
		if time.tick_since(deadline) >= 0 {
			testing.expectf(t, false, "metrics never matched within %v: %v", timeout, m, loc = loc)
			return m, false
		}
		time.sleep(5 * time.Millisecond)
	}
}

// Waits until no connection is active and checks every session was dropped
// and its budget returned.
idle :: proc(t: ^testing.T, s: ^Server, loc := #caller_location) -> (m: Metrics, ok: bool) {
	m = wait_metrics(t, s, proc(m: Metrics) -> bool {return m.active == 0}, loc = loc) or_return
	ok = testing.expectf(t, m.created == m.dropped, "sessions not dropped: %v", m, loc = loc)
	ok &&= testing.expectf(t, m.scope_bytes == 0, "budget still used: %v", m, loc = loc)
	return
}

// Stops the server and joins it. The program is still running, so a socket
// it did not close is still open.
join :: proc(t: ^testing.T, s: ^Server, loc := #caller_location) -> (j: Joined, ok: bool) {
	command(t, s, "s") or_return
	finished := harness.expect_line(t, s.p, "FINISHED ", 20 * time.Second) or_return
	if !testing.expectf(t, finished == "FINISHED true", "%s", finished, loc = loc) {
		return
	}
	command(t, s, "j") or_return
	line := harness.expect_line(t, s.p, "JOINED ", 20 * time.Second) or_return
	v := fields(line, "JOINED ")
	if !testing.expectf(t, len(v) == 10, "%s", line, loc = loc) {
		return
	}
	s.joined = true
	j = {
		created        = number(v[0]),
		opened         = number(v[1]),
		closed         = number(v[2]),
		dropped        = number(v[3]),
		scope_bytes    = number(v[4]),
		scope_nodes    = number(v[5]),
		heap_bytes     = number(v[6]),
		tls_bytes      = number(v[7]),
		write_waits    = number(v[8]),
		partial_writes = number(v[9]),
	}
	ok = testing.expectf(t, j.created == j.dropped && j.opened <= j.closed, "%v", j, loc = loc)
	ok &&= testing.expectf(t, j.scope_nodes == 1, "%v", j, loc = loc)
	ok &&= testing.expectf(t, j.scope_bytes == 0 && j.heap_bytes == 0 && j.tls_bytes == 0, "%v", j, loc = loc)
	if sockets, listed := harness.tcp_sockets(s.p); listed {
		ok &&= testing.expectf(t, sockets == 0, "%d TCP sockets open after the join", sockets, loc = loc)
	}
	return
}

// Joins the server if the test did not, lets it exit, and checks it exited 0
// without a sanitizer report.
close :: proc(t: ^testing.T, s: ^Server, loc := #caller_location) {
	if s.p == nil {
		return
	}
	if !s.joined {
		_, _ = join(t, s, loc = loc)
	}
	if s.joined {
		_ = harness.send_input(t, s.input, "q")
	}
	code := harness.wait(s.p)
	testing.expectf(t, code == 0, "the server exited with %d\n%s", code, harness.transcript(s.p), loc = loc)
	output := harness.transcript(s.p)
	for report in ([]string{"ERROR: AddressSanitizer", "WARNING: ThreadSanitizer"}) {
		testing.expectf(t, !strings.contains(output, report), "%s\n%s", report, output, loc = loc)
	}
	release(s)
}

release :: proc(s: ^Server) {
	if s.input != nil {
		os.close(s.input)
		s.input = nil
	}
	harness.stop(s.p)
	s.p = nil
}
