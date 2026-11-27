// Saba's HTTP/1.1 over TLS 1.3 against two independent TLS stacks: libcurl
// and OpenSSL driven byte by byte. Saba's own server, the application server
// and the facade all speak the same wire; certificates are rejected for the
// exact reason; records split into seven-byte writes, a ClientHello that never
// finishes, a reader too slow for an 8 MiB body, and every way a shutdown can
// find a connection (mid-handshake, mid-body, deferred, a WebSocket) end in
// order with nothing left open.
package saba_interop_https_test

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import curl "../../support/c/curl"
import openssl "../../support/c/openssl"
import fetch "../../support/fetch"
import harness "../../support/harness"
import peer "../../support/peer"

OK_BODY :: "https80-ok\n"
LARGE_BYTES :: 8 * 1024 * 1024

cert :: proc() -> string {
	return harness.fixture("tls/rsa2048-valid.pem")
}

// The client the Go peer was: verified TLS 1.3 to synthetic.invalid with
// ALPN http/1.1 (plain TCP for the plain server).
dial :: proc(t: ^testing.T, port: int, plain := false, fragment := 0, loc := #caller_location) -> (^peer.Conn, bool) {
	conn, result := peer.dial(
		port,
		{
			tls = !plain,
			server_name = "synthetic.invalid",
			ca_file = cert(),
			alpn = {"http/1.1"},
			fragment = fragment,
			timeout = 20 * time.Second,
		},
	)
	if !testing.expectf(t, result.ok, "handshake: %s (verify %d)", result.message, result.verify_result, loc = loc) {
		return nil, false
	}
	if !plain && !testing.expectf(t, peer.alpn(conn) == "http/1.1", "ALPN chose %q", peer.alpn(conn), loc = loc) {
		peer.close(conn)
		return nil, false
	}
	return conn, true
}

expect_response :: proc(t: ^testing.T, conn: ^peer.Conn, method, body: string, loc := #caller_location) -> bool {
	response, status := peer.read_response(conn, method, LARGE_BYTES + 1)
	if !testing.expectf(t, status == .Ok, "%s response: %v", method, status, loc = loc) {
		return false
	}
	ok := testing.expectf(t, response.status == 200, "%s status %d", method, response.status, loc = loc)
	ok &&= testing.expectf(t, string(response.body[:]) == body, "%s body %q, want %q", method, string(response.body[:]), body, loc = loc)
	return ok
}

// Four requests on one connection, the last one closing it: the peer then
// reads an orderly end (close_notify over TLS).
four_requests :: proc(t: ^testing.T, conn: ^peer.Conn) {
	for path in ([]string{"/fast", "/second"}) {
		testing.expect(t, peer.request(conn, "GET", path))
		expect_response(t, conn, "GET", OK_BODY)
	}
	testing.expect(t, peer.request(conn, "POST", "/echo", "fragmented-body"))
	expect_response(t, conn, "POST", "fragmented-body")
	testing.expect(t, peer.request(conn, "GET", "/close", close = true))
	expect_response(t, conn, "GET", OK_BODY)
	one: [1]u8
	n, status := peer.read(conn, one[:])
	testing.expectf(t, n == 0 && status == .Closed, "the closing response ended with %v after %d bytes", status, n)
}

trusted :: proc(t: ^testing.T, mode: string) {
	s, launched := launch(t, mode)
	if !launched {
		return
	}
	defer close(t, &s)
	conn, connected := dial(t, s.port, plain = mode == "plain")
	if !connected {
		return
	}
	four_requests(t, conn)
	peer.close(conn)
	if m, ok := idle(t, &s); ok {
		testing.expectf(t, m.handled == 4, "%v", m)
	}
}

@(test)
trusted_core :: proc(t: ^testing.T) {
	trusted(t, "core")
}

@(test)
trusted_application :: proc(t: ^testing.T) {
	trusted(t, "application")
}

@(test)
trusted_facade :: proc(t: ^testing.T) {
	trusted(t, "facade")
}

@(test)
trusted_plain :: proc(t: ^testing.T) {
	trusted(t, "plain")
}

Verification :: enum {
	Trust,
	Hostname,
	Expired,
	Before,
	Trusted,
}

