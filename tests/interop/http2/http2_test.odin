// Saba's HTTP/2 against peers that share none of its code: libcurl (nghttp2
// under it) for ordinary exchanges, and OpenSSL with frames written here for
// what a client library will not send: malformed frames, stalled bodies,
// WebSocket over HTTP/2 (RFC 8441), streams held open, windows left empty.
package saba_interop_http2_test

import "core:crypto/sha2"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import curl "../../support/c/curl"
import fetch "../../support/fetch"
import harness "../../support/harness"
import peer "../../support/peer"

ALPN_SERVER :: "tests/interop/http2/server"
MULTIPLEX_SERVER :: "tests/interop/http2/multiplex"
WEBSOCKET_SERVER :: "tests/fixtures/apps/http2_websocket"

alpn_server :: proc(t: ^testing.T) -> (Server, bool) {
	return launch(t, ALPN_SERVER, harness.fixture("tls/rsa2048-valid.pem"), harness.fixture("tls/rsa2048.pem"))
}

// A TLS 1.3 connection that does not verify the server, as the peers of the
// ALPN server are.
insecure :: proc(t: ^testing.T, port: int, alpn: []string, loc := #caller_location) -> (^peer.Conn, bool) {
	conn, result := peer.dial(port, {tls = true, server_name = "fixture.invalid", alpn = alpn, timeout = 3 * time.Second})
	return conn, testing.expectf(t, result.ok, "TLS handshake: %s", result.message, loc = loc)
}

// GET and POST /echo through curl over the protocol ALPN picks.
exchange :: proc(t: ^testing.T, port: int, version: i64, want: int) {
	client := fetch.client_make()
	defer fetch.client_destroy(&client)
	url := fmt.tprintf("https://fixture.invalid:%d/echo", port)
	resolve := fmt.tprintf("fixture.invalid:%d:127.0.0.1", port)
	got := fetch.perform(&client, {url = url, resolve = resolve, http_version = version, timeout = 3 * time.Second})
	testing.expectf(t, got.code == curl.CURLE_OK, "GET: %s", got.message)
	testing.expect_value(t, got.status, 200)
	testing.expect_value(t, string(got.body), "ok")
	testing.expect_value(t, got.version, want)
	got = fetch.perform(
		&client,
		{url = url, resolve = resolve, http_version = version, body = "ping", headers = {"Content-Type: text/plain"}, timeout = 3 * time.Second},
	)
	testing.expectf(t, got.code == curl.CURLE_OK, "POST: %s", got.message)
	testing.expect_value(t, got.status, 200)
	testing.expect_value(t, string(got.body), "ping")
	testing.expect_value(t, got.version, want)
	// The second request reused the first one's connection.
	testing.expect_value(t, got.connects, 0)
}

@(test)
alpn_h2 :: proc(t: ^testing.T) {
	s, s_ok := alpn_server(t)
	if !s_ok {
		return
	}
	defer release(&s)
	conn, conn_ok := insecure(t, s.port, {"h2"})
	if !conn_ok {
		return
	}
	testing.expect_value(t, peer.alpn(conn), "h2")
	peer.close(conn)
	exchange(t, s.port, curl.CURL_HTTP_VERSION_2TLS, curl.CURL_HTTP_VERSION_2_0)
	if finish(t, &s) {
		_, _ = harness.expect_line(t, s.p, "REQ POST /echo 4")
	}
}

@(test)
alpn_http1 :: proc(t: ^testing.T) {
	s, s_ok := alpn_server(t)
	if !s_ok {
		return
	}
	defer release(&s)
	conn, conn_ok := insecure(t, s.port, {"http/1.1"})
	if !conn_ok {
		return
	}
	testing.expect_value(t, peer.alpn(conn), "http/1.1")
	peer.close(conn)
	exchange(t, s.port, curl.CURL_HTTP_VERSION_1_1, curl.CURL_HTTP_VERSION_1_1)
	if finish(t, &s) {
		_, _ = harness.expect_line(t, s.p, "REQ POST /echo 4")
	}
}

