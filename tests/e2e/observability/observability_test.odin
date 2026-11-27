// Request events and metrics of a server with short timeouts, checked against
// the exact bytes each raw loopback client put on the wire and got back.
package saba_e2e_observability_test

import "core:net"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"
import harness "../../support/harness"

Expected :: struct {
	method, outcome: string,
	received, sent:  int,
}

Event :: struct {
	id:                                 int,
	method, route, outcome:             string,
	status, duration, received, sent:   int,
}

parse_event :: proc(line: string) -> Event {
	fields := strings.fields(line, context.temp_allocator)
	if len(fields) != 9 {
		return {}
	}
	number :: proc(text: string) -> int {
		value, _ := strconv.parse_int(text)
		return value
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

within :: proc(elapsed: time.Duration, low, high: time.Duration) -> bool {
	return elapsed > low && elapsed < high
}

@(test)
events_timeouts_and_metrics :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 2 * time.Minute)
	work := harness.workdir(t, "observability")
	defer os.remove_all(work)
	binary, built := harness.build(t, "tests/e2e/observability/server", work)
	if !built {
		return
	}
	p, input, started := harness.start_with_input(t, {binary})
	if !started {
		return
	}
	defer {
		harness.stop(p)
		os.close(input)
	}
	port, ready := harness.ready(t, p)
	if !ready {
		return
	}
	requests := make([dynamic]Expected, context.temp_allocator)

	// The path, query and request ID are the client's; none may reach an event.
	good := "GET /items/private-id?token=secret HTTP/1.1\r\nHost: localhost\r\nX-Request-ID: secret-id\r\n\r\n"
	result := exchange(t, port, good)
	testing.expectf(t, strings.has_prefix(result, "HTTP/1.1 200 ") && strings.has_suffix(result, "ok"), "GET: %q", result)
	append(&requests, Expected{"GET", "Completed", len(good), len(result)})

	head := "HEAD /items/private-id HTTP/1.1\r\nHost: localhost\r\n\r\n"
	result = exchange(t, port, head)
	testing.expectf(t, strings.has_suffix(result, "\r\n\r\n") && strings.contains(result, "Content-Length: 2\r\n"), "HEAD: %q", result)
	append(&requests, Expected{"HEAD", "Completed", len(head), len(result)})

	malformed := "GET /items/private-id HTTP/1.1\r\n\r\n"
	result = exchange(t, port, malformed)
	testing.expectf(t, strings.has_prefix(result, "HTTP/1.1 400 "), "no Host: %q", result)
	append(&requests, Expected{"GET", "Protocol_Error", len(malformed), len(result)})

	// Bytes that keep arriving do not extend the 200 ms header deadline.
	{
		conn, _ := harness.dial(port)
		defer net.close(conn)
		began := time.tick_now()
		harness.send_text(conn, "G")
		time.sleep(60 * time.Millisecond)
		harness.send_text(conn, "E")
		time.sleep(60 * time.Millisecond)
		harness.send_text(conn, "T")
		received, _ := harness.read_to_close(conn)
		slow := string(received)
		elapsed := time.tick_since(began)
		testing.expectf(
			t,
			strings.has_prefix(slow, "HTTP/1.1 408 ") && within(elapsed, 130 * time.Millisecond, 290 * time.Millisecond),
			"header deadline: %v %q",
			elapsed,
			slow,
		)
		append(&requests, Expected{"OTHER", "Timeout", 3, len(slow)})
	}

	// A connection that never sends a byte is answered at the idle deadline
	// but is not a request: no event.
	{
		conn, _ := harness.dial(port)
		defer net.close(conn)
		began := time.tick_now()
		buffer: [8192]u8
		n, _ := net.recv_tcp(conn, buffer[:])
		elapsed := time.tick_since(began)
		testing.expectf(
			t,
			strings.has_prefix(string(buffer[:n]), "HTTP/1.1 408 ") && within(elapsed, 40 * time.Millisecond, time.Second),
			"idle deadline: %v %q",
			elapsed,
			string(buffer[:n]),
		)
		rest, _ := harness.read_to_close(conn)
		testing.expect_value(t, string(rest), "")
	}

	partial := "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3\r\n\r\na"
	began := time.tick_now()
	result = exchange(t, port, partial)
	elapsed := time.tick_since(began)
	testing.expectf(
		t,
		strings.has_prefix(result, "HTTP/1.1 408 ") && within(elapsed, 70 * time.Millisecond, 2 * time.Second),
		"body deadline: %v %q",
		elapsed,
		result,
	)
	append(&requests, Expected{"POST", "Timeout", len(partial), len(result)})

	// A reader that does not read for longer than the response deadline is cut
	// off part way through an 8 MiB body.
	{
		conn, _ := harness.dial(port)
		defer net.close(conn)
		_ = net.set_option(conn, .Receive_Buffer_Size, 8192)
		wire := "GET /large HTTP/1.1\r\nHost: localhost\r\n\r\n"
		harness.send_text(conn, wire)
		time.sleep(600 * time.Millisecond)
		received, _ := harness.read_to_close(conn, 8 * 1024 * 1024)
		data := string(received)
		testing.expectf(
			t,
			strings.has_prefix(data, "HTTP/1.1 200 ") && len(data) < 8 * 1024 * 1024,
			"write deadline: %d bytes, %q",
			len(data),
			data[:min(60, len(data))],
		)
		append(&requests, Expected{"GET", "Timeout", len(wire), len(data)})
	}

	// Every attempt above has completed, not merely been sent.
	seen := make([dynamic]string, context.temp_allocator)
	for len(seen) < len(requests) {
		line, found := harness.expect_line(t, p, "event ", 8 * time.Second)
		if !found {
			return
		}
		append(&seen, line)
	}
	events := make([]Event, len(seen), context.temp_allocator)
	for line, index in seen {
		events[index] = parse_event(line)
	}
	slice.sort_by(events, proc(a, b: Event) -> bool {return a.id < b.id})
	for event, index in events {
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
	testing.expect_value(t, events[0].route, "/items/:id")
	testing.expect_value(t, events[1].route, "/items/:id")
	for line in seen {
		testing.expectf(t, !strings.contains(line, "private-id") && !strings.contains(line, "secret"), "leaked: %q", line)
	}

	// A parked request cancelled by shutdown still completes exactly once.
	parked, _ := harness.dial(port)
	harness.send_text(parked, "G")
	time.sleep(20 * time.Millisecond)
	harness.send_input(t, input, "\n")
	exited := harness.exited_cleanly(t, p, 8 * time.Second)
	net.close(parked)
	if !exited {
		return
	}
	every := make([dynamic]string, context.temp_allocator)
	append(&every, ..seen[:])
	append(&every, ..harness.lines_with(p, "event "))
	if !testing.expectf(t, len(every) == len(requests) + 1 && strings.has_suffix(every[len(every) - 1], "Cancelled"), "events: %v", every) {
		return
	}
	ids := make(map[int]bool, context.temp_allocator)
	for line in every {
		id := parse_event(line).id
		testing.expectf(t, id != 0 && !(id in ids), "request id %d reused or zero", id)
		ids[id] = true
	}
	metrics := harness.lines_with(p, "metrics ")
	if !testing.expect(t, len(metrics) == 1, "no metrics line") {
		return
	}
	stats := strings.fields(metrics[0], context.temp_allocator)
	value :: proc(text: string) -> int {
		number, _ := strconv.parse_int(text)
		return number
	}
	testing.expectf(t, value(stats[1]) == len(every), "started: %v", stats)
	testing.expectf(t, value(stats[2]) == len(requests), "completed: %v", stats)
	testing.expectf(t, value(stats[3]) == 1, "active: %v", stats)
	// Header, body and write timeouts; the silent connection is not counted.
	testing.expectf(t, value(stats[4]) == 3, "timeouts: %v", stats)
}
