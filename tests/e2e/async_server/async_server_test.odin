// The public Saba facade over test-owned loopback sockets: HTTP/1 framing
// policy, parked readers that hold no thread, backpressure, cached production
// assets, deadlines, connection capacity and its growth (including a failing
// allocator), the development reload WebSocket, and shutdown that closes every
// socket before the process exits.
package saba_e2e_async_server_test

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import harness "../../support/harness"

SOURCE :: "tests/fixtures/apps/async_server"
LARGE :: 2 * 1024 * 1024
TIMEOUT :: 8 * time.Second
ACCEPT :: "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

@(test)
async_server :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Minute)
	work := harness.workdir(t, "async-server")
	defer os.remove_all(work)
	built, ok := harness.build(t, SOURCE, work)
	if !ok {
		return
	}
	// Scenarios free temporary memory between them; these must outlive that.
	binary := strings.clone(built)
	defer delete(binary)
	web := strings.clone(fmt.tprintf("%s/web", work))
	defer delete(web)
	if !write_web(t, web) {
		return
	}
	for workers in ([]int{1, 4}) {
		if !write(t, web, "assets/blob.bin", string(blob())) || !production(t, binary, web, workers) {
			return
		}
		free_all(context.temp_allocator)
	}
	if !capacity(t, binary, web) {
		return
	}
	for workers in ([]int{1, 4}) {
		if !growth(t, binary, web, workers) {
			return
		}
		free_all(context.temp_allocator)
	}
	scenarios := []proc(t: ^testing.T, binary, web: string) -> bool {
		growth_past_previous_default,
		growth_failure,
		development,
		stop_before_startup,
	}
	for scenario in scenarios {
		if !scenario(t, binary, web) {
			return
		}
		free_all(context.temp_allocator)
	}
}

blob :: proc() -> []u8 {
	bytes := make([]u8, 256, context.temp_allocator)
	for &b, i in bytes {
		b = u8(i)
	}
	return bytes
}

pattern :: proc(n: int, allocator := context.temp_allocator) -> []u8 {
	bytes := make([]u8, n, allocator)
	for &b, i in bytes {
		b = u8(i % 251)
	}
	return bytes
}

write :: proc(t: ^testing.T, web, relative, data: string, loc := #caller_location) -> bool {
	error := os.write_entire_file(fmt.tprintf("%s/%s", web, relative), data)
	return testing.expectf(t, error == nil, "writing %s: %v", relative, error, loc = loc)
}

write_web :: proc(t: ^testing.T, web: string) -> bool {
	for directory in ([]string{"assets", "pages"}) {
		error := os.make_directory_all(fmt.tprintf("%s/%s", web, directory))
		testing.expectf(t, error == nil, "creating %s: %v", directory, error) or_return
	}
	write(t, web, "assets/blob.bin", string(blob())) or_return
	write(t, web, "view.jsx", "export default function View(){ return <div>hello</div>; }") or_return
	write(t, web, "pages/index.jsx", `export const title="Home"; export default function Home(){ return <h1>Home</h1>; }`) or_return
	return write(t, web, "index.html", "<html><head></head><body><!--saba:page--></body></html>")
}

Server :: struct {
	process: ^harness.Process,
	input:   ^os.File,
	port:    int,
	// Every connection a scenario opened and has not closed yet.
	open:    [dynamic]net.TCP_Socket,
}

launch :: proc(
	t: ^testing.T,
	binary, web: string,
	workers := 1,
	capacity := 64,
	development := false,
	initial := 0,
	fail_growth := false,
	loc := #caller_location,
) -> (
	s: Server,
	ok: bool,
) {
	env := []string {
		fmt.tprintf("SABA_TEST_WEB=%s", web),
		fmt.tprintf("SABA_TEST_WORKERS=%d", workers),
		fmt.tprintf("SABA_TEST_CAPACITY=%d", capacity),
		fmt.tprintf("SABA_TEST_INITIAL=%d", initial),
		fmt.tprintf("SABA_TEST_FAIL_GROWTH=%d", int(fail_growth)),
		fmt.tprintf("SABA_TEST_DEVELOPMENT=%d", int(development)),
	}
	s.open = make([dynamic]net.TCP_Socket, context.temp_allocator)
	s.process, s.input = harness.start_with_input(t, {binary}, env) or_return
	s.port, ok = harness.ready(t, s.process, timeout = TIMEOUT, loc = loc)
	if !ok {
		dispose(&s)
	}
	return
}

dispose :: proc(s: ^Server) {
	for conn in s.open {
		net.close(conn)
	}
	clear(&s.open)
	harness.stop(s.process)
	s.process = nil
	if s.input != nil {
		os.close(s.input)
		s.input = nil
	}
}