// Without ALPN the connection speaks HTTP/1.1.
@(test)
alpn_absent :: proc(t: ^testing.T) {
	s, s_ok := alpn_server(t)
	if !s_ok {
		return
	}
	defer release(&s)
	conn, conn_ok := insecure(t, s.port, nil)
	if !conn_ok {
		return
	}
	defer peer.close(conn)
	testing.expect_value(t, peer.alpn(conn), "")
	testing.expect(t, peer.write_string(conn, "GET /echo HTTP/1.1\r\nHost: fixture.invalid\r\nConnection: close\r\n\r\n"))
	response, status := peer.read_response(conn)
	testing.expect_value(t, status, peer.Status.Ok)
	testing.expect_value(t, response.status, 200)
	testing.expect_value(t, string(response.body[:]), "ok")
	if finish(t, &s) {
		_, _ = harness.expect_line(t, s.p, "REQ GET /echo 0")
	}
}

// A SETTINGS acknowledgement with a payload is a connection error of type
// FRAME_SIZE_ERROR (RFC 9113 section 6.5): GOAWAY, then the connection ends.
@(test)
malformed_settings :: proc(t: ^testing.T) {
	s, s_ok := alpn_server(t)
	if !s_ok {
		return
	}
	defer release(&s)
	conn, conn_ok := insecure(t, s.port, {"h2"})
	if !conn_ok {
		return
	}
	defer peer.close(conn)
	h := H2{t = t, conn = conn}
	testing.expect_value(t, peer.alpn(conn), "h2")
	testing.expect(t, peer.write_string(conn, PREFACE))
	testing.expect(t, write_frame(&h, SETTINGS, ACK, 0, {0}))
	goaway := false
	ended: peer.Status
	for {
		f, status := read_frame(&h, 1 << 20)
		if status != .Ok {
			ended = status
			break
		}
		if f.kind == GOAWAY {
			goaway = true
			testing.expectf(t, len(f.payload) >= 8 && be32(f.payload[4:8]) == 6, "GOAWAY %x is not FRAME_SIZE_ERROR", f.payload)
		}
	}
	// The connection must end, not stay open until the read times out.
	testing.expectf(t, ended != .Timeout, "the malformed connection stayed open (GOAWAY seen: %v)", goaway)
	testing.expectf(t, goaway, "no GOAWAY before the connection ended (%v)", ended)
	finish(t, &s)
}

// A request whose declared body never comes is reset when the body timeout
// (400 ms) passes.
@(test)
stalled_body :: proc(t: ^testing.T) {
	s, s_ok := alpn_server(t)
	if !s_ok {
		return
	}
	defer release(&s)
	conn, conn_ok := insecure(t, s.port, {"h2"})
	if !conn_ok {
		return
	}
	defer peer.close(conn)
	h := H2{t = t, conn = conn}
	testing.expect(t, peer.write_string(conn, PREFACE))
	testing.expect(t, write_frame(&h, SETTINGS, 0, 0))
	// :method POST and :scheme https indexed, :path /stall, :authority
	// localhost, content-length 32.
	block := []u8{
		0x83, 0x87,
		0x04, 0x06, '/', 's', 't', 'a', 'l', 'l',
		0x01, 0x09, 'l', 'o', 'c', 'a', 'l', 'h', 'o', 's', 't',
		0x0f, 0x0d, 0x02, '3', '2',
	}
	testing.expect(t, write_frame(&h, HEADERS, END_HEADERS, 1, block))
	reset := false
	for !reset {
		f, status := read_frame(&h, 1 << 20)
		if !testing.expectf(t, status == .Ok, "the stalled stream was not reset: %v", status) {
			break
		}
		if f.kind == SETTINGS && f.flags & ACK == 0 {
			_ = write_frame(&h, SETTINGS, ACK, 0)
		}
		reset = f.kind == RST_STREAM && f.stream == 1
	}
	finish(t, &s)
}

