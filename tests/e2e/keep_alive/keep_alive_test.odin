// Bounded HTTP/1 persistence, driven over raw sockets: request boundaries on
// one connection, exact byte accounting per request, close tokens, limits,
// idle and header deadlines, admission capacity, drain and shutdown. The same
// corpus runs against the full facade (shared:saba) and lean core.
package saba_e2e_keep_alive_test

import "core:fmt"
import "core:net"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import harness "../../support/harness"

FULL :: "tests/fixtures/apps/keep_alive"
CORE :: "tests/e2e/keep_alive/core_server"

@(test)
keep_alive :: proc(t: ^testing.T) {
	corpus(t, FULL)
}

@(test)
keep_alive_core :: proc(t: ^testing.T) {
	corpus(t, CORE)
}

corpus :: proc(t: ^testing.T, source: string) {
	testing.set_fail_timeout(t, 4 * time.Minute)
	work := harness.workdir(t, "keep-alive")
	defer os.remove_all(work)
	built, ok := harness.build(t, source, work)
	if !ok {
		return
	}
	// Scenarios free temporary memory between them; the path must outlive that.
	binary := strings.clone(built)
	defer delete(binary)
	scenarios := []proc(t: ^testing.T, binary: string) -> bool {
		disabled_closes,
		sequential_requests,
		coalesced_pipeline,
		grown_head_storage,
		arena_released,
		max_requests,
		close_tokens,
		bad_next_request,
		eof_inside_next_body,
		idle_inherits_budget,
		next_header_deadline,
		partial_next_request,
		idle_capacity,
		drain_wakes_idle,
		drain_admitted_body,
		handler_drain,
		observer_drain,
		shutdown_idle,
		drain_races_admission,
	}
	for scenario in scenarios {
		if !scenario(t, binary) {
			return
		}
		free_all(context.temp_allocator)
	}
}

Server :: struct {
	process:  ^harness.Process,
	input:    ^os.File,
	port:     int,
	finished: bool,
}

