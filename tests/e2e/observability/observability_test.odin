// Request events and metrics of a server with short timeouts, checked against
// the exact bytes each raw loopback client put on the wire and got back.
//
// A deadline is short only on the server whose requests are about it: the
// header and idle deadlines run from the accept, so on a server that has
// either of them an ordinary request would race the scheduler. Each deadline
// is bounded below exactly, by a clock started before the client connects,
// and above by an event: the server's own report, or the one short timeout
// its server has.
package saba_e2e_observability_test

import "core:fmt"
import "core:net"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"
import harness "../../support/harness"

HEADER :: 200 * time.Millisecond
BODY :: 120 * time.Millisecond
RESPONSE :: 120 * time.Millisecond
IDLE :: 80 * time.Millisecond

Expected :: struct {
	method, outcome: string,
	received, sent:  int,
}

Event :: struct {
	id:                                 int,
	method, route, outcome:             string,
	status, duration, received, sent:   int,
}

// started, completed, active and timeouts of a "snapshot" or "metrics" line.
Metrics :: struct {
	started, completed, active, timeouts: int,
}

// Zero leaves a timeout at the server's minute.
Timeouts :: struct {
	header, body, response, idle: time.Duration,
}

Server :: struct {
	p:     ^harness.Process,
	input: ^os.File,
	port:  int,
}

launch :: proc(t: ^testing.T, binary: string, timeouts: Timeouts) -> (s: Server, ok: bool) {
	env := make([dynamic]string, context.temp_allocator)
	names := [4]string{"HEADER", "BODY", "RESPONSE", "IDLE"}
	for duration, index in ([4]time.Duration{timeouts.header, timeouts.body, timeouts.response, timeouts.idle}) {
		if duration > 0 {
			append(&env, fmt.tprintf("SABA_OBSERVE_%s_MS=%d", names[index], duration / time.Millisecond))
		}
	}
	s.p, s.input = harness.start_with_input(t, {binary}, env[:]) or_return
	s.port, ok = harness.ready(t, s.p)
	if !ok {
		dispose(&s)
	}
	return
}

dispose :: proc(s: ^Server) {
	if s.p == nil {
		return
	}
	harness.stop(s.p)
	os.close(s.input)
	s^ = {}
}

parse_event :: proc(line: string) -> Event {
	fields := strings.fields(line, context.temp_allocator)
	if len(fields) != 9 {
		return {}
	}
	return {
		id = number(fields[1]),
		method = fields[2],
		route = fields[3],
		status = number(fields[4]),
		duration = number(fields[5]),
		received = number(fields[6]),
		sent = number(fields[7]),
		outcome = fields[8],
	}
}

number :: proc(text: string) -> int {
	value, _ := strconv.parse_int(text)
	return value
}

parse_metrics :: proc(t: ^testing.T, line: string) -> (m: Metrics, ok: bool) {
	fields := strings.fields(line, context.temp_allocator)
	testing.expectf(t, len(fields) == 8, "metrics: %q", line) or_return
	return {number(fields[1]), number(fields[2]), number(fields[3]), number(fields[4])}, true
}

// The server's metrics now.
snapshot :: proc(t: ^testing.T, s: ^Server) -> (m: Metrics, ok: bool) {
	harness.send_input(t, s.input, "m") or_return
	line := harness.expect_line(t, s.p, "snapshot ") or_return
	return parse_metrics(t, line)
}

// Waits until the server has reported count requests complete and returns
// their events in request order.
events :: proc(t: ^testing.T, s: ^Server, count: int, loc := #caller_location) -> (found: []Event, ok: bool) {
	harness.await_lines(t, s.p, "event ", count, loc = loc) or_return
	lines := harness.lines_with(s.p, "event ")
	found = make([]Event, len(lines), context.temp_allocator)
	for line, index in lines {
		found[index] = parse_event(line)
	}
	slice.sort_by(found, proc(a, b: Event) -> bool {return a.id < b.id})
	return found, true
}