// The first newline stops the server; the fixture then prints "stopped" and
// stays alive, so a socket that survived shutdown is not hidden by exit.
stop_serving :: proc(t: ^testing.T, s: ^Server, loc := #caller_location) -> bool {
	harness.send_input(t, s.input, "\n", loc) or_return
	harness.await_lines(t, s.process, "stopped", 1, 5 * time.Second, loc) or_return
	line := harness.lines_with(s.process, "stopped")[0]
	testing.expectf(t, line == "stopped", "stop line %q", line, loc = loc) or_return
	return testing.expectf(t, harness.running(s.process), "fixture must stay alive for cleanup verification", loc = loc)
}

// The second newline lets it exit. Returns what it wrote to stderr.
exit_server :: proc(t: ^testing.T, s: ^Server, loc := #caller_location) -> (errors: string, ok: bool) {
	harness.send_input(t, s.input, "\n", loc) or_return
	harness.exited_cleanly(t, s.process, loc = loc) or_return
	return harness.stderr_text(s.process), true
}

shutdown :: proc(t: ^testing.T, s: ^Server, loc := #caller_location) -> (errors: string, ok: bool) {
	stop_serving(t, s, loc) or_return
	return exit_server(t, s, loc)
}

open_conn :: proc(t: ^testing.T, s: ^Server, loc := #caller_location) -> (conn: net.TCP_Socket, ok: bool) {
	conn = harness.connect(t, s.port, TIMEOUT, loc) or_return
	append(&s.open, conn)
	return conn, true
}

close_conn :: proc(s: ^Server, conn: net.TCP_Socket) {
	for c, i in s.open {
		if c == conn {
			ordered_remove(&s.open, i)
			break
		}
	}
	net.close(conn)
}

// Thread-safe reads: no testing.T, everything in the temporary allocator.
read_head :: proc(conn: net.TCP_Socket) -> (string, harness.Read_Result) {
	b := strings.builder_make(context.temp_allocator)
	one: [1]u8
	for !strings.has_suffix(strings.to_string(b), "\r\n\r\n") {
		if result := harness.read_exact(conn, one[:]); result != .Ok {
			return strings.to_string(b), result
		}
		strings.write_byte(&b, one[0])
		if strings.builder_len(b) > harness.HEAD_LIMIT {
			return strings.to_string(b), .Failed
		}
	}
	return strings.to_string(b), .Ok
}

read_reply :: proc(conn: net.TCP_Socket) -> (r: harness.Response, result: harness.Read_Result) {
	r.head, result = read_head(conn)
	if result != .Ok {
		return
	}
	r.status = harness.status_of(r.head)
	length := 0
	if value, found := harness.field(r.head, "Content-Length"); found {
		length, _ = strconv.parse_int(value)
	}
	r.body = make([]u8, length, context.temp_allocator)
	result = harness.read_exact(conn, r.body)
	return
}

reply :: proc(t: ^testing.T, conn: net.TCP_Socket, loc := #caller_location) -> (harness.Response, bool) {
	r, result := read_reply(conn)
	return r, testing.expectf(t, result == .Ok, "reading a response: %v after %q", result, r.head, loc = loc)
}

expect_status :: proc(t: ^testing.T, conn: net.TCP_Socket, status: int, loc := #caller_location) -> bool {
	r := reply(t, conn, loc) or_return
	return testing.expectf(t, r.status == status, "status %d, want %d\n%s", r.status, status, r.head, loc = loc)
}

// A clean EOF, not a reset.
expect_eof :: proc(t: ^testing.T, conn: net.TCP_Socket, loc := #caller_location) -> bool {
	one: [1]u8
	n, error := net.recv_tcp(conn, one[:])
	return testing.expectf(t, n == 0 && error == nil, "expected EOF, got %d bytes, %v", n, error, loc = loc)
}

// One request on its own connection, which every ordinary response closes;
// only a best-effort 503 may reset after its response.
exchange :: proc(port: int, path := "/ok", body := "", fragments := false, extra := "") -> (r: harness.Response, failure: string) {
	method := "POST" if body != "" else "GET"
	wire := fmt.tprintf("%s %s HTTP/1.1\r\nHost: localhost\r\nContent-Length: %d\r\n%s\r\n%s", method, path, len(body), extra, body)
	conn, error := net.dial_tcp(net.Endpoint{net.IP4_Loopback, port})
	if error != nil {
		return r, fmt.tprintf("connect: %v", error)
	}
	defer net.close(conn)
	_ = net.set_option(conn, .Receive_Timeout, TIMEOUT)
	_ = net.set_option(conn, .Send_Timeout, TIMEOUT)
	if fragments {
		for at := 0; at < len(wire); at += 31 {
			harness.send_text(conn, wire[at:min(at + 31, len(wire))])
		}
	} else {
		harness.send_text(conn, wire)
	}
	result: harness.Read_Result
	r, result = read_reply(conn)
	if result != .Ok {
		return r, fmt.tprintf("%s %s: %v after %q", method, path, result, r.head)
	}
	one: [1]u8
	n, received := net.recv_tcp(conn, one[:])
	if received == .Connection_Closed {
		if r.status != 503 {
			failure = "only best-effort rejection may reset after its response"
		}
	} else if received != nil || n != 0 {
		failure = fmt.tprintf("ordinary responses must close the connection (%d, %v)", n, received)
	}
	return
}

