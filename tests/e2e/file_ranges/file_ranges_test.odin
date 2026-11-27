// File streams with byte ranges over raw sockets: exact range bytes and
// metadata, unsatisfiable and unsupported ranges, conditional precedence,
// rooted path policy, and release of every buffer and descriptor after
// disconnects, slow readers and shutdown.
package saba_e2e_file_ranges_test

import "core:crypto/sha2"
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

SERVER :: "tests/e2e/file_ranges/server"
NORMAL :: 131077
LARGE :: 256 * 65536

@(test)
file_ranges :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 4 * time.Minute)
	work := harness.workdir(t, "file-ranges")
	defer os.remove_all(work)
	root := fmt.tprintf("%s/files", work)
	if !prepare(t, work, root) {
		return
	}
	binary, built := harness.build(t, SERVER, work)
	if !built {
		return
	}
	p, input, started := harness.start_with_input(t, {binary}, {fmt.tprintf("SABA_FILE_ROOT=%s", root), "SABA_FILE_WORKERS=1"})
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
	s := Server{p, input, port}
	ranges(t, &s)
}

Server :: struct {
	process: ^harness.Process,
	input:   ^os.File,
	port:    int,
}

pattern :: proc(n: int, modulus: int, allocator := context.temp_allocator) -> []u8 {
	bytes := make([]u8, n, allocator)
	for &b, i in bytes {
		b = u8(i % modulus)
	}
	return bytes
}

prepare :: proc(t: ^testing.T, work, root: string) -> bool {
	testing.expect(t, os.make_directory(root) == nil, "files directory") or_return
	write :: proc(t: ^testing.T, path: string, data: []u8) -> bool {
		return testing.expectf(t, os.write_entire_file(path, data) == nil, "could not write %s", path)
	}
	write(t, fmt.tprintf("%s/normal.bin", root), pattern(NORMAL, 251)) or_return
	write(t, fmt.tprintf("%s/empty.txt", root), nil) or_return
	write(t, fmt.tprintf("%s/large.bin", root), pattern(LARGE, 256)) or_return
	write(t, fmt.tprintf("%s/private.jsx", root), transmute([]u8)string("private")) or_return
	write(t, fmt.tprintf("%s/outside.txt", work), transmute([]u8)string("secret")) or_return
	// 256 MiB that no reader finishes: sparse, so it costs no disk.
	slow, error := os.create(fmt.tprintf("%s/slow.bin", root))
	testing.expectf(t, error == nil, "slow.bin: %v", error) or_return
	truncated := os.truncate(slow, 256 * 1024 * 1024)
	os.close(slow)
	testing.expectf(t, truncated == nil, "slow.bin: %v", truncated) or_return
	testing.expect(t, os.symlink(fmt.tprintf("%s/outside.txt", work), fmt.tprintf("%s/escape.txt", root)) == nil, "escape.txt link") or_return
	testing.expect(t, os.symlink(work, fmt.tprintf("%s/outside", root)) == nil, "outside link") or_return
	return true
}

// One request on its own connection, read as an ordinary client reads it.
fetch :: proc(
	t: ^testing.T,
	s: ^Server,
	path := "/normal.bin",
	fields := "",
	method := "GET",
	loc := #caller_location,
) -> (
	r: harness.Response,
	ok: bool,
) {
	conn := harness.connect(t, s.port, loc = loc) or_return
	defer net.close(conn)
	return exchange(t, conn, path, fields, method, loc)
}

// One request on conn: no body for HEAD and 304, Content-Length otherwise.
exchange :: proc(
	t: ^testing.T,
	conn: net.TCP_Socket,
	path: string,
	fields := "",
	method := "GET",
	loc := #caller_location,
) -> (
	r: harness.Response,
	ok: bool,
) {
	harness.send_text(conn, fmt.tprintf("%s %s HTTP/1.1\r\nHost: localhost\r\n%s\r\n", method, path, fields))
	return harness.read_response(t, conn, method == "HEAD", loc)
}

// The response has no field called name.
lacks :: proc(head, name: string) -> bool {
	_, found := harness.field(head, name)
	return !found
}

