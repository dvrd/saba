// Streamed responses over raw sockets: fixed and chunked framing, producer
// ownership (every chunk released, every producer dropped once), timer waits
// that free the sole worker, slow readers, disconnect and shutdown. The SSE
// example is driven the same way.
package saba_e2e_streaming_test

import "core:crypto/sha2"
import "core:net"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"
import harness "../../support/harness"

SERVER :: "tests/e2e/streaming/server"
EXAMPLE :: "examples/sse"

@(test)
streaming :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 4 * time.Minute)
	work := harness.workdir(t, "streaming")
	defer os.remove_all(work)
	built, ok := harness.build(t, SERVER, work)
	if !ok {
		return
	}
	// Scenarios free temporary memory between them; the paths must outlive that.
	binary := strings.clone(built)
	defer delete(binary)
	built, ok = harness.build(t, EXAMPLE, work)
	if !ok {
		return
	}
	example := strings.clone(built)
	defer delete(example)
	if !producers(t, binary) {
		return
	}
	free_all(context.temp_allocator)
	sse_example(t, example)
}

Server :: struct {
	process:  ^harness.Process,
	input:    ^os.File,
	port:     int,
	example:  bool,
	finished: bool,
}

launch :: proc(t: ^testing.T, binary: string, example := false) -> (s: Server, ok: bool) {
	s.example = example
	s.process, s.input = harness.start_with_input(t, {binary}, {"SABA_STREAM_WORKERS=1"}) or_return
	// The example prints its own lowercase line.
	s.port = harness.ready(t, s.process, prefix = "ready " if example else "READY ") or_return
	return s, true
}

dispose :: proc(s: ^Server) {
	harness.stop(s.process)
	if s.input != nil {
		os.close(s.input)
	}
	s^ = {}
}

// Stops the program and, for the fixture, checks its accounting: every
// allocation released and one drop line per producer, each with its own ID
// and balanced allocations.
stop :: proc(t: ^testing.T, s: ^Server, loc := #caller_location) -> bool {
	if s.finished {
		return true
	}
	s.finished = true
	harness.send_input(t, s.input, "s", loc) or_return
	harness.exited_cleanly(t, s.process, loc = loc) or_return
	stopped := harness.lines_with(s.process, "stopped")
	testing.expectf(t, len(stopped) == 1, "no stopped line\n%s", harness.transcript(s.process), loc = loc) or_return
	if s.example {
		return true
	}
	fields := strings.fields(stopped[0], context.temp_allocator)
	testing.expectf(t, len(fields) == 4 && fields[2] == fields[3], "unbalanced %q", stopped[0], loc = loc) or_return
	drops, _ := strconv.parse_int(fields[1])
	records := drop_records(s)
	testing.expectf(t, len(records) == drops, "stopped with %d drops, %d drop lines", drops, len(records), loc = loc) or_return
	ids := make([dynamic]string, context.temp_allocator)
	for row in records {
		testing.expectf(t, row[3] == row[4], "producer %s dropped with %s allocations, %s releases", row[1], row[3], row[4], loc = loc) or_return
		append(&ids, row[1])
	}
	slice.sort(ids[:])
	for i in 1 ..< len(ids) {
		testing.expectf(t, ids[i] != ids[i - 1], "producer %s dropped twice", ids[i], loc = loc) or_return
	}
	return true
}

// "drop <id> <calls> <allocations> <releases>", in the order printed.
drop_records :: proc(s: ^Server) -> [][]string {
	rows := make([dynamic][]string, context.temp_allocator)
	for line in harness.lines_with(s.process, "drop ") {
		append(&rows, strings.fields(line, context.temp_allocator))
	}
	return rows[:]
}

request :: harness.request_wire

// A cheap request on its own connection.
fast :: proc(t: ^testing.T, s: ^Server, path := "/fast", loc := #caller_location) -> (r: harness.Response, ok: bool) {
	conn := harness.connect(t, s.port, loc = loc) or_return
	defer net.close(conn)
	harness.send_text(conn, request(path))
	return harness.read_response(t, conn, loc = loc)
}