// The independent RFC 8441 peer: SETTINGS_ENABLE_CONNECT_PROTOCOL, an idle
// WebSocket beside ordinary requests, DATA with no WebSocket bytes, echo, ping,
// close, and a stream reset that leaves the connection usable.
@(test)
extended_connect :: proc(t: ^testing.T) {
	s, s_ok := launch(t, WEBSOCKET_SERVER, "server", harness.fixture("tls/localhost.pem"), harness.fixture("tls/rsa2048.pem"))
	if !s_ok {
		return
	}
	defer release(&s)
	conn, result := peer.dial(s.port, {tls = true, server_name = "localhost", alpn = {"h2"}, timeout = 8 * time.Second})
	if !testing.expectf(t, result.ok, "TLS handshake: %s", result.message) {
		return
	}
	h := H2{t = t, conn = conn}
	connected := connect_exchange(&h)
	peer.close(conn)
	if !connected || !finish(t, &s) {
		return
	}
	// The peer's two WebSockets: one closed in order, one reset.
	line, _ := harness.expect_line(t, s.p, "RESULT ")
	testing.expectf(t, strings.contains(line, "opened=2 dropped=2"), "%s", line)
	testing.expectf(t, strings.contains(line, "resets=1"), "%s", line)
}

connect_exchange :: proc(h: ^H2) -> bool {
	if peer.alpn(h.conn) != "h2" {
		return fail(h, "ALPN chose %q", peer.alpn(h.conn))
	}
	peer.write_string(h.conn, PREFACE) or_return
	write_frame(h, SETTINGS, 0, 0, {0, 2, 0, 0, 0, 0}) or_return
	settings := until(h, 0, SETTINGS) or_return
	enabled := false
	for at := 0; at + 6 <= len(settings.payload); at += 6 {
		if be16(settings.payload[at:]) == 8 && be32(settings.payload[at + 2:]) == 1 {
			enabled = true
		}
	}
	if !enabled {
		return fail(h, "no SETTINGS_ENABLE_CONNECT_PROTOCOL in %x", settings.payload)
	}
	write_frame(h, HEADERS, END_HEADERS, 1, connect("/socket")) or_return
	response := until(h, 1, HEADERS) or_return
	if response.flags & END_STREAM != 0 || len(response.payload) == 0 || response.payload[0] != 0x88 {
		return fail(h, "CONNECT did not answer an open 200: flags %d %x", response.flags, response.payload)
	}
	// An idle WebSocket must not hold the ordinary request slot.
	normal := make([dynamic]u8, context.temp_allocator)
	append(&normal, 0x82, 0x87)
	indexed_name(&normal, 1, "synthetic.invalid")
	indexed_name(&normal, 4, "/health")
	write_frame(h, HEADERS, END_STREAM | END_HEADERS, 3, normal[:]) or_return
	data_string(h, 3, "http-ok") or_return
	// Empty and padding-only DATA carry no WebSocket bytes and no end.
	write_frame(h, DATA, 0, 1) or_return
	write_frame(h, DATA, PADDED, 1, {3, 0, 0, 0}) or_return
	write_frame(h, DATA, 0, 1, masked_string(1, "hello")) or_return
	data(h, 1, {0x81, 5, 'h', 'e', 'l', 'l', 'o'}) or_return
	write_frame(h, DATA, 0, 1, masked_string(9, "P")) or_return
	data(h, 1, {0x8a, 1, 'P'}) or_return
	write_frame(h, DATA, 0, 1, masked(8, {3, 232})) or_return
	data(h, 1, {0x88, 2, 3, 232}) or_return
	write_frame(h, DATA, END_STREAM, 1) or_return
	// A reset is local to its stream; the connection stays usable.
	write_frame(h, HEADERS, END_HEADERS, 5, connect("/socket")) or_return
	until(h, 5, HEADERS) or_return
	write_frame(h, RST_STREAM, 0, 5, {0, 0, 0, 8}) or_return
	write_frame(h, HEADERS, END_STREAM | END_HEADERS, 7, normal[:]) or_return
	return data_string(h, 7, "http-ok")
}

