// HEAD and cache validation through the public facade over raw sockets:
// GET/HEAD metadata parity, SHA-256 ETags checked independently, If-None-Match
// forms, headers-only 304s, the production snapshot, development freshness,
// and containment checks that conditions cannot bypass.
package saba_e2e_conditional_assets_test

import "core:crypto/sha2"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"
import harness "../../support/harness"

SOURCE :: "tests/fixtures/apps/async_server"
TIMEOUT :: 8 * time.Second

@(test)
conditional_assets :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 3 * time.Minute)
	work := harness.workdir(t, "conditional-assets")
	defer os.remove_all(work)
	built, ok := harness.build(t, SOURCE, work)
	if !ok {
		return
	}
	binary := strings.clone(built)
	defer delete(binary)
	root := strings.clone(work)
	defer delete(root)
	if !write_web(t, root) {
		return
	}
	web := fmt.tprintf("%s/web", root)
	if !check_production(t, binary, web) {
		return
	}
	free_all(context.temp_allocator)
	check_development(t, binary, fmt.tprintf("%s/web", root))
}

write :: proc(t: ^testing.T, path, data: string, loc := #caller_location) -> bool {
	error := os.write_entire_file(path, data)
	return testing.expectf(t, error == nil, "writing %s: %v", path, error, loc = loc)
}

write_web :: proc(t: ^testing.T, root: string) -> bool {
	web := fmt.tprintf("%s/web", root)
	for directory in ([]string{"assets", "pages"}) {
		error := os.make_directory_all(fmt.tprintf("%s/%s", web, directory))
		testing.expectf(t, error == nil, "creating %s: %v", directory, error) or_return
	}
	write(t, fmt.tprintf("%s/assets/data.txt", web), "abc") or_return
	write(t, fmt.tprintf("%s/assets/empty.txt", web), "") or_return
	write(t, fmt.tprintf("%s/assets/private.jsx", web), "export const secret = 1;") or_return
	write(t, fmt.tprintf("%s/outside.txt", root), "secret") or_return
	linked := os.symlink(fmt.tprintf("%s/outside.txt", root), fmt.tprintf("%s/assets/escape.txt", web))
	testing.expectf(t, linked == nil, "symlink: %v", linked) or_return
	write(t, fmt.tprintf("%s/view.jsx", web), "export default function View(){ return <div>hello</div>; }") or_return
	write(t, fmt.tprintf("%s/pages/index.jsx", web), "export default function Home(){ return <h1>Home</h1>; }") or_return
	return write(t, fmt.tprintf("%s/index.html", web), "<html><head></head><body><!--saba:page--></body></html>")
}

Server :: struct {
	process: ^harness.Process,
	input:   ^os.File,
	port:    int,
}

launch :: proc(t: ^testing.T, binary, web: string, development := false) -> (s: Server, ok: bool) {
	env := []string {
		fmt.tprintf("SABA_TEST_WEB=%s", web),
		"SABA_TEST_WORKERS=1",
		"SABA_TEST_CAPACITY=64",
		"SABA_TEST_INITIAL=0",
		"SABA_TEST_FAIL_GROWTH=0",
		fmt.tprintf("SABA_TEST_DEVELOPMENT=%d", int(development)),
	}
	s.process, s.input = harness.start_with_input(t, {binary}, env) or_return
	s.port, ok = harness.ready(t, s.process, timeout = TIMEOUT)
	if !ok {
		dispose(&s)
	}
	return
}

dispose :: proc(s: ^Server) {
	harness.stop(s.process)
	s.process = nil
	if s.input != nil {
		os.close(s.input)
		s.input = nil
	}
}

// The fixture prints "stopped" on the first newline and exits on the second.
shutdown :: proc(t: ^testing.T, s: ^Server) -> bool {
	harness.send_input(t, s.input, "\n") or_return
	harness.await_lines(t, s.process, "stopped", 1, 5 * time.Second) or_return
	line := harness.lines_with(s.process, "stopped")[0]
	testing.expectf(t, line == "stopped", "stop line %q", line) or_return
	state, error := os.process_wait(s.process.handle, 0)
	testing.expectf(t, error != nil || !state.exited, "fixture must stay alive until the second newline") or_return
	harness.send_input(t, s.input, "\n") or_return
	return harness.exited_cleanly(t, s.process)
}