// Stops the server and returns the metrics it printed on the way out.
finish :: proc(t: ^testing.T, s: ^Server) -> (m: Metrics, ok: bool) {
	harness.send_input(t, s.input, "\n") or_return
	harness.exited_cleanly(t, s.p) or_return
	lines := harness.lines_with(s.p, "metrics ")
	testing.expect(t, len(lines) == 1, "no metrics line") or_return
	return parse_metrics(t, lines[0])
}

// Sends wire on a new connection and reads the answer until the server closes.
exchange :: proc(t: ^testing.T, port: int, wire: string) -> string {
	conn, error := harness.dial(port)
	if !testing.expectf(t, error == nil, "connect: %v", error) {
		return ""
	}
	defer net.close(conn)
	harness.send_text(conn, wire)
	result, _ := harness.read_to_close(conn)
	return string(result)
}

@(test)
events_timeouts_and_metrics :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Minute)
	work := harness.workdir(t, "observability")
	defer os.remove_all(work)
	built, ok := harness.build(t, "tests/e2e/observability/server", work)
	if !ok {
		return
	}
	// Scenarios free temporary memory between them; the path must outlive that.
	binary := strings.clone(built)
	defer delete(binary)
	if !outcomes(t, binary) {
		return
	}
	free_all(context.temp_allocator)
	if !header_deadline(t, binary) {
		return
	}
	free_all(context.temp_allocator)
	idle_deadline(t, binary)
}