// curl presents a client certificate to a server that requires one; the
// handler sees the identity the handshake authenticated. Without a
// certificate the request fails.
@(test)
client_certificates :: proc(t: ^testing.T) {
	root := harness.fixture("tls/mtls/root.pem")
	s, s_ok := launch(t, WEBSOCKET_SERVER, "server-mtls", harness.fixture("tls/mtls/server.pem"), harness.fixture("tls/mtls/server-key.pem"), root)
	if !s_ok {
		return
	}
	defer release(&s)
	url := fmt.tprintf("https://localhost:%d/health", s.port)
	for name in ([]string{"client", "client-large"}) {
		cert := harness.fixture(fmt.tprintf("tls/mtls/%s.pem", name))
		client := fetch.client_make()
		got := fetch.perform(
			&client,
			{url = url, http_version = curl.CURL_HTTP_VERSION_2TLS, ca_file = root, cert = cert, key = harness.fixture(fmt.tprintf("tls/mtls/%s-key.pem", name))},
		)
		fetch.client_destroy(&client)
		testing.expectf(t, got.code == curl.CURLE_OK, "%s: %s", name, got.message)
		testing.expect_value(t, got.status, 200)
		testing.expect_value(t, got.version, curl.CURL_HTTP_VERSION_2_0)
		testing.expect_value(t, string(got.body), "http-ok")
		identity, _ := fetch.header(got, "x-client-identity")
		testing.expectf(t, identity == certificate_sha256(t, cert), "%s: the server saw identity %q", name, identity)
	}
	client := fetch.client_make()
	got := fetch.perform(&client, {url = url, http_version = curl.CURL_HTTP_VERSION_2TLS, ca_file = root, timeout = 3 * time.Second})
	fetch.client_destroy(&client)
	testing.expectf(t, got.code != curl.CURLE_OK, "a request without a client certificate got %d", got.status)
	log.infof("without a client certificate: %s", got.message)
	finish(t, &s)
}

// The SHA-256 of the first certificate in a PEM file, in hex.
certificate_sha256 :: proc(t: ^testing.T, path: string) -> string {
	pem, error := os.read_entire_file(path, context.temp_allocator)
	if !testing.expectf(t, error == nil, "could not read %s: %v", path, error) {
		return ""
	}
	text := string(pem)
	begin := strings.index(text, "-----BEGIN CERTIFICATE-----")
	end := strings.index(text, "-----END CERTIFICATE-----")
	if !testing.expectf(t, begin >= 0 && end > begin, "%s holds no certificate", path) {
		return ""
	}
	body, _ := strings.remove_all(text[begin + len("-----BEGIN CERTIFICATE-----"):end], "\n", context.temp_allocator)
	der, decoded := base64.decode(body, allocator = context.temp_allocator)
	if !testing.expectf(t, decoded == nil, "%s: %v", path, decoded) {
		return ""
	}
	digest: [sha2.DIGEST_SIZE_256]u8
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, der)
	sha2.final(&ctx, digest[:])
	return string(hex.encode(digest[:], context.temp_allocator))
}

// The multiplexing peer: thirty-two streams granted, twenty-three held open
// at once (deferred responses, producers, an incomplete POST, a WebSocket),
// ordinary requests beside them and past the lifetime of thirty-two stream
// IDs, cancellation local to two streams, a producer left without stream
// window, a rejected allocation answered 503, a 204 and a HEAD 304 without
// invented fields, six WebSockets under the one grant, and GOAWAY.
@(test)
multiplex :: proc(t: ^testing.T) {
	s, s_ok := launch(t, MULTIPLEX_SERVER, harness.fixture("tls/localhost.pem"), harness.fixture("tls/rsa2048.pem"))
	if !s_ok {
		return
	}
	defer release(&s)
	conn, result := peer.dial(s.port, {tls = true, server_name = "localhost", alpn = {"h2"}, timeout = 15 * time.Second})
	if !testing.expectf(t, result.ok, "TLS handshake: %s", result.message) {
		return
	}
	h := H2{t = t, conn = conn}
	started := time.tick_now()
	passed := multiplex_exchange(&h)
	log.infof(
		"multiplex: %v, %d SETTINGS and %d PING acknowledged, %d frames",
		time.tick_since(started),
		h.settings_acks,
		h.ping_acks,
		h.frames,
	)
	peer.close(conn)
	if !passed || !finish(t, &s) {
		return
	}
	_, _ = harness.expect_line(t, s.p, "RESOURCES retired-zero")
	line, _ := harness.expect_line(t, s.p, "WORK ")
	testing.expectf(t, strings.contains(line, "created=23 disposed=23 cancelled=3"), "%s", line)
}