// Waits until no producer is active and no chunk is live, then checks that
// every allocation was released. Returns active, live, allocated, released
// and drops.
idle :: proc(t: ^testing.T, s: ^Server, loc := #caller_location) -> (values: [5]int, ok: bool) {
	deadline := time.tick_add(time.tick_now(), 3 * time.Second)
	for {
		r := fast(t, s, "/stats", loc) or_return
		text := string(r.body)
		i := 0
		for field in strings.fields_iterator(&text) {
			if i < len(values) {
				values[i], _ = strconv.parse_int(field)
			}
			i += 1
		}
		if values[0] == 0 && values[1] == 0 {
			ok = testing.expectf(t, values[2] == values[3], "idle with unreleased chunks: %v", values, loc = loc)
			return
		}
		if !testing.expectf(t, time.tick_since(deadline) < 0, "producers still active: %v", values, loc = loc) {
			return values, false
		}
		time.sleep(5 * time.Millisecond)
	}
}

// idle() proves the producers are gone; their drop lines can still be in the
// stdout pipe. Waits until every one of them has been read.
settled :: proc(t: ^testing.T, s: ^Server, loc := #caller_location) -> bool {
	values := idle(t, s, loc) or_return
	return harness.await_lines(t, s.process, "drop ", values[4], 3 * time.Second, loc)
}

// One request on conn, read as an ordinary client reads it: no body for HEAD
// and 204/304, chunked bodies decoded, else Content-Length, else until close.
fetch :: proc(
	t: ^testing.T,
	conn: net.TCP_Socket,
	method, path: string,
	loc := #caller_location,
) -> (
	r: harness.Response,
	ok: bool,
) {
	harness.send_text(conn, request(path, method))
	r.head = harness.read_head(t, conn, loc) or_return
	r.status = harness.status_of(r.head)
	if method == "HEAD" || r.status == 204 || r.status == 304 {
		return r, true
	}
	if coding, found := harness.field(r.head, "Transfer-Encoding"); found && strings.equal_fold(coding, "chunked") {
		r.body, _ = harness.read_chunked(t, conn, loc) or_return
		return r, true
	}
	if value, found := harness.field(r.head, "Content-Length"); found {
		length, _ := strconv.parse_int(value)
		r.body = harness.read_n(t, conn, length, loc = loc) or_return
		return r, true
	}
	result: harness.Read_Result
	r.body, result = harness.read_to_close(conn)
	return r, testing.expectf(t, result == .Eof, "reading a body to close: %v", result, loc = loc)
}

pattern :: proc(n: int, allocator := context.temp_allocator) -> []u8 {
	bytes := make([]u8, n, allocator)
	for &b, i in bytes {
		b = u8(i % 251)
	}
	return bytes
}