// Completed and rejected requests, the body and response deadlines, and a
// request cancelled by shutdown. The header and idle deadlines of this server
// are a minute away, so how long a client takes to connect and send decides
// nothing.
outcomes :: proc(t: ^testing.T, binary: string) -> bool {
	s := launch(t, binary, {body = BODY, response = RESPONSE}) or_return
	defer dispose(&s)
	requests := make([dynamic]Expected, context.temp_allocator)

	// The path, query and request ID are the client's; none may reach an event.
	good := "GET /items/private-id?token=secret HTTP/1.1\r\nHost: localhost\r\nX-Request-ID: secret-id\r\n\r\n"
	result := exchange(t, s.port, good)
	testing.expectf(t, strings.has_prefix(result, "HTTP/1.1 200 ") && strings.has_suffix(result, "ok"), "GET: %q", result)
	append(&requests, Expected{"GET", "Completed", len(good), len(result)})

	head := "HEAD /items/private-id HTTP/1.1\r\nHost: localhost\r\n\r\n"
	result = exchange(t, s.port, head)
	testing.expectf(t, strings.has_suffix(result, "\r\n\r\n") && strings.contains(result, "Content-Length: 2\r\n"), "HEAD: %q", result)
	append(&requests, Expected{"HEAD", "Completed", len(head), len(result)})

	malformed := "GET /items/private-id HTTP/1.1\r\n\r\n"
	result = exchange(t, s.port, malformed)
	testing.expectf(t, strings.has_prefix(result, "HTTP/1.1 400 "), "no Host: %q", result)
	append(&requests, Expected{"GET", "Protocol_Error", len(malformed), len(result)})

	// A body that stops arriving is answered at the body deadline, which starts
	// once the head is read: never sooner than BODY after the client began. No
	// other deadline of this server is near, so the 408 is the body deadline's.
	{
		partial := "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3\r\n\r\na"
		began := time.tick_now()
		result = exchange(t, s.port, partial)
		elapsed := time.tick_since(began)
		testing.expectf(t, strings.has_prefix(result, "HTTP/1.1 408 ") && elapsed >= BODY, "body deadline: %v %q", elapsed, result)
		append(&requests, Expected{"POST", "Timeout", len(partial), len(result)})
	}

	// A reader that does not read is cut off part way through an 8 MiB body.
	// It reads nothing until the server has reported the request finished, so
	// the server gave up on its own, and not sooner than RESPONSE after the
	// client began.
	{
		conn, _ := harness.dial(s.port)
		defer net.close(conn)
		_ = net.set_option(conn, .Receive_Buffer_Size, 8192)
		wire := "GET /large HTTP/1.1\r\nHost: localhost\r\n\r\n"
		began := time.tick_now()
		harness.send_text(conn, wire)
		harness.await_lines(t, s.p, "event ", len(requests) + 1) or_return
		elapsed := time.tick_since(began)
		received, _ := harness.read_to_close(conn, 8 * 1024 * 1024)
		data := string(received)
		testing.expectf(
			t,
			strings.has_prefix(data, "HTTP/1.1 200 ") && len(data) < 8 * 1024 * 1024 && elapsed >= RESPONSE,
			"write deadline: %v, %d bytes, %q",
			elapsed,
			len(data),
			data[:min(60, len(data))],
		)
		append(&requests, Expected{"GET", "Timeout", len(wire), len(data)})
	}

	// Every attempt above has completed, not merely been sent.
	seen := events(t, &s, len(requests)) or_return
	testing.expectf(t, len(seen) == len(requests), "%d events for %d requests", len(seen), len(requests)) or_return
	for event, index in seen {
		expected := requests[index]
		testing.expectf(
			t,
			event.method == expected.method &&
			event.outcome == expected.outcome &&
			event.received == expected.received &&
			event.sent == expected.sent,
			"event %v, expected %v",
			event,
			expected,
		)
		testing.expect(t, event.duration >= 0)
	}
	testing.expect_value(t, seen[0].route, "/items/:id")
	testing.expect_value(t, seen[1].route, "/items/:id")
	testing.expectf(t, seen[3].duration >= int(BODY), "the body deadline ended a request of %v", time.Duration(seen[3].duration))
	testing.expectf(t, seen[4].duration >= int(RESPONSE), "the response deadline ended a request of %v", time.Duration(seen[4].duration))
	for line in harness.lines_with(s.p, "event ") {
		testing.expectf(t, !strings.contains(line, "private-id") && !strings.contains(line, "secret"), "leaked: %q", line)
	}

	// A parked request cancelled by shutdown still completes exactly once. The
	// server is stopped only after it reports the request active: it has read
	// the byte.
	parked, _ := harness.dial(s.port)
	defer net.close(parked)
	harness.send_text(parked, "G")
	deadline := time.tick_add(time.tick_now(), 10 * time.Second)
	for {
		now := snapshot(t, &s) or_return
		if now.active == 1 {
			break
		}
		testing.expectf(t, time.tick_since(deadline) < 0, "the parked request never became active: %v", now) or_return
		time.sleep(2 * time.Millisecond)
	}
	m := finish(t, &s) or_return
	every := harness.lines_with(s.p, "event ")
	if !testing.expectf(t, len(every) == len(requests) + 1 && strings.has_suffix(every[len(every) - 1], "Cancelled"), "events: %v", every) {
		return false
	}
	ids := make(map[int]bool, context.temp_allocator)
	for line in every {
		id := parse_event(line).id
		testing.expectf(t, id != 0 && !(id in ids), "request id %d reused or zero", id)
		ids[id] = true
	}
	// The metrics are printed before the stop: the parked request is active.
	// Body and write timeouts.
	return testing.expectf(
		t,
		m == Metrics{started = len(every), completed = len(requests), active = 1, timeouts = 2},
		"metrics %v with %d events",
		m,
		len(every),
	)
}

// One byte of a head that never ends, every PACE, until the server answers.
// status is 0 when no answer came. stall is the longest the server can have
// been without a new byte: from before the connect to the first byte sent,
// and from before one byte left to after the next one did.
Trickle :: struct {
	answer:         string,
	sent:           int,
	elapsed, stall: time.Duration,
}

PACE :: 60 * time.Millisecond
SLOW_HEAD :: "GET /items/private-id HTTP/1.1\r\nHost: localhost\r\nX-Slow: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