value :: proc(head, name: string) -> string {
	v, _ := harness.field(head, name)
	return v
}

// Waits until the server holds no file buffer and every allocation was
// released, and returns its open descriptor count.
idle :: proc(t: ^testing.T, s: ^Server, loc := #caller_location) -> (fds: int, ok: bool) {
	deadline := time.tick_add(time.tick_now(), 5 * time.Second)
	for {
		r := fetch(t, s, "/stats", loc = loc) or_return
		values: [4]int
		text := string(r.body)
		i := 0
		for field in strings.fields_iterator(&text) {
			if i < len(values) {
				values[i], _ = strconv.parse_int(field)
			}
			i += 1
		}
		if values[0] == 0 && values[1] == values[2] {
			return values[3], true
		}
		if !testing.expectf(t, time.tick_since(deadline) < 0, "file buffers still live: %v", values, loc = loc) {
			return 0, false
		}
		time.sleep(10 * time.Millisecond)
	}
}

Parallel :: struct {
	t:      ^testing.T,
	port:   int,
	first:  int,
	normal: []u8,
	ok:     bool,
}

parallel_range :: proc(job: ^Parallel) {
	s := Server{port = job.port}
	r, ok := fetch(job.t, &s, fields = fmt.tprintf("Range: bytes=%d-%d\r\n", job.first, job.first + 999))
	job.ok = ok && r.status == 206 && slice.equal(r.body, job.normal[job.first:job.first + 1000])
}