request :: proc(
	t: ^testing.T,
	s: ^Server,
	path := "/ok",
	body := "",
	fragments := false,
	extra := "",
	loc := #caller_location,
) -> (
	harness.Response,
	bool,
) {
	r, failure := exchange(s.port, path, body, fragments, extra)
	return r, testing.expectf(t, failure == "", "%s", failure, loc = loc)
}

expect_ok :: proc(t: ^testing.T, s: ^Server, loc := #caller_location) -> bool {
	r := request(t, s, loc = loc) or_return
	return testing.expectf(t, string(r.body) == "ok", "GET /ok: %d %q", r.status, r.body, loc = loc)
}

// Reads until the server closes (a reset ends it too) without keeping bytes.
drained :: proc(t: ^testing.T, conn: net.TCP_Socket, loc := #caller_location) -> bool {
	buffer: [65536]u8
	for {
		n, error := net.recv_tcp(conn, buffer[:])
		if error == .Connection_Closed || (error == nil && n == 0) {
			return true
		}
		if error != nil {
			return testing.expectf(t, false, "draining: %v", error, loc = loc)
		}
	}
}

// The server closed conn after shutdown. With allow_rejection the only bytes
// it may have sent are (a prefix of) a 503 response.
closed :: proc(t: ^testing.T, conn: net.TCP_Socket, allow_rejection := false, loc := #caller_location) -> bool {
	data, result := harness.read_to_close(conn)
	testing.expectf(t, result == .Eof, "waiting for the server to close: %v", result, loc = loc) or_return
	if len(data) == 0 {
		return true
	}
	testing.expectf(t, allow_rejection, "suspended connection survived shutdown: %q", data, loc = loc) or_return
	expected := "HTTP/1.1 503 "
	text := string(data)
	matches := strings.has_prefix(text, expected) if len(text) >= len(expected) else strings.has_prefix(expected, text)
	return testing.expectf(t, matches, "rejection was %q", text, loc = loc)
}

// The thread count, when this platform can read it.
threads :: proc(s: ^Server) -> int {
	count, ok := harness.threads(s.process)
	return count if ok else -1
}

expect_threads :: proc(t: ^testing.T, s: ^Server, baseline: int, loc := #caller_location) -> bool {
	if baseline < 0 {
		return true
	}
	now := threads(s)
	return testing.expectf(t, now == baseline, "threads %d, before %d", now, baseline, loc = loc)
}

Upload :: struct {
	port, first: int,
	failed:      bool,
	message:     [256]u8,
}

// Uploads first, first+8, first+16 and first+24 of the 32 fragmented bodies.
upload :: proc(u: ^Upload) {
	sizes := [4]int{1, 64, 4096, 12000}
	for i := u.first; i < 32; i += 8 {
		body := pattern(sizes[i % 4])
		r, failure := exchange(u.port, "/echo", string(body), fragments = true)
		if failure == "" && (r.status != 200 || string(r.body) != string(body)) {
			failure = fmt.tprintf("upload %d: status %d, %d bytes back", i, r.status, len(r.body))
		}
		if failure != "" {
			u.failed = true
			fmt.bprint(u.message[:], failure)
			return
		}
	}
}