// settings are SABA_KEEP_<NAME>=<value> pairs for the fixture.
launch :: proc(t: ^testing.T, binary: string, settings: ..string) -> (s: Server, ok: bool) {
	env := make([dynamic]string, context.temp_allocator)
	for setting in settings {
		append(&env, fmt.tprintf("SABA_KEEP_%s", setting))
	}
	s.process, s.input = harness.start_with_input(t, {binary}, env[:]) or_return
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

Event :: struct {
	id:                    int,
	method, route:         string,
	status:                int,
	received, sent:        int,
	outcome:               string,
}

events :: proc(s: ^Server) -> []Event {
	result := make([dynamic]Event, context.temp_allocator)
	for line in harness.lines_with(s.process, "event ") {
		p := strings.fields(line, context.temp_allocator)
		if len(p) < 8 {
			continue
		}
		e := Event{method = p[2], route = p[3], outcome = p[7]}
		e.id, _ = strconv.parse_int(p[1])
		e.status, _ = strconv.parse_int(p[4])
		e.received, _ = strconv.parse_int(p[5])
		e.sent, _ = strconv.parse_int(p[6])
		append(&result, e)
	}
	slice.sort_by(result[:], proc(a, b: Event) -> bool {return a.id < b.id})
	return result[:]
}

// Stops the fixture with mode ("" sends nothing: a drain already ends it) and
// checks that it reported one completion per event, each with its own ID.
finish :: proc(t: ^testing.T, s: ^Server, mode := "s", loc := #caller_location) -> bool {
	if s.finished {
		return true
	}
	s.finished = true
	if mode != "" {
		harness.send_input(t, s.input, mode, loc) or_return
	}
	harness.exited_cleanly(t, s.process, loc = loc) or_return
	stopped := harness.lines_with(s.process, "stopped ")
	if !testing.expectf(t, len(stopped) == 1, "no stopped line\n%s", harness.transcript(s.process), loc = loc) {
		return false
	}
	count, _ := strconv.parse_int(stopped[0][len("stopped "):])
	all := events(s)
	testing.expectf(t, count == len(all), "stopped %d but %d events", count, len(all), loc = loc) or_return
	for e, i in all {
		testing.expectf(t, e.id != 0, "event without an ID: %v", e, loc = loc) or_return
		if i > 0 {
			testing.expectf(t, e.id != all[i - 1].id, "duplicate event ID %d", e.id, loc = loc) or_return
		}
	}
	return true
}

expect_events :: proc(t: ^testing.T, s: ^Server, count: int, loc := #caller_location) -> bool {
	n := len(events(s))
	return testing.expectf(t, n == count, "%d events, want %d\n%s", n, count, harness.transcript(s.process), loc = loc)
}

request :: harness.request_wire

// A response with the status wanted and, when connection is set, that exact
// Connection field.
expect_response :: proc(
	t: ^testing.T,
	conn: net.TCP_Socket,
	status := 200,
	connection := "",
	head_only := false,
	loc := #caller_location,
) -> (
	r: harness.Response,
	ok: bool,
) {
	r = harness.read_response(t, conn, head_only, loc) or_return
	testing.expectf(t, r.status == status, "status %d, want %d\n%s", r.status, status, r.head, loc = loc) or_return
	if connection != "" {
		line := fmt.tprintf("Connection: %s", connection)
		testing.expectf(t, harness.has_field(r.head, line), "no %q in\n%s", line, r.head, loc = loc) or_return
	}
	return r, true
}

// Default disabled means the next already-buffered request is never admitted.
disabled_closes :: proc(t: ^testing.T, binary: string) -> bool {
	s := launch(t, binary, "DISABLED=1") or_return
	defer dispose(&s)
	conn := harness.connect(t, s.port) or_return
	defer net.close(conn)
	harness.send_text(conn, strings.concatenate({request(), request()}, context.temp_allocator))
	expect_response(t, conn, 200, "close") or_return
	harness.expect_closed(t, conn) or_return
	finish(t, &s) or_return
	return expect_events(t, &s, 1)
}

// Same socket: body framing, HEAD and fresh IDs/state for successive requests,
// exact consumed-byte metrics, and EOF adds no event.
sequential_requests :: proc(t: ^testing.T, binary: string) -> bool {
	s := launch(t, binary, "IDLE_MS=500") or_return
	defer dispose(&s)
	expected, received: [4]int
	{
		conn := harness.connect(t, s.port) or_return
		defer net.close(conn)
		wires := [4]string{request("/id"), request("/echo", "POST", "body"), request("/id", "HEAD"), request("/id")}
		for wire, i in wires {
			harness.send_text(conn, wire)
			r := expect_response(t, conn, 200, "keep-alive", head_only = i == 2) or_return
			expected[i] = len(wire)
			received[i] = len(r.head) + len(r.body)
		}
		harness.shutdown_write(conn)
		harness.expect_closed(t, conn) or_return
	}
	finish(t, &s) or_return
	expect_events(t, &s, 4) or_return
	for e, i in events(&s) {
		testing.expectf(t, e.received == expected[i] && e.sent == received[i], "event %d: %v, want received %d sent %d", i, e, expected[i], received[i]) or_return
	}
	return true
}

// Coalesced requests with a preceding body cannot consume the next message.
coalesced_pipeline :: proc(t: ^testing.T, binary: string) -> bool {
	s := launch(t, binary, "IDLE_MS=500") or_return
	defer dispose(&s)
	wires := [3]string{request("/echo", "POST", "abc"), request("/id"), request("/id", fields = "Connection: close\r\n")}
	answers: [3]harness.Response
	{
		conn := harness.connect(t, s.port) or_return
		defer net.close(conn)
		harness.send_text(conn, strings.concatenate(wires[:], context.temp_allocator))
		for &answer in answers {
			answer = expect_response(t, conn) or_return
		}
		testing.expect(t, string(answers[0].body) == "abc") or_return
		testing.expectf(t, string(answers[1].body) != string(answers[2].body), "two requests shared ID %s", answers[1].body) or_return
		testing.expect(t, harness.has_field(answers[2].head, "Connection: close")) or_return
		harness.expect_closed(t, conn) or_return
	}
	finish(t, &s) or_return
	expect_events(t, &s, 3) or_return
	for e, i in events(&s) {
		sent := len(answers[i].head) + len(answers[i].body)
		testing.expectf(t, e.received == len(wires[i]) && e.sent == sent, "event %d: %v", i, e) or_return
	}
	return true
}

// A head larger than the initial 512 bytes and a fragmented next request
// survive the arena reset.
grown_head_storage :: proc(t: ^testing.T, binary: string) -> bool {
	s := launch(t, binary, "IDLE_MS=500") or_return
	defer dispose(&s)
	{
		conn := harness.connect(t, s.port) or_return
		defer net.close(conn)
		pad := strings.repeat("x", 6000, context.temp_allocator)
		first := request("/id", fields = fmt.tprintf("X-Pad: %s\r\n", pad))
		following := request("/id", fields = "Connection: close\r\n")
		harness.send_text(conn, strings.concatenate({first, following[:7]}, context.temp_allocator))
		expect_response(t, conn) or_return
		harness.send_text(conn, following[7:])
		expect_response(t, conn) or_return
		harness.expect_closed(t, conn) or_return
	}
	finish(t, &s) or_return
	return expect_events(t, &s, 2)
}

// Old 1 MiB response blocks are gone before the next handler starts (the
// fixture asserts on /arena).
arena_released :: proc(t: ^testing.T, binary: string) -> bool {
	s := launch(t, binary, "IDLE_MS=500") or_return
	defer dispose(&s)
	{
		conn := harness.connect(t, s.port) or_return
		defer net.close(conn)
		for _ in 0 ..< 5 {
			harness.send_text(conn, strings.concatenate({request("/allocate"), request("/arena")}, context.temp_allocator))
			large := expect_response(t, conn) or_return
			testing.expect_value(t, len(large.body), 1024 * 1024) or_return
			expect_response(t, conn) or_return
		}
		harness.shutdown_write(conn)
		harness.expect_closed(t, conn) or_return
	}
	finish(t, &s) or_return
	return expect_events(t, &s, 10)
}

// max_requests advertises close on the last response and never dispatches an
// extra pipelined request.
max_requests :: proc(t: ^testing.T, binary: string) -> bool {
	s := launch(t, binary, "MAX=3", "IDLE_MS=500") or_return
	defer dispose(&s)
	{
		conn := harness.connect(t, s.port) or_return
		defer net.close(conn)
		harness.send_text(conn, strings.repeat(request(), 4, context.temp_allocator))
		for n in 0 ..< 3 {
			r := expect_response(t, conn) or_return
			closes := harness.has_field(r.head, "Connection: close")
			testing.expectf(t, closes == (n == 2), "response %d: close=%v", n, closes) or_return
		}
		harness.expect_closed(t, conn) or_return
	}
	finish(t, &s) or_return
	return expect_events(t, &s, 3)
}

// Mixed-case comma-list and duplicate close tokens, and a handler-forced
// close, end persistence.
close_tokens :: proc(t: ^testing.T, binary: string) -> bool {
	cases := [][2]string {
		{"/id", "cOnNeCtIoN: upgrade, cLoSe\r\n"},
		{"/close", ""},
		{"/id", "Connection: keep-alive\r\nConnection: close\r\n"},
	}
	for c in cases {
		s := launch(t, binary, "IDLE_MS=500") or_return
		defer dispose(&s)
		{
			conn := harness.connect(t, s.port) or_return
			defer net.close(conn)
			harness.send_text(conn, strings.concatenate({request(c[0], fields = c[1]), request()}, context.temp_allocator))
			expect_response(t, conn, 200, "close") or_return
			harness.expect_closed(t, conn) or_return
		}
		finish(t, &s) or_return
		expect_events(t, &s, 1) or_return
	}
	return true
}

// Malformed or over-limit next requests close safely with no parser, header
// or body state bleeding into them.
bad_next_request :: proc(t: ^testing.T, binary: string) -> bool {
	cases := []struct {
		wire:   string,
		status: int,
	}{{"GET /id HTTP/1.1\r\n\r\n", 400}, {request("/limited", "POST", "12345"), 413}}
	for c in cases {
		s := launch(t, binary, "IDLE_MS=500") or_return
		defer dispose(&s)
		{
			conn := harness.connect(t, s.port) or_return
			defer net.close(conn)
			harness.send_text(conn, strings.concatenate({request(), c.wire, request()}, context.temp_allocator))
			expect_response(t, conn) or_return
			expect_response(t, conn, c.status, "close") or_return
			harness.expect_closed(t, conn) or_return
		}
		finish(t, &s) or_return
		expect_events(t, &s, 2) or_return
	}
	return true
}

// EOF inside a subsequent body answers 400, keeps partial-byte accounting and
// cannot reuse ambiguous framing.
eof_inside_next_body :: proc(t: ^testing.T, binary: string) -> bool {
	s := launch(t, binary, "IDLE_MS=500") or_return
	defer dispose(&s)
	{
		conn := harness.connect(t, s.port) or_return
		defer net.close(conn)
		harness.send_text(conn, request())
		expect_response(t, conn) or_return
		wire := request("/echo", "POST", "abcdef")
		harness.send_text(conn, wire[:len(wire) - 3])
		harness.shutdown_write(conn)
		expect_response(t, conn, 400, "close") or_return
		harness.expect_closed(t, conn) or_return
	}
	finish(t, &s) or_return
	expect_events(t, &s, 2) or_return
	all := events(&s)
	return testing.expect_value(t, all[1].outcome, "Peer_Closed")
}

// Idle zero inherits the configured idle budget (100 ms) and closes silently
// without a phantom completion.
idle_inherits_budget :: proc(t: ^testing.T, binary: string) -> bool {
	s := launch(t, binary) or_return
	defer dispose(&s)
	{
		conn := harness.connect(t, s.port) or_return
		defer net.close(conn)
		harness.send_text(conn, request())
		expect_response(t, conn) or_return
		started := time.tick_now()
		harness.expect_closed(t, conn) or_return
		elapsed := time.tick_since(started)
		testing.expectf(t, elapsed > 40 * time.Millisecond && elapsed < 600 * time.Millisecond, "idle close after %v", elapsed) or_return
	}
	finish(t, &s) or_return
	return expect_events(t, &s, 1)
}

// The next header deadline starts on its first byte, independently of the
// preceding idle interval.
next_header_deadline :: proc(t: ^testing.T, binary: string) -> bool {
	s := launch(t, binary, "IDLE_MS=500") or_return
	defer dispose(&s)
	{
		conn := harness.connect(t, s.port) or_return
		defer net.close(conn)
		harness.send_text(conn, request())
		expect_response(t, conn) or_return
		time.sleep(250 * time.Millisecond)
		harness.send_text(conn, request(fields = "Connection: close\r\n"))
		expect_response(t, conn) or_return
		harness.expect_closed(t, conn) or_return
	}
	finish(t, &s) or_return
	return expect_events(t, &s, 2)
}

// A partial subsequent request uses its own total header deadline and closes
// on timeout.
partial_next_request :: proc(t: ^testing.T, binary: string) -> bool {
	s := launch(t, binary, "IDLE_MS=500") or_return
	defer dispose(&s)
	{
		conn := harness.connect(t, s.port) or_return
		defer net.close(conn)
		harness.send_text(conn, request())
		expect_response(t, conn) or_return
		harness.send_text(conn, "G")
		expect_response(t, conn, 408) or_return
		harness.expect_closed(t, conn) or_return
	}
	finish(t, &s) or_return
	expect_events(t, &s, 2) or_return
	all := events(&s)
	return testing.expect_value(t, all[1].outcome, "Timeout")
}

// Idle connections stay bounded by admission capacity, and overload recovers
// after one closes.
idle_capacity :: proc(t: ^testing.T, binary: string) -> bool {
	s := launch(t, binary, "IDLE_MS=500", "CAPACITY=2") or_return
	defer dispose(&s)
	one := harness.connect(t, s.port) or_return
	two, ok := harness.connect(t, s.port)
	if !ok {
		net.close(one)
		return false
	}
	defer net.close(two)
	for conn in ([]net.TCP_Socket{one, two}) {
		harness.send_text(conn, request())
		expect_response(t, conn) or_return
	}
	{
		extra := harness.connect(t, s.port) or_return
		defer net.close(extra)
		expect_response(t, extra, 503) or_return
		harness.expect_closed(t, extra) or_return
	}
	net.close(one)
	time.sleep(20 * time.Millisecond)
	{
		extra := harness.connect(t, s.port) or_return
		defer net.close(extra)
		harness.send_text(extra, request(fields = "Connection: close\r\n"))
		expect_response(t, extra) or_return
		harness.expect_closed(t, extra) or_return
	}
	finish(t, &s) or_return
	return expect_events(t, &s, 3)
}

drain :: proc(t: ^testing.T, s: ^Server) -> bool {
	harness.send_input(t, s.input, "d") or_return
	return harness.await_lines(t, s.process, "draining")
}

// Drain wakes idle sockets promptly rather than on a polling tick, and emits
// no duplicate event.
drain_wakes_idle :: proc(t: ^testing.T, binary: string) -> bool {
	s := launch(t, binary, "IDLE_MS=500") or_return
	defer dispose(&s)
	{
		conn := harness.connect(t, s.port) or_return
		defer net.close(conn)
		harness.send_text(conn, request())
		expect_response(t, conn) or_return
		started := time.tick_now()
		drain(t, &s) or_return
		harness.expect_closed(t, conn) or_return
		elapsed := time.tick_since(started)
		testing.expectf(t, elapsed < 200 * time.Millisecond, "drain closed the idle socket after %v", elapsed) or_return
	}
	finish(t, &s, "") or_return
	return expect_events(t, &s, 1)
}

// A second request admitted before the drain may finish its body, then the
// connection closes instead of admitting another.
drain_admitted_body :: proc(t: ^testing.T, binary: string) -> bool {
	s := launch(t, binary, "IDLE_MS=500") or_return
	defer dispose(&s)
	{
		conn := harness.connect(t, s.port) or_return
		defer net.close(conn)
		harness.send_text(conn, request())
		expect_response(t, conn) or_return
		wire := request("/echo", "POST", "abcdef")
		harness.send_text(conn, wire[:len(wire) - 3])
		time.sleep(20 * time.Millisecond)
		drain(t, &s) or_return
		harness.send_text(conn, "def")
		r := expect_response(t, conn, 200, "close") or_return
		testing.expect_value(t, string(r.body), "abcdef") or_return
		harness.expect_closed(t, conn) or_return
	}
	finish(t, &s, "") or_return
	expect_events(t, &s, 2) or_return
	for e in events(&s) {
		testing.expect_value(t, e.outcome, "Completed") or_return
	}
	return true
}

// A handler-initiated drain rejects unread pipelined requests after the
// current response.
handler_drain :: proc(t: ^testing.T, binary: string) -> bool {
	s := launch(t, binary, "IDLE_MS=500") or_return
	defer dispose(&s)
	{
		conn := harness.connect(t, s.port) or_return
		defer net.close(conn)
		harness.send_text(conn, strings.concatenate({request("/drain"), request()}, context.temp_allocator))
		expect_response(t, conn, 200, "close") or_return
		harness.expect_closed(t, conn) or_return
	}
	finish(t, &s, "j") or_return
	return expect_events(t, &s, 1)
}

// A drain started by the completion observer closes a connection that already
// advertised persistence, before the unread pipelined request is admitted.
observer_drain :: proc(t: ^testing.T, binary: string) -> bool {
	s := launch(t, binary, "IDLE_MS=500", "OBSERVER_DRAIN=1") or_return
	defer dispose(&s)
	{
		conn := harness.connect(t, s.port) or_return
		defer net.close(conn)
		harness.send_text(conn, strings.concatenate({request(), request()}, context.temp_allocator))
		expect_response(t, conn, 200, "keep-alive") or_return
		harness.expect_closed(t, conn) or_return
	}
	finish(t, &s, "j") or_return
	return expect_events(t, &s, 1)
}

// Immediate shutdown closes idle persistence without a new request or a
// leaked task.
shutdown_idle :: proc(t: ^testing.T, binary: string) -> bool {
	s := launch(t, binary, "IDLE_MS=500") or_return
	defer dispose(&s)
	conn := harness.connect(t, s.port) or_return
	defer net.close(conn)
	harness.send_text(conn, request())
	expect_response(t, conn) or_return
	finish(t, &s) or_return
	harness.expect_closed(t, conn) or_return
	return expect_events(t, &s, 1)
}

Racer :: struct {
	conn:   net.TCP_Socket,
	failed: string,
}

// The next request races the drain: it is served in full or the connection
// ends; anything else (a wrong status, bytes after the response) fails.
race :: proc(r: ^Racer) {
	harness.send_text(r.conn, request("/slow"))
	head := make([dynamic]u8, context.temp_allocator)
	one: [1]u8
	for !strings.has_suffix(string(head[:]), "\r\n\r\n") {
		if harness.read_exact(r.conn, one[:]) != .Ok {
			return
		}
		append(&head, one[0])
	}
	if harness.status_of(string(head[:])) != 200 {
		r.failed = "status"
		return
	}
	length := 0
	if value, found := harness.field(string(head[:]), "Content-Length"); found {
		length, _ = strconv.parse_int(value)
	}
	body := make([]u8, length, context.temp_allocator)
	if harness.read_exact(r.conn, body) != .Ok {
		return
	}
	switch harness.read_exact(r.conn, one[:]) {
	case .Eof, .Reset, .Failed:
	case .Ok, .Timeout:
		r.failed = "connection survived"
	}
}

// Concurrent next-request admission races drain without idle-list lifetime
// leaks or duplicate IDs.
drain_races_admission :: proc(t: ^testing.T, binary: string) -> bool {
	s := launch(t, binary, "IDLE_MS=500") or_return
	defer dispose(&s)
	racers: [12]Racer
	opened := 0
	defer for r in racers[:opened] {
		net.close(r.conn)
	}
	for &r in racers {
		r.conn = harness.connect(t, s.port) or_return
		opened += 1
		harness.send_text(r.conn, request())
		expect_response(t, r.conn) or_return
	}
	threads: [12]^thread.Thread
	for &r, i in racers {
		threads[i] = thread.create_and_start_with_poly_data(&r, race)
	}
	time.sleep(10 * time.Millisecond)
	drained := drain(t, &s)
	for worker in threads {
		thread.join(worker)
		thread.destroy(worker)
	}
	drained or_return
	for r, i in racers {
		testing.expectf(t, r.failed == "", "racer %d: %s", i, r.failed) or_return
	}
	finish(t, &s, "") or_return
	all := events(&s)
	testing.expectf(t, len(all) >= 12, "%d events", len(all)) or_return
	for e in all {
		testing.expect_value(t, e.outcome, "Completed") or_return
	}
	return true
}