Exchange :: struct {
	status: int,
	fields: map[string]string,
	body:   string,
}

// One request on its own connection. HEAD and 304 carry no body; after the
// response the server must close with nothing more on the wire.
exchange :: proc(
	t: ^testing.T,
	s: ^Server,
	path: string,
	method := "GET",
	fields: [][2]string = nil,
	loc := #caller_location,
) -> (
	e: Exchange,
	ok: bool,
) {
	conn := harness.connect(t, s.port, TIMEOUT, loc) or_return
	defer net.close(conn)
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%s %s HTTP/1.1\r\nHost: localhost\r\n", method, path)
	for f in fields {
		fmt.sbprintf(&b, "%s: %s\r\n", f[0], f[1])
	}
	strings.write_string(&b, "\r\n")
	harness.send_text(conn, strings.to_string(b))
	head := harness.read_head(t, conn, loc) or_return
	e.status = harness.status_of(head)
	e.fields = make(map[string]string, context.temp_allocator)
	text := head
	for line in strings.split_lines_iterator(&text) {
		if separator := strings.index(line, ": "); separator >= 0 {
			e.fields[line[:separator]] = strings.trim_right(line[separator + 2:], "\r")
		}
	}
	if method != "HEAD" && e.status != 304 {
		value, found := e.fields["Content-Length"]
		testing.expectf(t, found, "%s %s: no Content-Length in\n%s", method, path, head, loc = loc) or_return
		length, _ := strconv.parse_int(value)
		body := harness.read_n(t, conn, length, loc = loc) or_return
		e.body = string(body)
	}
	one: [1]u8
	n, error := net.recv_tcp(conn, one[:])
	ok = testing.expectf(t, n == 0 && error == nil, "%s %s: unexpected bytes after HEAD/304 or a framing error (%d, %v)", method, path, n, error, loc = loc)
	return
}

same_fields :: proc(a, b: map[string]string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for name, value in a {
		if other, found := b[name]; !found || other != value {
			return false
		}
	}
	return true
}

same :: proc(a, b: Exchange) -> bool {
	return a.status == b.status && a.body == b.body && same_fields(a.fields, b.fields)
}