production :: proc(t: ^testing.T, binary, web: string, workers: int) -> bool {
	s := launch(t, binary, web, workers = workers) or_return
	defer dispose(&s)
	expect_ok(t, &s) or_return
	{
		conn := open_conn(t, &s) or_return
		harness.send_text(conn, "HEAD /ok HTTP/1.1\r\nHost: localhost\r\n\r\n")
		head, result := read_head(conn)
		testing.expectf(t, result == .Ok && strings.has_prefix(head, "HTTP/1.1 200 "), "HEAD: %v %q", result, head) or_return
		testing.expectf(t, strings.contains(head, "Content-Length: 2\r\n"), "HEAD head %q", head) or_return
		// HEAD must not transmit the representation body.
		expect_eof(t, conn) or_return
		close_conn(&s, conn)
	}
	for fields in ([]string{"", "Host: localhost\r\nHost: other\r\n", "Host: user@localhost\r\n"}) {
		conn := open_conn(t, &s) or_return
		harness.send_text(conn, fmt.tprintf("GET /ok HTTP/1.1\r\n%s\r\n", fields))
		expect_status(t, conn, 400) or_return
		close_conn(&s, conn)
	}
	for method in ([]string{"PUT", "DELETE"}) {
		conn := open_conn(t, &s) or_return
		harness.send_text(conn, fmt.tprintf("%s /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3\r\n\r\nabc", method))
		r := reply(t, conn) or_return
		testing.expectf(t, string(r.body) == "abc", "%s body %q", method, r.body) or_return
		close_conn(&s, conn)
	}

	// 24 suspended clients allow unrelated requests without another thread.
	held := make([dynamic]net.TCP_Socket, context.temp_allocator)
	baseline := threads(&s)
	for _ in 0 ..< 24 {
		conn := open_conn(t, &s) or_return
		harness.send_text(conn, "GET /ok HTTP/1.1\r\nHo")
		append(&held, conn)
	}
	expect_ok(t, &s) or_return
	expect_threads(t, &s, baseline) or_return

	// 32 concurrent fragmented uploads, including bodies above 4 KiB.
	{
		uploads: [8]Upload
		workers: [8]^thread.Thread
		for &u, i in uploads {
			u = {port = s.port, first = i}
			workers[i] = thread.create_and_start_with_poly_data(&u, upload)
		}
		for worker in workers {
			thread.join(worker)
			thread.destroy(worker)
		}
		for &u in uploads {
			testing.expectf(t, !u.failed, "%s", cstring(raw_data(u.message[:]))) or_return
		}
	}

	// Header growth and limits, duplicate length, unsupported framing and
	// expectations, body limits and truncated bodies.
	{
		r := request(t, &s, extra = fmt.tprintf("X-Test: %s\r\n", strings.repeat("x", 6000, context.temp_allocator))) or_return
		testing.expect_value(t, r.status, 200) or_return
		conn := open_conn(t, &s) or_return
		harness.send_text(conn, fmt.tprintf("GET /ok HTTP/1.1\r\nX-Test: %s\r\n\r\n", strings.repeat("x", 8192, context.temp_allocator)))
		expect_status(t, conn, 431) or_return
		close_conn(&s, conn)
	}
	bad := []struct {
		fields: string,
		status: int,
	} {
		{"Content-Length: 1\r\nContent-Length: 1\r\n", 400},
		{"Transfer-Encoding: gzip\r\n", 501},
		{"Expect: 200-ok\r\n", 417},
		{"Content-Length: 16385\r\n", 413},
	}
	for b in bad {
		conn := open_conn(t, &s) or_return
		harness.send_text(conn, fmt.tprintf("POST /echo HTTP/1.1\r\nHost: localhost\r\n%s\r\n", b.fields))
		expect_status(t, conn, b.status) or_return
		close_conn(&s, conn)
	}
	{
		conn := open_conn(t, &s) or_return
		harness.send_text(conn, "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\n\r\nx")
		harness.shutdown_write(conn)
		expect_status(t, conn, 400) or_return
		close_conn(&s, conn)
	}

	// Expect: 100-continue gets the interim response after the body limit
	// check, and a refused body gets only its final status.
	{
		conn := open_conn(t, &s) or_return
		harness.send_text(conn, "POST /echo HTTP/1.1\r\nHost: localhost\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n")
		head, result := read_head(conn)
		testing.expectf(t, result == .Ok && head == "HTTP/1.1 100 Continue\r\n\r\n", "interim %v %q", result, head) or_return
		harness.send_text(conn, "hello")
		r := reply(t, conn) or_return
		testing.expectf(t, r.status == 200 && string(r.body) == "hello", "%d %q", r.status, r.body) or_return
		close_conn(&s, conn)
	}
	{
		// A body sent without waiting needs no interim response.
		conn := open_conn(t, &s) or_return
		harness.send_text(conn, "POST /echo HTTP/1.1\r\nHost: localhost\r\nExpect: 100-continue\r\nContent-Length: 2\r\n\r\nhi")
		r := reply(t, conn) or_return
		testing.expectf(t, r.status == 200 && string(r.body) == "hi", "%d %q", r.status, r.body) or_return
		close_conn(&s, conn)
	}
	{
		conn := open_conn(t, &s) or_return
		harness.send_text(conn, "POST /echo HTTP/1.1\r\nHost: localhost\r\nExpect: 100-continue\r\nContent-Length: 16385\r\n\r\n")
		expect_status(t, conn, 413) or_return
		close_conn(&s, conn)
	}

	// HTTP/1.0 is served without Host, interim responses or persistence;
	// other versions get 505.
	{
		conn := open_conn(t, &s) or_return
		harness.send_text(conn, "GET /ok HTTP/1.0\r\n\r\n")
		r := reply(t, conn) or_return
		testing.expectf(
			t,
			r.status == 200 && string(r.body) == "ok" && strings.contains(r.head, "Connection: close") && !strings.contains(strings.to_lower(r.head, context.temp_allocator), "chunked"),
			"HTTP/1.0 GET: %q %q",
			r.head,
			r.body,
		) or_return
		expect_eof(t, conn) or_return
		close_conn(&s, conn)
	}
	{
		conn := open_conn(t, &s) or_return
		harness.send_text(conn, "POST /echo HTTP/1.0\r\nHost: localhost\r\nConnection: keep-alive\r\nExpect: 100-continue\r\nContent-Length: 3\r\n\r\n")
		time.sleep(50 * time.Millisecond)
		harness.send_text(conn, "abc")
		r := reply(t, conn) or_return
		testing.expectf(t, r.status == 200 && string(r.body) == "abc" && strings.contains(r.head, "Connection: close"), "HTTP/1.0 POST: %q %q", r.head, r.body) or_return
		expect_eof(t, conn) or_return
		close_conn(&s, conn)
	}
	{
		conn := open_conn(t, &s) or_return
		harness.send_text(conn, "GET /ok HTTP/2.0\r\nHost: localhost\r\n\r\n")
		expect_status(t, conn, 505) or_return
		close_conn(&s, conn)
	}

	// Empty lines before a request line are ignored, alone or with the request.
	{
		conn := open_conn(t, &s) or_return
		harness.send_text(conn, "\r\n\r\n")
		time.sleep(50 * time.Millisecond)
		harness.send_text(conn, "GET /ok HTTP/1.1\r\nHost: localhost\r\n\r\n")
		r := reply(t, conn) or_return
		testing.expect_value(t, string(r.body), "ok") or_return
		close_conn(&s, conn)
	}
	{
		conn := open_conn(t, &s) or_return
		harness.send_text(conn, "\r\nPOST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3\r\n\r\nabc")
		r := reply(t, conn) or_return
		testing.expect_value(t, string(r.body), "abc") or_return
		close_conn(&s, conn)
	}

	// A 2 MiB response resumes exactly under backpressure while an unrelated
	// request progresses.
	{
		slow := open_conn(t, &s) or_return
		_ = net.set_option(slow, .Receive_Buffer_Size, 16384)
		harness.send_text(slow, "GET /large HTTP/1.1\r\nHost: localhost\r\n\r\n")
		time.sleep(100 * time.Millisecond)
		expect_ok(t, &s) or_return
		r := reply(t, slow) or_return
		testing.expectf(t, r.status == 200 && string(r.body) == string(pattern(LARGE)), "large: %d, %d bytes", r.status, len(r.body)) or_return
		close_conn(&s, slow)
	}

	// Production assets stay cached; JSX modules and file-based pages still
	// dispatch before the handler.
	{
		original := string(blob())
		r := request(t, &s, "/assets/blob.bin") or_return
		testing.expect(t, string(r.body) == original) or_return
		write(t, web, "assets/blob.bin", "changed") or_return
		r = request(t, &s, "/assets/blob.bin") or_return
		testing.expectf(t, string(r.body) == original, "production asset changed to %q", r.body) or_return
		r = request(t, &s, "/view.js") or_return
		testing.expectf(t, strings.contains(string(r.body), "/__saba/dom.js"), "/view.js: %q", r.body) or_return
		r = request(t, &s, "/") or_return
		testing.expectf(t, strings.contains(string(r.body), "/__saba/page-entry.js"), "/: %q", r.body) or_return
	}

	// Header and body deadlines answer 408 together, without blocking the
	// worker: both are in flight at once.
	{
		header := open_conn(t, &s) or_return
		body := open_conn(t, &s) or_return
		harness.send_text(header, "G")
		harness.send_text(body, "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\n\r\nx")
		expect_status(t, header, 408) or_return
		expect_status(t, body, 408) or_return
		close_conn(&s, header)
		close_conn(&s, body)
	}

	// Shutdown closes parked readers and a blocked writer before the process
	// exits, joins the workers and releases the published runtime.
	readers: [2]net.TCP_Socket
	for wire, i in ([]string{"GET /ok HTTP/1.1\r\nHo", "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\n\r\nx"}) {
		readers[i] = open_conn(t, &s) or_return
		harness.send_text(readers[i], wire)
	}
	expect_ok(t, &s) or_return // Earlier accepted readers can park first.
	pending := open_conn(t, &s) or_return
	harness.send_text(pending, "GET /large HTTP/1.1\r\nHost: localhost\r\n\r\n")
	stop_serving(t, &s) or_return
	for conn in readers {
		closed(t, conn, allow_rejection = true) or_return
	}
	drained(t, pending) or_return
	exit_server(t, &s) or_return
	// A queued response may precede EOF on the writer; drain it first.
	for conn in held {
		drained(t, conn) or_return
	}
	return true
}