ranges :: proc(t: ^testing.T, s: ^Server) -> bool {
	normal := pattern(NORMAL, 251)
	baseline := idle(t, s) or_return

	r := fetch(t, s) or_return
	testing.expectf(t, r.status == 200 && slice.equal(r.body, normal), "full GET: %d", r.status) or_return
	testing.expectf(
		t,
		value(r.head, "Content-Length") == fmt.tprint(NORMAL) &&
		value(r.head, "ETag") == `"fixture-v1"` &&
		value(r.head, "Accept-Ranges") == "bytes" &&
		lacks(r.head, "Transfer-Encoding"),
		"full GET head:\n%s",
		r.head,
	) or_return

	// Full, fixed, open, suffix and overflowing ranges: exact bytes and metadata.
	cases := []struct {
		range:        string,
		first, end: int,
	} {
		{"bytes=0-0", 0, 1},
		{"bytes=31-127", 31, 128},
		{"bytes=131070-", 131070, NORMAL},
		{"bytes=-17", NORMAL - 17, NORMAL},
		{"bytes=-999999999999999999999999", 0, NORMAL},
		{"bytes=0-999999999999999999999999", 0, NORMAL},
	}
	for c in cases {
		r = fetch(t, s, fields = fmt.tprintf("Range: %s\r\n", c.range)) or_return
		testing.expectf(t, r.status == 206 && slice.equal(r.body, normal[c.first:c.end]), "%s: %d", c.range, r.status) or_return
		testing.expectf(
			t,
			value(r.head, "Content-Range") == fmt.tprintf("bytes %d-%d/%d", c.first, c.end - 1, NORMAL) &&
			value(r.head, "Content-Length") == fmt.tprint(c.end - c.first) &&
			lacks(r.head, "Transfer-Encoding"),
			"%s head:\n%s",
			c.range,
			r.head,
		) or_return
	}

	// Unsatisfiable ranges and the empty file use exact 416 and 200 framing.
	for range in ([]string{"bytes=999999-", "bytes=-0", "bytes=99999999999999999999999-"}) {
		r = fetch(t, s, fields = fmt.tprintf("Range: %s\r\n", range)) or_return
		testing.expectf(
			t,
			r.status == 416 && len(r.body) == 0 && value(r.head, "Content-Range") == fmt.tprintf("bytes */%d", NORMAL),
			"%s:\n%s",
			range,
			r.head,
		) or_return
	}
	r = fetch(t, s, "/empty.txt", "Range: bytes=0-\r\n") or_return
	testing.expectf(t, r.status == 416 && len(r.body) == 0 && value(r.head, "Content-Range") == "bytes */0", "empty range:\n%s", r.head) or_return
	r = fetch(t, s, "/empty.txt") or_return
	testing.expectf(t, r.status == 200 && len(r.body) == 0 && value(r.head, "Content-Length") == "0", "empty file:\n%s", r.head) or_return

	// Unsupported ranges fall back to the whole file; conditions take
	// precedence and only a strong If-Range validator keeps the range.
	for range in ([]string{"bytes=0-1,5-7", "items=0-1", "bytes=8-3", "bytes=0 -1", "bytes=0-xx"}) {
		r = fetch(t, s, fields = fmt.tprintf("Range: %s\r\n", range)) or_return
		testing.expectf(t, r.status == 200 && slice.equal(r.body, normal), "%s: %d", range, r.status) or_return
	}
	r = fetch(t, s, fields = "Range: bytes=0-1\r\nRange: bytes=4-5\r\n") or_return
	testing.expectf(t, r.status == 200 && slice.equal(r.body, normal), "two Range fields: %d", r.status) or_return
	conditions := []struct {
		condition: string,
		status:    int,
	}{{`"fixture-v1"`, 206}, {`W/"fixture-v1"`, 200}, {`"old"`, 200}, {"Sat, 01 Jan 2000 00:00:00 GMT", 200}}
	for c in conditions {
		r = fetch(t, s, fields = fmt.tprintf("Range: bytes=4-7\r\nIf-Range: %s\r\n", c.condition)) or_return
		want := normal[4:8] if c.status == 206 else normal
		testing.expectf(t, r.status == c.status && slice.equal(r.body, want), "If-Range %s: %d", c.condition, r.status) or_return
	}
	r = fetch(t, s, fields = "Range: bytes=4-7\r\nIf-None-Match: W/\"fixture-v1\"\r\n") or_return
	testing.expectf(t, r.status == 304 && len(r.body) == 0 && lacks(r.head, "Content-Length"), "If-None-Match:\n%s", r.head) or_return
	r = fetch(t, s, "/untagged/normal.bin", "Range: bytes=4-7\r\nIf-Range: \"fixture-v1\"\r\n") or_return
	testing.expectf(
		t,
		r.status == 200 && slice.equal(r.body, normal) && value(r.head, "Cache-Control") == "no-store" && lacks(r.head, "ETag"),
		"untagged If-Range:\n%s",
		r.head,
	) or_return

	// HEAD ignores Range; traversal, private, symlink, size and method
	// policies hold.
	for range in ([]string{"bytes=4-7", "bytes=999999-"}) {
		r = fetch(t, s, fields = fmt.tprintf("Range: %s\r\n", range), method = "HEAD") or_return
		testing.expectf(
			t,
			r.status == 200 && value(r.head, "Content-Length") == fmt.tprint(NORMAL) && lacks(r.head, "Content-Range"),
			"HEAD %s:\n%s",
			range,
			r.head,
		) or_return
	}
	for path in ([]string{"/../outside.txt", "/%2e%2e/outside.txt", "/%2fetc/passwd", "/private.jsx", "/escape.txt", "/outside/outside.txt"}) {
		r = fetch(t, s, path) or_return
		testing.expectf(t, r.status == 404, "%s: %d", path, r.status) or_return
	}
	r = fetch(t, s, "/reject") or_return
	testing.expect_value(t, r.status, 500) or_return
	r = fetch(t, s, method = "POST") or_return
	testing.expect_value(t, r.status, 405) or_return

	// A 14 MiB range in 16 KiB storage, then the same connection is reused.
	{
		first, last :: 12345, 15000000
		want: [sha2.DIGEST_SIZE_256]u8
		{
			ctx: sha2.Context_256
			sha2.init_256(&ctx)
			sha2.update(&ctx, pattern(LARGE, 256)[first:last + 1])
			sha2.final(&ctx, want[:])
		}
		conn := harness.connect(t, s.port) or_return
		defer net.close(conn)
		harness.send_text(conn, fmt.tprintf("GET /large.bin HTTP/1.1\r\nHost: localhost\r\nRange: bytes=%d-%d\r\n\r\n", first, last))
		head := harness.read_head(t, conn) or_return
		testing.expectf(t, harness.status_of(head) == 206, "large range:\n%s", head) or_return
		total := last + 1 - first
		testing.expectf(t, value(head, "Content-Length") == fmt.tprint(total), "large range:\n%s", head) or_return
		ctx: sha2.Context_256
		sha2.init_256(&ctx)
		buffer := make([]u8, 32768, context.temp_allocator)
		count := 0
		for count < total {
			n, error := net.recv_tcp(conn, buffer[:min(len(buffer), total - count)])
			if !testing.expectf(t, error == nil && n > 0, "large range ended after %d bytes: %v", count, error) {
				return false
			}
			sha2.update(&ctx, buffer[:n])
			count += n
		}
		got: [sha2.DIGEST_SIZE_256]u8
		sha2.final(&ctx, got[:])
		testing.expect(t, got == want, "large range content differs") or_return
		r = exchange(t, conn, "/fast") or_return
		testing.expect_value(t, string(r.body), "ok") or_return
	}

	// Concurrent ranges, repeated disconnects and a rejected head release every
	// tracked byte and descriptor.
	{
		jobs: [40]Parallel
		for &job, n in jobs {
			job = {t = t, port = s.port, first = n * 73, normal = normal}
		}
		// Eight at a time, as a pool of eight clients would.
		for batch := 0; batch < len(jobs); batch += 8 {
			workers: [8]^thread.Thread
			for &worker, i in workers {
				worker = thread.create_and_start_with_poly_data(&jobs[batch + i], parallel_range)
			}
			for worker in workers {
				thread.join(worker)
				thread.destroy(worker)
			}
		}
		for job in jobs {
			testing.expectf(t, job.ok, "parallel range at %d", job.first) or_return
		}
	}
	for _ in 0 ..< 12 {
		conn := harness.connect(t, s.port) or_return
		defer net.close(conn)
		harness.send_text(conn, harness.request_wire("/slow.bin"))
		head := harness.read_head(t, conn) or_return
		testing.expectf(t, strings.has_prefix(head, "HTTP/1.1 200 "), "slow.bin:\n%s", head) or_return
	}
	fds := idle(t, s) or_return
	testing.expectf(t, fds == baseline, "%d descriptors open, %d at start", fds, baseline) or_return
	{
		conn := harness.connect(t, s.port) or_return
		defer net.close(conn)
		harness.send_text(conn, harness.request_wire("/badhead"))
		head := harness.read_head(t, conn) or_return
		// A rejected head answers 500.
		testing.expectf(t, strings.has_prefix(head, "HTTP/1.1 500 "), "badhead:\n%s", head) or_return
	}
	fds = idle(t, s) or_return
	testing.expectf(t, fds == baseline, "%d descriptors open, %d at start", fds, baseline) or_return

	// A slow reader reaches the write timeout and releases its producer while
	// a cheap route stays responsive. Descriptors are counted in the server.
	{
		slow := harness.connect(t, s.port) or_return
		defer net.close(slow)
		_ = net.set_option(slow, .Receive_Buffer_Size, 4096)
		harness.send_text(slow, harness.request_wire("/slow.bin"))
		harness.read_head(t, slow) or_return
		r = fetch(t, s, "/fast") or_return
		testing.expect_value(t, string(r.body), "ok") or_return
		time.sleep(500 * time.Millisecond)
		fds = idle(t, s) or_return
		testing.expectf(t, fds == baseline, "%d descriptors open, %d at start", fds, baseline) or_return
	}
	fds = idle(t, s) or_return
	testing.expectf(t, fds == baseline, "%d descriptors open, %d at start", fds, baseline) or_return

	// Shutdown with an active file stream releases every producer and buffer;
	// the program asserts that before it prints stopped.
	slow := harness.connect(t, s.port) or_return
	defer net.close(slow)
	harness.send_text(slow, harness.request_wire("/slow.bin"))
	harness.read_head(t, slow) or_return
	harness.send_input(t, s.input, "s") or_return
	harness.exited_cleanly(t, s.process) or_return
	return testing.expectf(t, len(harness.lines_with(s.process, "stopped")) == 1, "no stopped line\n%s", harness.transcript(s.process))
}
