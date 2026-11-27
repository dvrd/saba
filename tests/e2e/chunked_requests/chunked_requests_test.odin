// Chunked request bodies over raw sockets: every split of the framing, one-byte
// fragments, bodies past the read buffers, decoded-size and line limits,
// malformed framing, CL/TE ambiguity, premature EOF, the total body deadline,
// and exact per-request byte accounting before a pipelined request.
package saba_e2e_chunked_requests_test

import "core:fmt"
import "core:net"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"
import harness "../../support/harness"

SERVER :: "tests/fixtures/apps/keep_alive"

Server :: struct {
	process:  ^harness.Process,
	input:    ^os.File,
	port:     int,
	finished: bool,
}

Event :: struct {
	id, received: int,
	outcome:      string,
}

events :: proc(s: ^Server) -> []Event {
	result := make([dynamic]Event, context.temp_allocator)
	for line in harness.lines_with(s.process, "event ") {
		p := strings.fields(line, context.temp_allocator)
		if len(p) < 8 {
			continue
		}
		e := Event{outcome = p[7]}
		e.id, _ = strconv.parse_int(p[1])
		e.received, _ = strconv.parse_int(p[5])
		append(&result, e)
	}
	slice.sort_by(result[:], proc(a, b: Event) -> bool {return a.id < b.id})
	return result[:]
}

// Stops the fixture and checks it reported one completion per event, each
// with its own ID.
finish :: proc(t: ^testing.T, s: ^Server) -> bool {
	if s.finished {
		return true
	}
	s.finished = true
	harness.send_input(t, s.input, "s") or_return
	harness.exited_cleanly(t, s.process) or_return
	stopped := harness.lines_with(s.process, "stopped ")
	testing.expectf(t, len(stopped) == 1, "no stopped line\n%s", harness.transcript(s.process)) or_return
	count, _ := strconv.parse_int(stopped[0][len("stopped "):])
	all := events(s)
	testing.expectf(t, count == len(all), "stopped %d but %d events", count, len(all)) or_return
	for e, i in all {
		testing.expectf(t, e.id != 0 && (i == 0 || e.id != all[i - 1].id), "bad event ID %d", e.id) or_return
	}
	return true
}

head :: proc(path := "/echo", extra := "") -> string {
	return fmt.tprintf("POST %s HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n%s\r\n", path, extra)
}

@(test)
chunked_requests :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Minute)
	work := harness.workdir(t, "chunked")
	defer os.remove_all(work)
	binary, built := harness.build(t, SERVER, work)
	if !built {
		return
	}
	s: Server
	started: bool
	// The body deadline is the subject of one scenario; the header and
	// response deadlines keep the fixture's generous default.
	s.process, s.input, started = harness.start_with_input(t, {binary}, {"SABA_KEEP_BODY_MS=300"})
	if !started {
		return
	}
	defer {
		harness.stop(s.process)
		os.close(s.input)
	}
	port, ready := harness.ready(t, s.process)
	if !ready {
		return
	}
	s.port = port
	expected := make([dynamic]int, context.temp_allocator)
	_ = exercise(t, &s, &expected)
}