// Capacity rejection answers a best-effort 503, and admission recovers once a
// connection is cleaned up.
capacity :: proc(t: ^testing.T, binary, web: string) -> bool {
	s := launch(t, binary, web, workers = 4, capacity = 2) or_return
	defer dispose(&s)
	held: [2]net.TCP_Socket
	for &conn in held {
		conn = open_conn(t, &s) or_return
		harness.send_text(conn, "G")
	}
	r := request(t, &s) or_return
	testing.expect_value(t, r.status, 503) or_return
	close_conn(&s, held[1])
	recovered(t, &s, 3 * time.Second) or_return
	shutdown(t, &s) or_return
	return closed(t, held[0])
}

// Retries until a request is admitted again.
recovered :: proc(t: ^testing.T, s: ^Server, within: time.Duration, loc := #caller_location) -> bool {
	deadline := time.tick_add(time.tick_now(), within)
	for {
		r := request(t, s, loc = loc) or_return
		if r.status != 503 {
			return true
		}
		testing.expectf(t, time.tick_since(deadline) < 0, "admission did not recover within %v", within, loc = loc) or_return
		time.sleep(10 * time.Millisecond)
	}
}

Stats :: struct {
	current, maximum, peak, growths, rejected, failures: int,
}

stats :: proc(t: ^testing.T, s: ^Server, loc := #caller_location) -> (result: Stats, ok: bool) {
	r := request(t, s, "/capacity", loc = loc) or_return
	testing.expectf(t, r.status == 200, "/capacity: %d %q", r.status, r.body, loc = loc) or_return
	parts := strings.split(string(r.body), ",", context.temp_allocator)
	testing.expectf(t, len(parts) == 6, "/capacity: %q", r.body, loc = loc) or_return
	values: [6]int
	for part, i in parts {
		values[i], ok = strconv.parse_int(part)
		testing.expectf(t, ok, "/capacity: %q", r.body, loc = loc) or_return
	}
	return transmute(Stats)values, true
}