trickle :: proc(t: ^testing.T, port: int) -> (r: Trickle, ok: bool) {
	began := time.tick_now()
	conn := harness.connect(t, port) or_return
	defer net.close(conn)
	_ = net.set_option(conn, .Receive_Timeout, PACE)
	answer := make([dynamic]u8, context.temp_allocator)
	buffer: [4096]u8
	before := began
	head := string(SLOW_HEAD)
	for r.sent < len(head) {
		leaving := time.tick_now()
		if !harness.send_text(conn, head[r.sent:r.sent + 1]) {
			break
		}
		r.stall = max(r.stall, time.tick_diff(before, time.tick_now()))
		before = leaving
		r.sent += 1
		// The pause between bytes ends early when the answer arrives.
		n, error := net.recv_tcp(conn, buffer[:])
		if error == nil && n > 0 {
			append(&answer, ..buffer[:n])
			break
		}
		if error != .Timeout && error != .Would_Block {
			break
		}
	}
	_ = net.set_option(conn, .Receive_Timeout, 5 * time.Second)
	rest, _ := harness.read_to_close(conn)
	append(&answer, ..rest)
	r.elapsed = time.tick_since(began)
	r.answer = string(answer[:])
	return r, true
}

// Bytes that keep arriving do not extend the header deadline, which runs from
// the accept: a head that trickles in is answered 408 never sooner than
// HEADER after the client began to connect, and while its bytes still arrive
// less than HEADER apart. A server that extended the deadline with each byte
// would not answer such a client at all, so the answer is the upper bound.
// A client that was itself held up for HEADER between two bytes has shown
// nothing; it is checked like the others and the attempt is made again.
header_deadline :: proc(t: ^testing.T, binary: string) -> bool {
	s := launch(t, binary, {header = HEADER}) or_return
	defer dispose(&s)
	attempts := 0
	shown := false
	for !shown {
		testing.expectf(t, attempts < 8, "no client in %d kept its bytes less than %v apart", attempts, HEADER) or_return
		attempts += 1
		r := trickle(t, s.port) or_return
		testing.expectf(
			t,
			strings.has_prefix(r.answer, "HTTP/1.1 408 ") && r.elapsed >= HEADER && r.sent < len(SLOW_HEAD),
			"header deadline: %d bytes sent in %v, %q",
			r.sent,
			r.elapsed,
			r.answer,
		) or_return
		seen := events(t, &s, attempts) or_return
		event := seen[attempts - 1]
		testing.expectf(
			t,
			event.method == "OTHER" &&
			event.outcome == "Timeout" &&
			event.status == 408 &&
			event.received >= 1 &&
			event.received <= r.sent &&
			event.sent == len(r.answer),
			"event %v after %d bytes sent and %d received",
			event,
			r.sent,
			len(r.answer),
		) or_return
		shown = r.stall < HEADER
	}
	m := finish(t, &s) or_return
	return testing.expectf(
		t,
		m == Metrics{started = attempts, completed = attempts, timeouts = attempts},
		"metrics %v after %d attempts",
		m,
		attempts,
	)
}

// A connection that never sends a byte is answered at the idle deadline, never
// sooner than IDLE after the client began to connect, but is not a request: no
// event, and nothing counted. The idle deadline is the only short one here and
// the header deadline only starts to matter with a first byte, so the 408 is
// the idle deadline's.
idle_deadline :: proc(t: ^testing.T, binary: string) -> bool {
	s := launch(t, binary, {idle = IDLE}) or_return
	defer dispose(&s)
	{
		began := time.tick_now()
		conn := harness.connect(t, s.port) or_return
		defer net.close(conn)
		buffer: [8192]u8
		n, _ := net.recv_tcp(conn, buffer[:])
		elapsed := time.tick_since(began)
		testing.expectf(
			t,
			strings.has_prefix(string(buffer[:n]), "HTTP/1.1 408 ") && elapsed >= IDLE,
			"idle deadline: %v %q",
			elapsed,
			string(buffer[:n]),
		) or_return
		rest, _ := harness.read_to_close(conn)
		testing.expect_value(t, string(rest), "") or_return
	}
	m := finish(t, &s) or_return
	found := harness.lines_with(s.p, "event ")
	return testing.expectf(t, len(found) == 0 && m == Metrics{}, "a silent connection was reported: %v %v", m, found)
}