etag :: proc(body: string) -> string {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]u8)body)
	digest: [sha2.DIGEST_SIZE_256]u8
	sha2.final(&ctx, digest[:])
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '"')
	for byte in digest {
		fmt.sbprintf(&b, "%02x", byte)
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

check_production :: proc(t: ^testing.T, binary, web: string) -> bool {
	original: Exchange
	{
		s := launch(t, binary, web) or_return
		defer dispose(&s)
		for path in ([]string{"/assets/data.txt", "/assets/empty.txt", "/view.js", "/", "/__saba/dom.js", "/__saba/page-entry.js"}) {
			get := exchange(t, &s, path) or_return
			testing.expectf(t, get.status == 200 && get.fields["Cache-Control"] == "no-cache", "%s: %d %v", path, get.status, get.fields) or_return
			tag := etag(get.body)
			testing.expectf(t, get.fields["ETag"] == tag, "%s: ETag %q, want %q", path, get.fields["ETag"], tag) or_return
			head := exchange(t, &s, path, "HEAD") or_return
			testing.expectf(t, head.status == 200 && head.body == "" && same_fields(head.fields, get.fields), "%s: HEAD %v, GET %v", path, head.fields, get.fields) or_return
			for method in ([]string{"GET", "HEAD"}) {
				for condition in ([]string{tag, fmt.tprintf("W/%s", tag), fmt.tprintf(`"miss", W/%s`, tag), "*"}) {
					e := exchange(t, &s, path, method, {{"If-None-Match", condition}}) or_return
					testing.expectf(t, e.status == 304 && e.body == "", "%s %s If-None-Match %s: %d", method, path, condition, e.status) or_return
					testing.expectf(t, e.fields["ETag"] == tag && e.fields["Cache-Control"] == "no-cache", "304 fields %v", e.fields) or_return
					_, length := e.fields["Content-Length"]
					_, coding := e.fields["Transfer-Encoding"]
					testing.expectf(t, !length && !coding, "304 with framing fields %v", e.fields) or_return
				}
				repeated := exchange(t, &s, path, method, {{"If-None-Match", `"miss"`}, {"if-none-match", tag}}) or_return
				testing.expectf(t, repeated.status == 304 && repeated.fields["ETag"] == tag, "repeated condition: %d %v", repeated.status, repeated.fields) or_return
				misses := [][][2]string {
					{{"If-None-Match", `"miss"`}},
					{{"If-None-Match", fmt.tprintf("%s, invalid", tag)}},
					{{"If-None-Match", "*"}, {"If-None-Match", tag}},
				}
				for fields in misses {
					e := exchange(t, &s, path, method, fields) or_return
					testing.expectf(t, e.status == 200, "%s %s %v: %d", method, path, fields, e.status) or_return
				}
			}
		}
		// A production mount keeps its startup snapshot until restarted.
		original = exchange(t, &s, "/assets/data.txt") or_return
		write(t, fmt.tprintf("%s/assets/data.txt", web), "new bytes") or_return
		again := exchange(t, &s, "/assets/data.txt") or_return
		testing.expectf(t, same(again, original), "snapshot changed: %v", again) or_return
		validated := exchange(t, &s, "/assets/data.txt", fields = {{"If-None-Match", original.fields["ETag"]}}) or_return
		testing.expect_value(t, validated.status, 304) or_return
		for method in ([]string{"GET", "HEAD"}) {
			for path in ([]string{"/assets/%2e%2e/index.html", "/assets/private.jsx", "/assets/escape.txt", "/%2e%2e/view.js", "/private.jsx"}) {
				e := exchange(t, &s, path, method, {{"If-None-Match", "*"}}) or_return
				testing.expectf(t, e.status == 404, "%s %s: %d", method, path, e.status) or_return
			}
		}
		shutdown(t, &s) or_return
	}
	// A restart takes the new bytes and a new validator.
	s := launch(t, binary, web) or_return
	defer dispose(&s)
	tag := original.fields["ETag"]
	current := exchange(t, &s, "/assets/data.txt", fields = {{"If-None-Match", tag}}) or_return
	testing.expectf(t, current.status == 200 && current.body == "new bytes", "after restart: %d %q", current.status, current.body) or_return
	testing.expectf(t, current.fields["ETag"] != tag, "ETag unchanged after restart") or_return
	return shutdown(t, &s)
}

check_development :: proc(t: ^testing.T, binary, web: string) -> bool {
	s := launch(t, binary, web, development = true) or_return
	defer dispose(&s)
	for path in ([]string{"/assets/data.txt", "/view.js", "/"}) {
		get := exchange(t, &s, path, fields = {{"If-None-Match", "*"}}) or_return
		testing.expectf(t, get.status == 200 && get.fields["Cache-Control"] == "no-store", "%s: %d %v", path, get.status, get.fields) or_return
		_, tagged := get.fields["ETag"]
		testing.expectf(t, !tagged, "%s: development response carries an ETag", path) or_return
		head := exchange(t, &s, path, "HEAD", {{"If-None-Match", "*"}}) or_return
		testing.expectf(t, head.status == 200 && head.body == "" && same_fields(head.fields, get.fields), "%s: HEAD %v, GET %v", path, head.fields, get.fields) or_return
	}
	changes := [][3]string {
		{"/assets/data.txt", "assets/data.txt", "changed asset"},
		{"/view.js", "view.jsx", "export default function View(){ return <p>changed module</p>; }"},
		{"/", "index.html", "<html><head></head><body>changed shell<!--saba:page--></body></html>"},
	}
	for c in changes {
		previous := exchange(t, &s, c[0]) or_return
		write(t, fmt.tprintf("%s/%s", web, c[1]), c[2]) or_return
		current := exchange(t, &s, c[0], fields = {{"If-None-Match", "*"}}) or_return
		testing.expectf(t, current.status == 200 && current.body != previous.body && strings.contains(current.body, "changed"), "%s after a change: %d %q", c[0], current.status, current.body) or_return
		head := exchange(t, &s, c[0], "HEAD") or_return
		testing.expectf(t, same_fields(head.fields, current.fields), "%s: HEAD %v, GET %v", c[0], head.fields, current.fields) or_return
	}
	return shutdown(t, &s)
}