producers :: proc(t: ^testing.T, binary: string) -> bool {
	s := launch(t, binary) or_return
	defer dispose(&s)
	expected := pattern(6144)

	// An ordinary client reads fixed and chunked streams and reuses the
	// connection.
	for path in ([]string{"/known", "/chunked"}) {
		conn := harness.connect(t, s.port) or_return
		defer net.close(conn)
		r := fetch(t, conn, "GET", path) or_return
		testing.expectf(t, r.status == 200 && slice.equal(r.body, expected), "%s: %d with %d bytes", path, r.status, len(r.body)) or_return
		length, has_length := harness.field(r.head, "Content-Length")
		coding, has_coding := harness.field(r.head, "Transfer-Encoding")
		if path == "/known" {
			testing.expectf(t, has_length && length == "6144" && !has_coding, "/known framing:\n%s", r.head) or_return
		} else {
			testing.expectf(t, !has_length && has_coding && coding == "chunked", "/chunked framing:\n%s", r.head) or_return
		}
		again := fetch(t, conn, "GET", "/fast") or_return
		testing.expect_value(t, string(again.body), "ok") or_return
	}
	idle(t, &s) or_return

	// Exact chunk framing, the final terminator, and the pipelined next request
	// served after it.
	{
		conn := harness.connect(t, s.port) or_return
		defer net.close(conn)
		harness.send_text(conn, strings.concatenate({request("/chunked"), request("/fast")}, context.temp_allocator))
		head := harness.read_head(t, conn) or_return
		testing.expectf(t, harness.has_field(head, "Transfer-Encoding: chunked"), "not chunked:\n%s", head) or_return
		body, chunks := harness.read_chunked(t, conn) or_return
		testing.expectf(t, chunks == 3 && slice.equal(body, expected), "%d chunks, %d bytes", chunks, len(body)) or_return
		r := harness.read_response(t, conn) or_return
		testing.expect_value(t, string(r.body), "ok") or_return
	}

	// HEAD and body-forbidden responses never poll the producer; a known empty
	// representation completes.
	settled(t, &s) or_return
	before := len(drop_records(&s))
	cases := [][2]string{{"HEAD", "/known"}, {"HEAD", "/chunked"}, {"GET", "/nobody"}, {"GET", "/empty"}}
	for c in cases {
		conn := harness.connect(t, s.port, 4 * time.Second) or_return
		defer net.close(conn)
		r := fetch(t, conn, c[0], c[1]) or_return
		testing.expectf(t, len(r.body) == 0, "%s %s sent a body", c[0], c[1]) or_return
		if c[0] == "HEAD" {
			length, has_length := harness.field(r.head, "Content-Length")
			_, has_coding := harness.field(r.head, "Transfer-Encoding")
			testing.expectf(t, !has_coding, "HEAD %s advertised chunked", c[1]) or_return
			if c[1] == "/known" {
				testing.expectf(t, has_length && length == "6144", "HEAD /known:\n%s", r.head) or_return
			} else {
				testing.expectf(t, !has_length, "HEAD /chunked has a length:\n%s", r.head) or_return
			}
		}
	}
	settled(t, &s) or_return
	last := drop_records(&s)[before:]
	testing.expectf(t, len(last) == 4, "%d producers dropped, want 4: %v", len(last), last) or_return
	for row in last[:3] {
		testing.expectf(t, row[2] == "0", "producer %s was polled %s times", row[1], row[2]) or_return
	}

	// 8 MiB in sequential owned 16 KiB chunks, read slowly so writes are partial.
	{
		want: [sha2.DIGEST_SIZE_256]u8
		{
			ctx: sha2.Context_256
			sha2.init_256(&ctx)
			sha2.update(&ctx, pattern(8 * 1024 * 1024))
			sha2.final(&ctx, want[:])
		}
		conn := harness.connect(t, s.port) or_return
		defer net.close(conn)
		harness.send_text(conn, request("/large"))
		head := harness.read_head(t, conn) or_return
		testing.expect_value(t, harness.status_of(head), 200) or_return
		length, _ := harness.field(head, "Content-Length")
		testing.expect_value(t, length, "8388608") or_return
		ctx: sha2.Context_256
		sha2.init_256(&ctx)
		buffer := make([]u8, 32768, context.temp_allocator)
		count := 0
		for count < 8 * 1024 * 1024 {
			n, error := net.recv_tcp(conn, buffer[:min(len(buffer), 8 * 1024 * 1024 - count)])
			if !testing.expectf(t, error == nil && n > 0, "/large ended after %d bytes: %v", count, error) {
				return false
			}
			sha2.update(&ctx, buffer[:n])
			count += n
			time.sleep(500 * time.Microsecond)
		}
		got: [sha2.DIGEST_SIZE_256]u8
		sha2.final(&ctx, got[:])
		testing.expect(t, got == want, "/large content differs") or_return
	}
	idle(t, &s) or_return

	// Producer, length, admission, wait and metadata failures close without a
	// false completion and release every owner.
	for path in ([]string{"/error", "/short", "/long", "/overlimit", "/backpressure", "/badwait"}) {
		{
			conn := harness.connect(t, s.port) or_return
			defer net.close(conn)
			harness.send_text(conn, request(path))
			head := harness.read_head(t, conn) or_return
			testing.expectf(t, strings.has_prefix(head, "HTTP/1.1 200 "), "%s:\n%s", path, head) or_return
			partial, result := harness.read_to_close(conn)
			testing.expectf(t, result == .Eof, "%s did not close: %v", path, result) or_return
			want := ""
			switch path {
			case "/error", "/overlimit":
				want = "3\r\n\x00\x01\x02\r\n"
			case "/short":
				want = "\x00\x01\x02"
			}
			testing.expectf(t, string(partial) == want, "%s sent %q, want %q", path, partial, want) or_return
		}
		idle(t, &s) or_return
	}
	for path in ([]string{"/badhead", "/mix"}) {
		{
			conn := harness.connect(t, s.port) or_return
			defer net.close(conn)
			harness.send_text(conn, request(path))
			reply, result := harness.read_to_close(conn)
			testing.expectf(t, result == .Eof, "%s did not close: %v", path, result) or_return
			// A head the encoder rejects answers 500; a structurally invalid
			// stream still closes.
			if path == "/badhead" {
				testing.expectf(t, strings.has_prefix(string(reply), "HTTP/1.1 500 "), "/badhead: %q", reply) or_return
			} else {
				testing.expectf(t, len(reply) == 0, "/mix: %q", reply) or_return
			}
		}
		idle(t, &s) or_return
	}

	// Timer-suspended producers free the sole worker; waits clamp to the total
	// stream deadline.
	{
		conn := harness.connect(t, s.port) or_return
		defer net.close(conn)
		harness.send_text(conn, request("/wait"))
		harness.read_head(t, conn) or_return
		started := time.tick_now()
		r := fast(t, &s) or_return
		testing.expect_value(t, string(r.body), "ok") or_return
		elapsed := time.tick_since(started)
		testing.expectf(t, elapsed < 500 * time.Millisecond, "/fast took %v behind a waiting stream", elapsed) or_return
		body, _ := harness.read_chunked(t, conn) or_return
		testing.expect(t, slice.equal(body, []u8{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11}), "/wait content") or_return
	}
	{
		conn := harness.connect(t, s.port) or_return
		defer net.close(conn)
		harness.send_text(conn, request("/stall"))
		harness.read_head(t, conn) or_return
		started := time.tick_now()
		rest, result := harness.read_to_close(conn)
		elapsed := time.tick_since(started)
		testing.expectf(t, result == .Eof && len(rest) == 0, "/stall sent %q (%v)", rest, result) or_return
		testing.expectf(t, elapsed < time.Second, "/stall closed after %v", elapsed) or_return
	}
	idle(t, &s) or_return

	// A consumer that stops reading reaches the write timeout and releases the
	// pending chunk and producer while cheap routes progress.
	{
		slow := harness.connect(t, s.port) or_return
		defer net.close(slow)
		_ = net.set_option(slow, .Receive_Buffer_Size, 1024)
		harness.send_text(slow, request("/slow"))
		harness.read_head(t, slow) or_return
		r := fast(t, &s) or_return
		testing.expect_value(t, string(r.body), "ok") or_return
		idle(t, &s) or_return
	}

	// Disconnect and shutdown destroy every accepted chunk, rejected owner and
	// producer exactly once.
	{
		peer := harness.connect(t, s.port) or_return
		harness.send_text(peer, request("/slow"))
		_, read := harness.read_head(t, peer)
		net.close(peer)
		read or_return
		idle(t, &s) or_return
	}
	held := harness.connect(t, s.port) or_return
	defer net.close(held)
	harness.send_text(held, request("/wait"))
	harness.read_head(t, held) or_return
	blocked := harness.connect(t, s.port) or_return
	defer net.close(blocked)
	harness.send_text(blocked, request("/slow"))
	harness.read_head(t, blocked) or_return
	return stop(t, &s)
}

