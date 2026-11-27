package saba_interop_https_test

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"
import harness "../../support/harness"

SOURCE :: "tests/interop/https/server"

// The server program, driven through its stdin: m prints METRICS, r releases
// the deferred response, d drains, s stops, j joins the server thread and
// prints JOINED, q exits.
Server :: struct {
	p:      ^harness.Process,
	input:  ^os.File,
	port:   int,
	joined: bool,
}

Metrics :: struct {
	active, handled, handshakes, closed, write_waits, partial_writes, leases, started, completed: int,
	valid:                                                                                     bool,
}

Joined :: struct {
	handled, handshakes, successes, closed, live_bytes, write_waits, partial_writes, leases: int,
}

launch :: proc(t: ^testing.T, mode: string, web := "") -> (s: Server, ok: bool) {
	binary := harness.build_shared(t, SOURCE) or_return
	env: []string
	if web != "" {
		env = {fmt.tprintf("HTTPS80_WEB=%s", web)}
	}
	s.p, s.input, ok = harness.start_with_input(
		t,
		{binary, mode, harness.fixture("tls/rsa2048-valid.pem"), harness.fixture("tls/rsa2048.pem")},
		env,
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
	line := harness.expect_line(t, s.p, "METRICS ", 15 * time.Second) or_return
	v := fields(line, "METRICS ")
	if !testing.expectf(t, len(v) == 10, "%s", line) {
		return
	}
	m = {
		active         = number(v[0]),
		valid          = v[1] == "true",
		handled        = number(v[2]),
		handshakes     = number(v[3]),
		closed         = number(v[4]),
		write_waits    = number(v[5]),
		partial_writes = number(v[6]),
		leases         = number(v[7]),
		started        = number(v[8]),
		completed      = number(v[9]),
	}
	return m, true
}

wait_metrics :: proc(
	t: ^testing.T,
	s: ^Server,
	until: proc(m: Metrics) -> bool,
	timeout := 8 * time.Second,
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
			testing.expectf(t, false, "metrics never matched: %v", m, loc = loc)
			return m, false
		}
		time.sleep(5 * time.Millisecond)
	}
}

// Waits until no connection is active and checks every lease and handshake
// was retired.
idle :: proc(t: ^testing.T, s: ^Server, loc := #caller_location) -> (m: Metrics, ok: bool) {
	m = wait_metrics(t, s, proc(m: Metrics) -> bool {return m.active == 0}, loc = loc) or_return
	ok = testing.expectf(t, m.leases == 0, "leases held: %v", m, loc = loc)
	ok &&= testing.expectf(t, m.handshakes == m.closed, "handshakes not closed: %v", m, loc = loc)
	return
}

// Stops the server (unless it stopped on its own) and joins it. The program
// is still running, so a socket it did not close is still open.
join :: proc(t: ^testing.T, s: ^Server, stop := true, loc := #caller_location) -> (j: Joined, ok: bool) {
	if stop {
		command(t, s, "s") or_return
	}
	finished := harness.expect_line(t, s.p, "FINISHED ", 15 * time.Second) or_return
	if !testing.expectf(t, finished == "FINISHED true", "%s", finished, loc = loc) {
		return
	}
	command(t, s, "j") or_return
	line := harness.expect_line(t, s.p, "JOINED ", 15 * time.Second) or_return
	v := fields(line, "JOINED ")
	if !testing.expectf(t, len(v) == 9 && v[0] == "true", "%s", line, loc = loc) {
		return
	}
	s.joined = true
	j = {
		handled        = number(v[1]),
		handshakes     = number(v[2]),
		successes      = number(v[3]),
		closed         = number(v[4]),
		live_bytes     = number(v[5]),
		write_waits    = number(v[6]),
		partial_writes = number(v[7]),
		leases         = number(v[8]),
	}
	ok = testing.expectf(t, j.handshakes == j.closed, "%v", j, loc = loc)
	ok &&= testing.expectf(t, j.live_bytes == 0 && j.leases == 0, "%v", j, loc = loc)
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