// 4->8->16->32->40 growth preserves parked reads, partial bodies,
// backpressured writes and shutdown; threads stay fixed.
growth :: proc(t: ^testing.T, binary, web: string, workers: int) -> bool {
	s := launch(t, binary, web, workers = workers, initial = 4, capacity = 40) or_return
	defer dispose(&s)
	baseline := threads(&s)
	body := open_conn(t, &s) or_return
	harness.send_text(body, "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhe")
	slow := open_conn(t, &s) or_return
	_ = net.set_option(slow, .Receive_Buffer_Size, 16384)
	harness.send_text(slow, "GET /large HTTP/1.1\r\nHost: localhost\r\n\r\n")
	head, result := read_head(slow)
	testing.expectf(t, result == .Ok && strings.has_prefix(head, "HTTP/1.1 200 "), "/large: %v %q", result, head) or_return
	// With two admitted connections, a stats request is still below 80%.
	before := stats(t, &s) or_return
	testing.expect_value(t, before.current, 4) or_return
	held: [32]net.TCP_Socket
	for &conn in held {
		conn = open_conn(t, &s) or_return
		harness.send_text(conn, "G")
	}
	grown := stats(t, &s) or_return
	testing.expectf(
		t,
		grown.current == 40 && grown.maximum == 40 && grown.growths == 4 && grown.rejected == 0 && grown.failures == 0 && grown.peak >= 34,
		"grown: %v",
		grown,
	) or_return
	expect_threads(t, &s, baseline) or_return
	harness.send_text(body, "llo")
	echoed := reply(t, body) or_return
	testing.expect_value(t, string(echoed.body), "hello") or_return
	close_conn(&s, body)
	large := harness.read_n(t, slow, LARGE) or_return
	testing.expect(t, string(large) == string(pattern(LARGE))) or_return
	close_conn(&s, slow)
	for conn in held {
		harness.send_text(conn, "ET /ok HTTP/1.1\r\nHost: localhost\r\n\r\n")
	}
	for conn in held {
		r := reply(t, conn) or_return
		testing.expect_value(t, string(r.body), "ok") or_return
		close_conn(&s, conn)
	}
	after := stats(t, &s) or_return
	testing.expectf(t, after.current == 40, "capacity must not shrink after draining: %v", after) or_return
	// Cancel sockets left pending after several storage replacements.
	pending: [8]net.TCP_Socket
	for &conn in pending {
		conn = open_conn(t, &s) or_return
		harness.send_text(conn, "G")
	}
	stop_serving(t, &s) or_return
	for conn in pending {
		closed(t, conn, allow_rejection = true) or_return
	}
	errors := exit_server(t, &s) or_return
	testing.expect_value(t, strings.count(errors, "Connection capacity expanded:"), 4) or_return
	return testing.expect_value(t, strings.count(errors, "Connection capacity pressure: configured ceiling"), 1)
}