multiplex_preface :: proc(h: ^H2) -> bool {
	peer.write_string(h.conn, PREFACE) or_return
	write_frame(h, SETTINGS, 0, 0, {0, 2, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0}) or_return
	settings := until(h, 0, SETTINGS) or_return
	grant: u32
	for at := 0; at + 6 <= len(settings.payload); at += 6 {
		if be16(settings.payload[at:]) == 3 {
			grant = be32(settings.payload[at + 2:])
		}
	}
	if grant != 32 {
		return fail(h, "SETTINGS_MAX_CONCURRENT_STREAMS %d, want 32", grant)
	}
	return true
}

multiplex_exchange :: proc(h: ^H2) -> bool {
	multiplex_preface(h) or_return
	// Twenty live deferred responses plus a parked producer, an incomplete
	// POST and a WebSocket.
	for id := u32(1); id <= 39; id += 2 {
		write_frame(h, HEADERS, END_STREAM | END_HEADERS, id, get("/hold")) or_return
	}
	write_frame(h, HEADERS, END_STREAM | END_HEADERS, 41, get("/stream")) or_return
	post := make([dynamic]u8, context.temp_allocator)
	append(&post, 0x83, 0x87)
	indexed_name(&post, 1, "synthetic.invalid")
	indexed_name(&post, 4, "/post")
	literal(&post, "content-length", "4")
	write_frame(h, HEADERS, END_HEADERS, 43, post[:]) or_return
	write_frame(h, DATA, 0, 43, transmute([]u8)string("ab")) or_return
	write_frame(h, HEADERS, END_HEADERS, 45, connect("/socket")) or_return
	// Fast ordinary requests finish while those twenty-three streams are idle.
	write_frame(h, HEADERS, END_STREAM | END_HEADERS, 47, get("/health")) or_return
	data_string(h, 47, "http-ok") or_return
	// Cancellation belongs only to one deferred response and one producer.
	cancel := []u8{0, 0, 0, 8}
	write_frame(h, RST_STREAM, 0, 1, cancel) or_return
	write_frame(h, RST_STREAM, 0, 41, cancel) or_return
	// More than thirty-two stream IDs over the connection's life.
	for id := u32(49); id <= 177; id += 2 {
		write_frame(h, HEADERS, END_STREAM | END_HEADERS, id, get("/health")) or_return
		data_string(h, id, "http-ok") or_return
	}
	write_frame(h, DATA, END_STREAM, 43, transmute([]u8)string("cd")) or_return
	data_string(h, 43, "http-ok") or_return
	write_frame(h, DATA, 0, 45, masked_string(1, "still-live")) or_return
	data(h, 45, server_text("still-live")) or_return
	write_frame(h, HEADERS, END_STREAM | END_HEADERS, 179, get("/release")) or_return
	remaining := make(map[u32]bool, context.temp_allocator)
	for id := u32(3); id <= 39; id += 2 {
		remaining[id] = true
	}
	remaining[179] = true
	bodies := make(map[u32]string, context.temp_allocator)
	for len(remaining) > 0 {
		f, status := read_frame(h)
		if status != .Ok {
			return fail(h, "waiting for the held responses: %v", status)
		}
		advance(h, f) or_return
		if f.kind == RST_STREAM {
			return fail(h, "unexpected reset of stream %d", f.stream)
		}
		if f.kind != DATA {
			continue
		}
		body := strings.concatenate({bodies[f.stream], string(f.payload)}, context.temp_allocator)
		bodies[f.stream] = body
		if f.flags & END_STREAM != 0 && remaining[f.stream] {
			want := "http-ok" if f.stream == 179 else "held-ok"
			if body != want {
				return fail(h, "body of stream %d: %q", f.stream, body)
			}
			delete_key(&remaining, f.stream)
		}
	}
	// A finished producer goes through the same scheduling as the others.
	write_frame(h, HEADERS, END_STREAM | END_HEADERS, 181, get("/stream")) or_return
	data_string(h, 181, "held-ok") or_return
	// This producer's stream window is left empty and only the connection is
	// credited; another ordinary response must still finish.
	write_frame(h, HEADERS, END_STREAM | END_HEADERS, 183, get("/bulk")) or_return
	write_frame(h, HEADERS, END_STREAM | END_HEADERS, 185, get("/health")) or_return
	bulk := 0
	fast := make([dynamic]u8, context.temp_allocator)
	for string(fast[:]) != "http-ok" {
		f, status := read_frame(h)
		if status != .Ok {
			return fail(h, "waiting beside the blocked producer: %v", status)
		}
		if f.kind == RST_STREAM {
			return fail(h, "bulk reset on stream %d", f.stream)
		}
		if f.kind == DATA && f.stream == 183 {
			bulk += len(f.payload)
			if len(f.payload) > 0 {
				write_frame(h, WINDOW_UPDATE, 0, 0, u32_bytes(u32(len(f.payload)))) or_return
			}
		} else {
			advance(h, f) or_return
			if f.kind == DATA && f.stream == 185 {
				append(&fast, ..f.payload)
			}
		}
	}
	if bulk > 65535 {
		return fail(h, "the producer sent %d bytes past its 65535-byte stream window", bulk)
	}
	write_frame(h, RST_STREAM, 0, 183, cancel) or_return
	// 204: no body, no reset.
	write_frame(h, HEADERS, END_STREAM | END_HEADERS, 187, get("/no-content")) or_return
	for ended := false; !ended; {
		f, status := read_frame(h)
		if status != .Ok {
			return fail(h, "waiting for the 204: %v", status)
		}
		advance(h, f) or_return
		if f.kind == RST_STREAM {
			return fail(h, "the 204 reset stream %d", f.stream)
		}
		if f.stream != 187 {
			continue
		}
		if f.kind == DATA && len(f.payload) != 0 {
			return fail(h, "the 204 has a body")
		}
		ended = (f.kind == DATA || f.kind == HEADERS) && f.flags & END_STREAM != 0
	}
	// A rejected operation allocation is answered locally (503), and the
	// connection stays usable.
	write_frame(h, HEADERS, END_STREAM | END_HEADERS, 189, get("/pressure")) or_return
	head := until(h, 189, HEADERS) or_return
	if len(head.payload) == 0 || head.payload[0] == 0x88 {
		return fail(h, "the pressure request was not rejected: %x", head.payload)
	}
	write_frame(h, HEADERS, END_STREAM | END_HEADERS, 191, get("/health")) or_return
	data_string(h, 191, "http-ok") or_return
	// A conditional asset has a GET representation, and its HEAD 304 has
	// neither a body nor an invented content-length 0.
	write_frame(h, HEADERS, END_STREAM | END_HEADERS, 193, get("/asset")) or_return
	data_string(h, 193, "asset-body") or_return
	conditional := make([dynamic]u8, context.temp_allocator)
	indexed_name(&conditional, 2, "HEAD")
	append(&conditional, 0x87)
	indexed_name(&conditional, 1, "synthetic.invalid")
	indexed_name(&conditional, 4, "/asset")
	literal(&conditional, "if-none-match", "*")
	write_frame(h, HEADERS, END_STREAM | END_HEADERS, 195, conditional[:]) or_return
	head = until(h, 195, HEADERS) or_return
	length, not_modified, decoded := conditional_head_fields(head.payload)
	if !decoded || !not_modified || length {
		return fail(h, "HEAD 304: not-modified %v, content-length %v, block %x", not_modified, length, head.payload)
	}
	for ended := head.flags & END_STREAM != 0; !ended; {
		f, status := read_frame(h)
		if status != .Ok {
			return fail(h, "waiting for the end of the HEAD 304: %v", status)
		}
		advance(h, f) or_return
		if f.kind == RST_STREAM {
			return fail(h, "the HEAD 304 was reset")
		}
		if f.stream != 195 {
			continue
		}
		if f.kind == DATA && len(f.payload) > 0 {
			return fail(h, "the HEAD 304 has a body")
		}
		ended = f.flags & END_STREAM != 0
	}
	// Six admitted WebSockets: upgrades share the configured grant, with no
	// separate ceiling of four.
	sockets := []u32{45, 197, 199, 201, 203, 205}
	for id in sockets[1:] {
		write_frame(h, HEADERS, END_HEADERS, id, connect("/socket")) or_return
		opened := until(h, id, HEADERS) or_return
		if opened.flags & END_STREAM != 0 {
			return fail(h, "WebSocket on stream %d was rejected", id)
		}
	}
	// GOAWAY ends admission while the admitted WebSockets stay usable.
	write_frame(h, GOAWAY, 0, 0, make([]u8, 8, context.temp_allocator)) or_return
	for final := false; !final; {
		f, status := read_frame(h)
		if status != .Ok {
			return fail(h, "waiting for the final GOAWAY: %v", status)
		}
		advance(h, f) or_return
		if f.kind != GOAWAY {
			continue
		}
		if len(f.payload) < 8 {
			return fail(h, "short GOAWAY")
		}
		last, code := be32(f.payload[:4]), be32(f.payload[4:8])
		if code != 0 {
			return fail(h, "GOAWAY with error %d", code)
		}
		if last != 0x7fffffff {
			if last < 205 {
				return fail(h, "the final GOAWAY (last stream %d) excludes an admitted stream", last)
			}
			final = true
		}
	}
	for id in sockets {
		write_frame(h, DATA, 0, id, masked_string(1, "drain-live")) or_return
		data(h, id, server_text("drain-live")) or_return
		write_frame(h, DATA, END_STREAM, id, masked(8, {3, 232})) or_return
		for {
			f, status := read_frame(h)
			if status != .Ok {
				return fail(h, "waiting for the end of WebSocket %d: %v", id, status)
			}
			advance(h, f) or_return
			if f.kind == DATA && f.stream == id && f.flags & END_STREAM != 0 {
				break
			}
		}
	}
	return true
}