// Each rejection has its exact OpenSSL verify result. Only the trusted case
// reaches the handler.
@(test)
verification :: proc(t: ^testing.T) {
	s, launched := launch(t, "core")
	if !launched {
		return
	}
	defer close(t, &s)
	for client in ([]string{"curl", "openssl"}) {
		for mode in Verification {
			before, ok := idle(t, &s)
			if !ok {
				return
			}
			if client == "curl" {
				verify_curl(t, s.port, mode)
			} else {
				verify_openssl(t, s.port, mode)
			}
			after, idle_again := idle(t, &s)
			if !idle_again {
				return
			}
			if mode != .Trusted {
				testing.expectf(t, before.handled == after.handled, "%s %v reached the handler: %v %v", client, mode, before, after)
			} else {
				testing.expectf(t, after.handled == before.handled + 1, "%s %v: %v %v", client, mode, before, after)
			}
		}
	}
}

expected_verify :: proc(mode: Verification) -> int {
	switch mode {
	case .Trust:
		return openssl.X509_V_ERR_DEPTH_ZERO_SELF_SIGNED_CERT
	case .Hostname:
		return openssl.X509_V_ERR_HOSTNAME_MISMATCH
	case .Expired:
		return openssl.X509_V_ERR_CERT_HAS_EXPIRED
	case .Before:
		return openssl.X509_V_ERR_CERT_NOT_YET_VALID
	case .Trusted:
	}
	return openssl.X509_V_OK
}

verify_time :: proc(mode: Verification) -> i64 {
	#partial switch mode {
	case .Expired:
		return 2000000000
	case .Before:
		// The epoch itself; 0 means now to the peers.
		return 1
	}
	return 1790000000
}

verify_curl :: proc(t: ^testing.T, port: int, mode: Verification) {
	host := "wrong.invalid" if mode == .Hostname else "synthetic.invalid"
	anchor := harness.fixture("tls/rsa4096-valid.pem") if mode == .Trust else cert()
	client := fetch.client_make()
	defer fetch.client_destroy(&client)
	got := fetch.perform(
		&client,
		{
			url = fmt.tprintf("https://%s:%d/close", host, port),
			resolve = fmt.tprintf("%s:%d:127.0.0.1", host, port),
			http_version = curl.CURL_HTTP_VERSION_1_1,
			ca_file = anchor,
			verify_time = verify_time(mode),
			timeout = 5 * time.Second,
		},
	)
	if mode == .Trusted {
		testing.expectf(t, got.code == curl.CURLE_OK, "curl: %s", got.message)
		testing.expect_value(t, got.status, 200)
		testing.expect_value(t, got.version, curl.CURL_HTTP_VERSION_1_1)
		testing.expect_value(t, string(got.body), OK_BODY)
		return
	}
	testing.expectf(t, got.code == curl.CURLE_PEER_FAILED_VERIFICATION, "curl %v: %s", mode, got.message)
	// curl matches the name itself once OpenSSL verified the chain, so the
	// rejection is its own message rather than a verify result.
	if mode == .Hostname {
		testing.expectf(t, strings.contains(got.message, "subject name matches target hostname"), "curl %v: %s", mode, got.message)
	} else {
		testing.expectf(t, got.verify_result == expected_verify(mode), "curl %v: verify result %d (%s)", mode, got.verify_result, got.message)
	}
}

// The checks of the former C client: one cipher suite, an explicit anchor and
// clock, and a close_notify after the response.
verify_openssl :: proc(t: ^testing.T, port: int, mode: Verification) {
	conn, result := peer.dial(
		port,
		{
			tls = true,
			server_name = "synthetic.invalid",
			verify_name = "wrong.invalid" if mode == .Hostname else "synthetic.invalid",
			ca_file = harness.fixture("tls/rsa4096-valid.pem") if mode == .Trust else cert(),
			verify_time = verify_time(mode),
			alpn = {"http/1.1"},
			ciphersuites = "TLS_AES_128_GCM_SHA256",
			timeout = 5 * time.Second,
		},
	)
	if mode != .Trusted {
		testing.expectf(t, !result.ok, "OpenSSL %v: the handshake succeeded", mode)
		testing.expectf(t, int(result.verify_result) == expected_verify(mode), "OpenSSL %v: verify result %d", mode, result.verify_result)
		peer.abort(conn)
		return
	}
	if !testing.expectf(t, result.ok && result.verify_result == 0, "OpenSSL: %s (verify %d)", result.message, result.verify_result) {
		return
	}
	defer peer.close(conn)
	testing.expect_value(t, peer.alpn(conn), "http/1.1")
	testing.expect(t, peer.write_string(conn, "GET /close HTTP/1.1\r\nHost: synthetic.invalid\r\nConnection: close\r\n\r\n"))
	wire := make([dynamic]u8, context.temp_allocator)
	for {
		buffer: [4096]u8
		n, status := peer.read(conn, buffer[:])
		if status != .Ok {
			testing.expectf(t, status == .Closed, "the response ended without close_notify: %v", status)
			break
		}
		append(&wire, ..buffer[:n])
		if !testing.expect(t, len(wire) < 16384, "bounded response") {
			break
		}
	}
	text := string(wire[:])
	testing.expectf(t, strings.has_prefix(text, "HTTP/1.1 200 "), "%q", text)
	end := strings.index(text, "\r\n\r\n")
	testing.expectf(t, end >= 0 && text[end + 4:] == OK_BODY, "%q", text)
}