exercise :: proc(t: ^testing.T, s: ^Server, expected: ^[dynamic]int) -> bool {
	following := harness.request_wire("/id")

	// Every framing, body and trailer split, with a coalesced next request,
	// keeps byte ownership.
	body := "3;name=\"a,b\"\r\nabc\r\n2\r\nde\r\n0\r\nX-Check: ok\r\n\r\n"
	upload := strings.concatenate({head(), body}, context.temp_allocator)
	for split in 0 ..= len(body) {
		conn := harness.connect(t, s.port) or_return
		defer net.close(conn)
		harness.send_text(conn, strings.concatenate({head(), body[:split]}, context.temp_allocator))
		if split > 0 {
			time.sleep(time.Millisecond)
		}
		harness.send_text(conn, strings.concatenate({body[split:], following}, context.temp_allocator))
		r := harness.read_response(t, conn) or_return
		testing.expectf(t, r.status == 200 && string(r.body) == "abcde", "split %d: %d %q", split, r.status, r.body) or_return
		testing.expectf(t, harness.has_field(r.head, "Connection: keep-alive"), "split %d:\n%s", split, r.head) or_return
		next := harness.read_response(t, conn) or_return
		testing.expect_value(t, next.status, 200) or_return
		append(expected, len(upload), len(following))
	}

	// One-byte framing and data fragments.
	{
		conn := harness.connect(t, s.port) or_return
		defer net.close(conn)
		harness.send_text(conn, head())
		chunks := "1\r\nx\r\n0\r\n\r\n"
		for i in 0 ..< len(chunks) {
			harness.send_text(conn, chunks[i:i + 1])
			time.sleep(time.Millisecond)
		}
		r := harness.read_response(t, conn) or_return
		testing.expect_value(t, string(r.body), "x") or_return
		append(expected, len(head()) + len(chunks))
	}

	// Reads past both the initial head buffer and the async input scratch.
	{
		conn := harness.connect(t, s.port) or_return
		defer net.close(conn)
		content := strings.repeat("ab", 1500, context.temp_allocator)
		large := strings.concatenate({head(), "bb8\r\n", content, "\r\n0\r\n\r\n"}, context.temp_allocator)
		harness.send_text(conn, strings.concatenate({large, following}, context.temp_allocator))
		r := harness.read_response(t, conn) or_return
		testing.expect(t, string(r.body) == content, "large chunk body differs") or_return
		next := harness.read_response(t, conn) or_return
		testing.expect_value(t, next.status, 200) or_return
		append(expected, len(large), len(following))
	}

	// What an ordinary client's chunk encoder writes (Python's http.client with
	// encode_chunked): its own head, then one write per chunk, binary data.
	{
		conn := harness.connect(t, s.port) or_return
		defer net.close(conn)
		binary: [256]u8
		for &b, i in binary {
			b = u8(i)
		}
		pieces := []string{"one", string(binary[:]), "three"}
		harness.send_text(
			conn,
			fmt.tprintf(
				"POST /echo HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nAccept-Encoding: identity\r\nTransfer-Encoding: chunked\r\n\r\n",
				s.port,
			),
		)
		for piece in pieces {
			harness.send_text(conn, fmt.tprintf("%X\r\n%s\r\n", len(piece), piece))
		}
		harness.send_text(conn, "0\r\n\r\n")
		r := harness.read_response(t, conn) or_return
		want := strings.concatenate(pieces, context.temp_allocator)
		testing.expect(t, r.status == 200 && string(r.body) == want, "encoded upload did not echo") or_return
	}

	// Decoded-size exact and cumulative caps, an oversized declaration, line
	// and trailer caps and malformed framing fail closed.
	cases := []struct {
		path, wire: string,
		status:     int,
	} {
		{"/limited", "4\r\nabcd\r\n0\r\n\r\n", 200},
		{"/limited", "0\r\n\r\n", 200},
		{"/limited", "5\r\n", 413},
		{"/limited", "3\r\nabc\r\n2\r\n", 413},
		{"/echo", "1001\r\n", 413},
		{"/echo", "1\r\naXX", 400},
		{"/echo", "1\na", 400},
		{"/echo", "0\r\nContent-Length: 0\r\n\r\n", 400},
		{"/echo", "0\r\nCookie: spoof\r\n\r\n", 400},
		{"/echo", fmt.tprintf("1;x=%s\r\n", strings.repeat("x", 1024, context.temp_allocator)), 413},
		{"/echo", fmt.tprintf("0\r\n%s\r\n", strings.repeat("X: y\r\n", 33, context.temp_allocator)), 413},
	}
	for c in cases {
		conn := harness.connect(t, s.port) or_return
		defer net.close(conn)
		harness.send_text(conn, strings.concatenate({head(c.path), c.wire}, context.temp_allocator))
		r := harness.read_response(t, conn) or_return
		testing.expectf(t, r.status == c.status, "%s %q: %d, want %d", c.path, c.wire[:min(len(c.wire), 40)], r.status, c.status) or_return
		if c.status != 200 {
			testing.expectf(t, harness.has_field(r.head, "Connection: close"), "%q:\n%s", c.wire[:min(len(c.wire), 40)], r.head) or_return
			harness.expect_closed(t, conn) or_return
		}
	}

	// CL/TE ambiguity, a duplicate transfer coding and unsupported
	// expectations are rejected.
	rejected := []struct {
		fields: string,
		status: int,
	}{{"Content-Length: 0\r\n", 400}, {"Transfer-Encoding: chunked\r\n", 400}, {"Expect: 200-ok\r\n", 417}}
	for c in rejected {
		conn := harness.connect(t, s.port) or_return
		defer net.close(conn)
		harness.send_text(conn, head(extra = c.fields))
		r := harness.read_response(t, conn) or_return
		testing.expectf(t, r.status == c.status, "%q: %d, want %d", c.fields, r.status, c.status) or_return
		harness.expect_closed(t, conn) or_return
	}

	// Premature EOF at the size, data, delimiter and trailer phases.
	for partial in ([]string{"1", "1\r\n", "2\r\na", "1\r\na\r", "0\r\nX: y\r\n"}) {
		conn := harness.connect(t, s.port) or_return
		defer net.close(conn)
		harness.send_text(conn, strings.concatenate({head(), partial}, context.temp_allocator))
		harness.shutdown_write(conn)
		r := harness.read_response(t, conn) or_return
		testing.expectf(t, r.status == 400, "EOF after %q: %d", partial, r.status) or_return
		harness.expect_closed(t, conn) or_return
	}

	// Progress does not extend the total body deadline (300 ms).
	{
		conn := harness.connect(t, s.port) or_return
		defer net.close(conn)
		harness.send_text(conn, strings.concatenate({head(), "1;"}, context.temp_allocator))
		time.sleep(100 * time.Millisecond)
		harness.send_text(conn, "x")
		time.sleep(100 * time.Millisecond)
		harness.send_text(conn, "=")
		r := harness.read_response(t, conn) or_return
		testing.expect_value(t, r.status, 408) or_return
		harness.expect_closed(t, conn) or_return
	}

	// A disconnect and a shutdown release parked readers.
	partial_body := strings.concatenate({head(), "4\r\na"}, context.temp_allocator)
	{
		abandoned := harness.connect(t, s.port) or_return
		harness.send_text(abandoned, partial_body)
		net.close(abandoned)
	}
	served :: proc(t: ^testing.T, port: int) -> bool {
		conn := harness.connect(t, port) or_return
		defer net.close(conn)
		harness.send_text(conn, harness.request_wire("/id"))
		r := harness.read_response(t, conn) or_return
		return testing.expect_value(t, r.status, 200)
	}
	served(t, s.port) or_return
	held := harness.connect(t, s.port) or_return
	defer net.close(held)
	harness.send_text(held, partial_body)
	time.sleep(20 * time.Millisecond)
	served(t, s.port) or_return
	finish(t, s) or_return
	harness.expect_closed(t, held) or_return

	// Exact wire-byte metrics before each pipeline handoff.
	all := events(s)
	testing.expectf(t, len(all) >= len(expected), "%d events for %d requests", len(all), len(expected)) or_return
	for want, i in expected {
		e := all[i]
		testing.expectf(t, e.received == want && e.outcome == "Completed", "event %d: %v, want %d bytes Completed", i, e, want) or_return
	}
	return true
}