// The SSE example emits bounded events and heartbeats through timer waits,
// supports HEAD, and stops with a stream open.
sse_example :: proc(t: ^testing.T, binary: string) -> bool {
	s := launch(t, binary, example = true) or_return
	defer dispose(&s)
	{
		conn := harness.connect(t, s.port) or_return
		defer net.close(conn)
		r := fetch(t, conn, "GET", "/events") or_return
		kind, _ := harness.field(r.head, "Content-Type")
		coding, _ := harness.field(r.head, "Transfer-Encoding")
		testing.expectf(t, kind == "text/event-stream" && coding == "chunked", "/events head:\n%s", r.head) or_return
		body := string(r.body)
		testing.expectf(
			t,
			strings.count(body, "event: tick\n") == 4 && strings.count(body, ": heartbeat\n\n") == 4,
			"/events body: %q",
			body,
		) or_return
	}
	{
		conn := harness.connect(t, s.port, 3 * time.Second) or_return
		defer net.close(conn)
		r := fetch(t, conn, "HEAD", "/events") or_return
		testing.expectf(t, r.status == 200 && len(r.body) == 0, "HEAD /events: %d", r.status) or_return
	}
	held := harness.connect(t, s.port) or_return
	defer net.close(held)
	harness.send_text(held, request("/events"))
	harness.read_head(t, held) or_return
	payload, done := harness.read_chunk(t, held) or_return
	testing.expect(t, !done && len(payload) > 0, "no first event") or_return
	stop(t, &s) or_return
	_, result := harness.read_to_close(held)
	return testing.expectf(t, result == .Eof, "the held stream did not end: %v", result)
}