// The trusted exchange with every TCP write and read seven bytes long.
@(test)
fragmented_records :: proc(t: ^testing.T) {
	s, launched := launch(t, "core")
	if !launched {
		return
	}
	defer close(t, &s)
	conn, connected := dial(t, s.port, fragment = 7)
	if !connected {
		return
	}
	four_requests(t, conn)
	peer.close(conn)
	_, _ = idle(t, &s)
}

// A chunked request body, a chunked response, and a closing request.
@(test)
chunked_helpers :: proc(t: ^testing.T) {
	s, launched := launch(t, "core")
	if !launched {
		return
	}
	defer close(t, &s)
	conn, connected := dial(t, s.port)
	if !connected {
		return
	}
	defer peer.close(conn)
	testing.expect(
		t,
		peer.write_string(conn, "POST /echo HTTP/1.1\r\nHost: synthetic.invalid\r\nTransfer-Encoding: chunked\r\n\r\n4\r\npart\r\n4\r\ndone\r\n0\r\n\r\n"),
	)
	expect_response(t, conn, "POST", "partdone")
	testing.expect(t, peer.request(conn, "GET", "/stream"))
	expect_response(t, conn, "GET", "onetwo")
	testing.expect(t, peer.request(conn, "GET", "/close", close = true))
	expect_response(t, conn, "GET", OK_BODY)
	_, _ = idle(t, &s)
}

// The start of a ClientHello and nothing more: the 400 ms handshake timeout
// closes the connection.
@(test)
handshake_timeout :: proc(t: ^testing.T) {
	s, launched := launch(t, "core")
	if !launched {
		return
	}
	defer close(t, &s)
	conn, connected := dial(t, s.port, plain = true)
	if !connected {
		return
	}
	defer peer.abort(conn)
	testing.expect(t, peer.write_raw(conn, {22, 3, 1, 0, 64, 1}))
	started := time.tick_now()
	one: [1024]u8
	_, status := peer.read(conn, one[:])
	elapsed := time.tick_since(started)
	testing.expectf(t, status != .Ok && status != .Timeout, "the stalled handshake produced %v", status)
	testing.expectf(t, elapsed > 150 * time.Millisecond && elapsed < 3 * time.Second, "handshake timeout after %v", elapsed)
	_, _ = idle(t, &s)
}

// An 8 MiB response to a reader that does not read, on the only worker: a new
// handshake and request still finish within a second, and the server saw its
// writes wait and go out in parts.
@(test)
backpressure :: proc(t: ^testing.T) {
	s, launched := launch(t, "core")
	if !launched {
		return
	}
	defer close(t, &s)
	conn, connected := dial(t, s.port)
	if !connected {
		return
	}
	defer peer.close(conn)
	testing.expect(t, peer.request(conn, "GET", "/large", close = true))
	testing.expect_value(t, peer.peek(conn), peer.Status.Ok)
	time.sleep(150 * time.Millisecond)
	started := time.tick_now()
	cheap, cheap_connected := dial(t, s.port)
	if cheap_connected {
		testing.expect(t, peer.request(cheap, "GET", "/fast", close = true))
		expect_response(t, cheap, "GET", OK_BODY)
		peer.close(cheap)
	}
	elapsed := time.tick_since(started)
	testing.expectf(t, elapsed < time.Second, "the cheap request waited %v behind the large one", elapsed)
	time.sleep(400 * time.Millisecond)
	response, status := peer.read_head(conn)
	if !testing.expectf(t, status == .Ok && response.status == 200, "large response: %v %d", status, response.status) {
		return
	}
	testing.expect_value(t, response.content_length, LARGE_BYTES)
	at := 0
	for at < LARGE_BYTES {
		buffer: [8192]u8
		n, read := peer.read(conn, buffer[:min(len(buffer), LARGE_BYTES - at)])
		if !testing.expectf(t, read == .Ok, "large body after %d bytes: %v", at, read) {
			return
		}
		for v, i in buffer[:n] {
			if v != u8((at + i) % 251) {
				testing.expectf(t, false, "large body byte %d", at + i)
				return
			}
		}
		at += n
	}
	log.infof("8 MiB read; the cheap request took %v", elapsed)
	if m, ok := idle(t, &s); ok {
		testing.expectf(t, m.write_waits > 0, "no write waited: %v", m)
		testing.expectf(t, m.partial_writes > 0, "no write went out in parts: %v", m)
	}
}