// The default ceiling admits 96 parked clients past the former 64 cap,
// growing 16->32->64->128 with fixed workers, and shuts down cleanly.
growth_past_previous_default :: proc(t: ^testing.T, binary, web: string) -> bool {
	s := launch(t, binary, web, workers = 4, initial = 16, capacity = 0) or_return
	defer dispose(&s)
	baseline := threads(&s)
	held: [96]net.TCP_Socket
	for &conn in held {
		conn = open_conn(t, &s) or_return
		harness.send_text(conn, "G")
	}
	grown := stats(t, &s) or_return
	testing.expectf(
		t,
		grown.current == 128 && grown.maximum == 4096 && grown.growths == 3 && grown.rejected == 0 && grown.failures == 0 && grown.peak >= 97,
		"grown: %v",
		grown,
	) or_return
	expect_threads(t, &s, baseline) or_return
	stop_serving(t, &s) or_return
	for conn in held {
		closed(t, conn) or_return
	}
	_ = exit_server(t, &s) or_return
	return true
}

// A failed expansion keeps admission and sockets, throttles retries and
// warnings, then expands once the allocator recovers.
growth_failure :: proc(t: ^testing.T, binary, web: string) -> bool {
	s := launch(t, binary, web, workers = 1, initial = 4, capacity = 16, fail_growth = true) or_return
	defer dispose(&s)
	held := make([dynamic]net.TCP_Socket, context.temp_allocator)
	for _ in 0 ..< 3 {
		conn := open_conn(t, &s) or_return
		harness.send_text(conn, "G")
		append(&held, conn)
	}
	first := stats(t, &s) or_return
	testing.expectf(t, first.current == 4 && first.growths == 0 && first.failures == 1, "after a failed growth: %v", first) or_return
	for _ in 0 ..< 8 {
		again := stats(t, &s) or_return
		testing.expect_value(t, again.current, 4) or_return
	}
	throttled := stats(t, &s) or_return
	testing.expectf(t, throttled.failures == 1, "failed growth attempts must be throttled: %v", throttled) or_return
	full := open_conn(t, &s) or_return
	harness.send_text(full, "G")
	r := request(t, &s) or_return
	testing.expect_value(t, r.status, 503) or_return
	close_conn(&s, full)
	// Admission recovers at the old capacity although expansion fails.
	recovered(t, &s, 2 * time.Second) or_return
	time.sleep(1050 * time.Millisecond)
	retried := stats(t, &s) or_return
	testing.expectf(t, retried.current == 4 && retried.growths == 0 && retried.rejected >= 1 && retried.failures == 2, "retried: %v", retried) or_return
	allowed := request(t, &s, "/allow-growth") or_return
	testing.expect_value(t, allowed.status, 200) or_return
	time.sleep(1050 * time.Millisecond)
	expanded := stats(t, &s) or_return
	testing.expectf(t, expanded.current == 8 && expanded.growths == 1 && expanded.failures == 2, "expansion must recover after allocation recovers: %v", expanded) or_return
	for conn in held {
		harness.send_text(conn, "ET /ok HTTP/1.1\r\nHost: localhost\r\n\r\n")
		r = reply(t, conn) or_return
		testing.expect_value(t, string(r.body), "ok") or_return
		close_conn(&s, conn)
	}
	expect_ok(t, &s) or_return
	errors := shutdown(t, &s) or_return
	return testing.expect_value(t, strings.count(errors, "Connection capacity pressure:"), 1)
}

// A WebSocket frame of at most 125 bytes, masked as a client sends it.
frame :: proc(opcode: u8, payload: string, masked := true) -> string {
	assert(len(payload) <= 125)
	mask := [4]u8{1, 3, 5, 7}
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, 0x80 | opcode)
	if !masked {
		strings.write_byte(&b, u8(len(payload)))
		strings.write_string(&b, payload)
		return strings.to_string(b)
	}
	strings.write_byte(&b, 0x80 | u8(len(payload)))
	strings.write_bytes(&b, mask[:])
	for i in 0 ..< len(payload) {
		strings.write_byte(&b, payload[i] ~ mask[i % 4])
	}
	return strings.to_string(b)
}

// The next frame from the server: final, unmasked, short.
received_frame :: proc(t: ^testing.T, conn: net.TCP_Socket, loc := #caller_location) -> (opcode: u8, payload: string, ok: bool) {
	head := harness.read_n(t, conn, 2, loc = loc) or_return
	testing.expectf(t, head[0] & 0x80 != 0 && head[1] & 0x80 == 0, "frame head %x", head, loc = loc) or_return
	data := harness.read_n(t, conn, int(head[1] & 127), loc = loc) or_return
	return head[0] & 15, string(data), true
}