// A server drain closes an open WebSocket with 1001 and ends with a final
// GOAWAY.
@(test)
multiplex_drain :: proc(t: ^testing.T) {
	s, s_ok := launch(t, MULTIPLEX_SERVER, harness.fixture("tls/localhost.pem"), harness.fixture("tls/rsa2048.pem"))
	if !s_ok {
		return
	}
	defer release(&s)
	conn, result := peer.dial(s.port, {tls = true, server_name = "localhost", alpn = {"h2"}, timeout = 15 * time.Second})
	if !testing.expectf(t, result.ok, "TLS handshake: %s", result.message) {
		return
	}
	h := H2{t = t, conn = conn}
	passed := drain_exchange(&h)
	peer.close(conn)
	if passed {
		finish(t, &s)
	}
}

drain_exchange :: proc(h: ^H2) -> bool {
	multiplex_preface(h) or_return
	write_frame(h, HEADERS, END_HEADERS, 1, connect("/socket")) or_return
	until(h, 1, HEADERS) or_return
	write_frame(h, HEADERS, END_STREAM | END_HEADERS, 3, get("/drain")) or_return
	closed, final := false, false
	for !closed || !final {
		f, status := read_frame(h)
		if status != .Ok {
			return fail(h, "waiting for the drain (close %v, final GOAWAY %v): %v", closed, final, status)
		}
		advance(h, f) or_return
		if f.kind == DATA && f.stream == 1 && len(f.payload) > 0 {
			if len(f.payload) != 4 || f.payload[0] != 0x88 || be16(f.payload[2:]) != 1001 {
				return fail(h, "the drain did not close the WebSocket with 1001: %x", f.payload)
			}
			closed = true
			write_frame(h, DATA, END_STREAM, 1, masked(8, {3, 233})) or_return
		}
		if f.kind == GOAWAY && len(f.payload) >= 4 && be32(f.payload[:4]) != 0x7fffffff {
			final = true
		}
	}
	return true
}