active :: proc(m: Metrics) -> bool {
	return m.active > 0
}

// A ClientHello that never finishes when the server stops.
@(test)
shutdown_hold_handshake :: proc(t: ^testing.T) {
	s, launched := launch(t, "core")
	if !launched {
		return
	}
	defer close(t, &s)
	conn, connected := dial(t, s.port, plain = true)
	if !connected {
		return
	}
	defer peer.abort(conn)
	testing.expect(t, peer.write_raw(conn, {22, 3, 1, 0, 64, 1}))
	if _, held := wait_metrics(t, &s, active); !held {
		return
	}
	_, _ = join(t, &s)
	one: [1024]u8
	_, status := peer.read(conn, one[:])
	testing.expectf(t, status != .Ok && status != .Timeout, "the held handshake produced %v", status)
}

// Half a request body when the server stops.
@(test)
shutdown_hold_http :: proc(t: ^testing.T) {
	s, launched := launch(t, "core")
	if !launched {
		return
	}
	defer close(t, &s)
	conn, connected := dial(t, s.port)
	if !connected {
		return
	}
	defer peer.close(conn)
	testing.expect(t, peer.write_string(conn, "POST /echo HTTP/1.1\r\nHost: synthetic.invalid\r\nContent-Length: 8\r\n\r\npart"))
	if _, held := wait_metrics(t, &s, active); !held {
		return
	}
	_, _ = join(t, &s)
	one: [1024]u8
	_, status := peer.read(conn, one[:])
	testing.expectf(t, status != .Ok && status != .Timeout, "the held request did not close: %v", status)
}

// Half a request body when the server drains: the request finishes, then the
// connection closes and the server stops by itself.
@(test)
shutdown_drain_body :: proc(t: ^testing.T) {
	s, launched := launch(t, "core")
	if !launched {
		return
	}
	defer close(t, &s)
	conn, connected := dial(t, s.port)
	if !connected {
		return
	}
	defer peer.close(conn)
	testing.expect(t, peer.write_string(conn, "POST /echo HTTP/1.1\r\nHost: synthetic.invalid\r\nContent-Length: 8\r\n\r\npart"))
	if _, held := wait_metrics(t, &s, active); !held {
		return
	}
	if _, reading := wait_metrics(t, &s, proc(m: Metrics) -> bool {return m.started > 0}); !reading {
		return
	}
	command(t, &s, "d")
	if _, drained := harness.expect_line(t, s.p, "DRAIN", 15 * time.Second); !drained {
		return
	}
	testing.expect(t, peer.write_string(conn, "done"))
	expect_response(t, conn, "POST", "partdone")
	one: [1024]u8
	_, status := peer.read(conn, one[:])
	testing.expectf(t, status != .Ok && status != .Timeout, "the drained connection did not close: %v", status)
	_, _ = join(t, &s, stop = false)
}

// A deferred response released from another thread while its connection
// waits; the connection then takes a fresh keep-alive budget. With pipeline,
// the start of the next request is already buffered when the response is
// released.
shutdown_deferred :: proc(t: ^testing.T, pipeline: bool) {
	s, launched := launch(t, "core")
	if !launched {
		return
	}
	defer close(t, &s)
	conn, connected := dial(t, s.port)
	if !connected {
		return
	}
	defer peer.close(conn)
	testing.expect(t, peer.request(conn, "GET", "/deferred"))
	if pipeline {
		testing.expect(t, peer.write_string(conn, "GET /nex"))
	}
	if _, held := wait_metrics(t, &s, active); !held {
		return
	}
	if _, deferred := harness.expect_line(t, s.p, "DEFERRED", 15 * time.Second); !deferred {
		return
	}
	// Let the continuation take its suspended read turn before Ready is
	// signalled from the command thread.
	time.sleep(50 * time.Millisecond)
	command(t, &s, "r")
	if _, released := harness.expect_line(t, s.p, "RELEASED", 15 * time.Second); !released {
		return
	}
	expect_response(t, conn, "GET", "deferred-ready")
	time.sleep(550 * time.Millisecond)
	if pipeline {
		testing.expect(t, peer.write_string(conn, "t HTTP/1.1\r\nHost: synthetic.invalid\r\nConnection: close\r\n\r\n"))
	} else {
		testing.expect(t, peer.request(conn, "GET", "/close", close = true))
	}
	expect_response(t, conn, "GET", OK_BODY)
	_, _ = idle(t, &s)
}