expect_frame :: proc(t: ^testing.T, conn: net.TCP_Socket, opcode: u8, payload: string, loc := #caller_location) -> bool {
	got, data := received_frame(t, conn, loc) or_return
	return testing.expectf(t, got == opcode && data == payload, "frame %d %q, want %d %q", got, data, opcode, payload, loc = loc)
}

expect_close_code :: proc(t: ^testing.T, conn: net.TCP_Socket, code: int, loc := #caller_location) -> bool {
	opcode, payload := received_frame(t, conn, loc) or_return
	testing.expectf(t, opcode == 8 && len(payload) >= 2, "expected a close frame, got %d %q", opcode, payload, loc = loc) or_return
	got := int(payload[0]) << 8 | int(payload[1])
	return testing.expectf(t, got == code, "close code %d, want %d", got, code, loc = loc)
}

websocket :: proc(t: ^testing.T, s: ^Server, following := "", extra := "", loc := #caller_location) -> (conn: net.TCP_Socket, ok: bool) {
	conn = open_conn(t, s, loc) or_return
	harness.send_text(
		conn,
		fmt.tprintf(
			"GET /__reload HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n%s\r\n%s",
			extra,
			following,
		),
	)
	head, result := read_head(conn)
	testing.expectf(t, result == .Ok && strings.has_prefix(head, "HTTP/1.1 101 "), "upgrade: %v %q", result, head, loc = loc) or_return
	return conn, testing.expectf(t, strings.contains(head, ACCEPT), "upgrade head %q", head, loc = loc)
}

development :: proc(t: ^testing.T, binary, web: string) -> bool {
	s := launch(t, binary, web, development = true) or_return
	defer dispose(&s)
	html := request(t, &s, "/html") or_return
	testing.expectf(t, strings.count(string(html.body), "/__reload/client.js") == 1, "/html: %q", html.body) or_return
	asset := request(t, &s, "/assets/blob.bin") or_return
	testing.expect_value(t, string(asset.body), "changed") or_return

	// The reload WebSocket upgrades; coalesced and fragmented masked pings and
	// the close are echoed.
	{
		pad := strings.repeat("x", 2000, context.temp_allocator)
		conn := websocket(t, &s, frame(9, "coalesced"), fmt.tprintf("X-Pad: %s\r\n", pad)) or_return
		expect_frame(t, conn, 10, "coalesced") or_return
		ping := frame(9, "fragmented")
		for i in 0 ..< len(ping) {
			harness.send_text(conn, ping[i:i + 1])
		}
		expect_frame(t, conn, 10, "fragmented") or_return
		goodbye := "\x03\xe8bye"
		harness.send_text(conn, frame(8, goodbye))
		expect_frame(t, conn, 8, goodbye) or_return
		closed(t, conn) or_return
		close_conn(&s, conn)
	}

	// Unmasked or oversized control frames, invalid close UTF-8 and
	// unsupported data frames get the existing close codes.
	invalid := []struct {
		wire: string,
		code: int,
	} {
		{frame(9, "x", masked = false), 1002},
		{"\x89\xfe", 1002},
		{frame(8, "\x03\xe8\xff"), 1007},
		{frame(1, "x"), 1003},
	}
	for c in invalid {
		conn := websocket(t, &s) or_return
		harness.send_text(conn, c.wire)
		expect_close_code(t, conn, c.code) or_return
		closed(t, conn) or_return
		close_conn(&s, conn)
	}

	// Idle WebSockets do not occupy the sole worker; a watched change sends
	// reload and close to each.
	{
		held: [16]net.TCP_Socket
		for &conn in held {
			conn = websocket(t, &s) or_return
		}
		expect_ok(t, &s) or_return
		write(t, web, "view.jsx", "export default function View(){ return <p>updated</p>; }") or_return
		for conn in held {
			expect_frame(t, conn, 1, "reload") or_return
			expect_close_code(t, conn, 1000) or_return
			closed(t, conn) or_return
			close_conn(&s, conn)
		}
	}

	// Shutdown cancels an idle socket and a partial frame.
	held: [2]net.TCP_Socket
	for &conn in held {
		conn = websocket(t, &s) or_return
	}
	harness.send_text(held[1], "\x89\x83\x01")
	expect_ok(t, &s) or_return
	stop_serving(t, &s) or_return
	for conn in held {
		closed(t, conn) or_return
	}
	_ = exit_server(t, &s) or_return
	return true
}

// A shutdown requested before the listener is published is honoured.
stop_before_startup :: proc(t: ^testing.T, binary, web: string) -> bool {
	env := []string{fmt.tprintf("SABA_TEST_WEB=%s", web), "SABA_TEST_PRESTOP=1"}
	p, input := harness.start_with_input(t, {binary}, env) or_return
	defer harness.stop(p)
	defer os.close(input)
	return harness.exited_cleanly(t, p, TIMEOUT)
}