@(test)
shutdown_deferred_response :: proc(t: ^testing.T) {
	shutdown_deferred(t, false)
}

@(test)
shutdown_deferred_pipeline :: proc(t: ^testing.T) {
	shutdown_deferred(t, true)
}

// A masked client frame with a short payload.
ws_frame :: proc(opcode: u8, payload: string) -> []u8 {
	mask := [4]u8{1, 2, 3, 4}
	wire := make([dynamic]u8, context.temp_allocator)
	append(&wire, 0x80 | opcode, 0x80 | u8(len(payload)))
	append(&wire, ..mask[:])
	for i in 0 ..< len(payload) {
		append(&wire, payload[i] ~ mask[i % 4])
	}
	return wire[:]
}

// A final, unmasked server frame of at most 125 bytes.
ws_read :: proc(t: ^testing.T, conn: ^peer.Conn, loc := #caller_location) -> (opcode: u8, payload: string, ok: bool) {
	head, status := peer.read_exact(conn, 2)
	if !testing.expectf(t, status == .Ok, "WebSocket frame header: %v", status, loc = loc) {
		return
	}
	if !testing.expectf(t, head[0] & 0x80 != 0 && head[1] & 0x80 == 0 && head[1] < 126, "frame header %x", head, loc = loc) {
		return
	}
	body: []u8
	body, status = peer.read_exact(conn, int(head[1]))
	if !testing.expectf(t, status == .Ok, "WebSocket payload: %v", status, loc = loc) {
		return
	}
	return head[0] & 15, string(body), true
}

// The development server's reload socket over TLS: a ping coalesced with the
// upgrade request and one sent a byte per record are answered, and the socket
// is closed by the server, after a reload (or with a frame half sent, when the
// server stops).
shutdown_wss :: proc(t: ^testing.T, stop: bool) {
	web := harness.workdir(t, "https-web")
	defer os.remove_all(web)
	view := fmt.tprintf("%s/view.jsx", web)
	testing.expect(t, os.write_entire_file(view, transmute([]u8)string("export default function View(){return <p>first</p>}")) == nil)
	s, launched := launch(t, "development", web)
	if !launched {
		return
	}
	defer close(t, &s)
	conn, connected := dial(t, s.port)
	if !connected {
		return
	}
	defer peer.close(conn)
	upgrade := "GET /__reload HTTP/1.1\r\nHost: synthetic.invalid\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
	coalesced := strings.concatenate({upgrade, string(ws_frame(9, "coalesced"))}, context.temp_allocator)
	testing.expect(t, peer.write_string(conn, coalesced))
	response, status := peer.read_head(conn)
	if !testing.expectf(t, status == .Ok && response.status == 101, "upgrade: %v %d", status, response.status) {
		return
	}
	accept, _ := peer.header(response, "Sec-WebSocket-Accept")
	testing.expect_value(t, accept, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
	opcode, payload, ok := ws_read(t, conn)
	testing.expectf(t, ok && opcode == 10 && payload == "coalesced", "coalesced ping answered %d %q", opcode, payload)
	for b in ws_frame(9, "fragmented") {
		one := [1]u8{b}
		testing.expect(t, peer.write(conn, one[:]))
	}
	opcode, payload, ok = ws_read(t, conn)
	testing.expectf(t, ok && opcode == 10 && payload == "fragmented", "fragmented ping answered %d %q", opcode, payload)
	if stop {
		testing.expect(t, peer.write(conn, {0x89, 0x83, 1}))
	}
	if _, held := wait_metrics(t, &s, active); !held {
		return
	}
	if !stop {
		testing.expect(t, os.write_entire_file(view, transmute([]u8)string("export default function View(){return <p>changed</p>}")) == nil)
		opcode, payload, ok = ws_read(t, conn)
		testing.expectf(t, ok && opcode == 1 && payload == "reload", "watcher sent %d %q", opcode, payload)
		opcode, payload, ok = ws_read(t, conn)
		testing.expectf(
			t,
			ok && opcode == 8 && len(payload) >= 2 && payload[0] == 3 && payload[1] == 232,
			"reload close %d %x",
			opcode,
			payload,
		)
	} else {
		_, _ = join(t, &s)
	}
	one: [1]u8
	_, ended := peer.read(conn, one[:])
	testing.expectf(t, ended != .Ok && ended != .Timeout, "the WebSocket was not closed: %v", ended)
	if !stop {
		_, _ = idle(t, &s)
	}
}

@(test)
shutdown_wss_reload :: proc(t: ^testing.T) {
	shutdown_wss(t, false)
}

@(test)
shutdown_wss_stop :: proc(t: ^testing.T) {
	shutdown_wss(t, true)
}
