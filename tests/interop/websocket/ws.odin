package saba_interop_websocket_test

import "core:bytes"
import "core:fmt"
import "core:testing"
import "core:time"
import peer "../../support/peer"

// RFC 6455 frames written and checked by hand, so the peer decides every byte
// Saba reads and sees every byte Saba writes.

TEXT :: 1
BINARY :: 2
CLOSE :: 8
PING :: 9
PONG :: 10
CONTINUATION :: 0

ACCEPT :: "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
MESSAGE_BOUND :: 8 * 1024 * 1024

Frame :: struct {
	final:   bool,
	opcode:  u8,
	payload: []u8,
}

// One client session. A failed step records its reason on t.
WS :: struct {
	t:     ^testing.T,
	conn:  ^peer.Conn,
	// The largest server frame this peer accepts.
	limit: int,
}

Session :: struct {
	t:      ^testing.T,
	port:   int,
	secure: bool,
	// Read the upgrade response a byte at a time, so no frame after it leaves
	// the socket.
	single: bool,
}

encode :: proc(opcode: u8, final, masked: bool, payload: []u8) -> []u8 {
	wire := make([dynamic]u8, context.temp_allocator)
	append(&wire, opcode | (0x80 if final else 0))
	mask: u8 = 0x80 if masked else 0
	n := len(payload)
	switch {
	case n < 126:
		append(&wire, mask | u8(n))
	case n <= 65535:
		append(&wire, mask | 126, u8(n >> 8), u8(n))
	case:
		append(&wire, mask | 127)
		for shift := 56; shift >= 0; shift -= 8 {
			append(&wire, u8(u64(n) >> uint(shift)))
		}
	}
	key := [4]u8{1, 2, 3, 4}
	if masked {
		append(&wire, ..key[:])
	}
	for b, i in payload {
		append(&wire, b ~ key[i % 4] if masked else b)
	}
	return wire[:]
}

text :: proc(s: string) -> []u8 {
	return transmute([]u8)s
}

repeat :: proc(b: u8, n: int) -> []u8 {
	out := make([]u8, n, context.temp_allocator)
	for &v in out {
		v = b
	}
	return out
}

fail :: proc(w: ^WS, format: string, args: ..any, loc := #caller_location) -> bool {
	testing.expectf(w.t, false, format, ..args, loc = loc)
	return false
}

write :: proc(w: ^WS, opcode: u8, final: bool, payload: []u8, loc := #caller_location) -> bool {
	if !peer.write(w.conn, encode(opcode, final, true, payload)) {
		return fail(w, "could not write a frame", loc = loc)
	}
	return true
}

read :: proc(w: ^WS, loc := #caller_location) -> (f: Frame, ok: bool) {
	head, status := peer.read_exact(w.conn, 2)
	if status != .Ok {
		return {}, fail(w, "frame header: %v", status, loc = loc)
	}
	if head[0] & 0x70 != 0 || head[1] & 0x80 != 0 {
		return {}, fail(w, "server frame with RSV bits or a mask: %x", head, loc = loc)
	}
	length := u64(head[1] & 127)
	if length == 126 {
		b, extended := peer.read_exact(w.conn, 2)
		if extended != .Ok {
			return {}, fail(w, "16-bit length", loc = loc)
		}
		length = u64(b[0]) << 8 | u64(b[1])
		if length < 126 {
			return {}, fail(w, "non-minimal server length %d", length, loc = loc)
		}
	} else if length == 127 {
		b, extended := peer.read_exact(w.conn, 8)
		if extended != .Ok {
			return {}, fail(w, "64-bit length", loc = loc)
		}
		length = 0
		for v in b {
			length = length << 8 | u64(v)
		}
		if length <= 65535 {
			return {}, fail(w, "non-minimal server length %d", length, loc = loc)
		}
	}
	if length > u64(w.limit) {
		return {}, fail(w, "server frame exceeds the limit: %d > %d", length, w.limit, loc = loc)
	}
	payload: []u8
	payload, status = peer.read_exact(w.conn, int(length))
	if status != .Ok {
		return {}, fail(w, "frame payload: %v", status, loc = loc)
	}
	return {head[0] & 0x80 != 0, head[0] & 15, payload}, true
}

// Reads one message, fragments included, and compares it. A keepalive ping
// the server puts before or between the fragments is answered, as a peer
// answers it: a long message read slowly outlasts the ping interval.
message :: proc(w: ^WS, opcode: u8, expected: []u8, loc := #caller_location) -> bool {
	body := make([dynamic]u8, context.temp_allocator)
	first := true
	for {
		f := read(w, loc) or_return
		if f.opcode == PING {
			if !f.final || len(f.payload) > 125 {
				return fail(w, "ping: final %v, %d bytes", f.final, len(f.payload), loc = loc)
			}
			write(w, PONG, true, f.payload, loc) or_return
			continue
		}
		defer first = false
		if first && f.opcode != opcode {
			return fail(w, "message opcode %d, want %d", f.opcode, opcode, loc = loc)
		}
		if !first && f.opcode != CONTINUATION {
			return fail(w, "continuation opcode %d", f.opcode, loc = loc)
		}
		if len(body) + len(f.payload) > MESSAGE_BOUND {
			return fail(w, "message past %d bytes", MESSAGE_BOUND, loc = loc)
		}
		append(&body, ..f.payload)
		if f.final {
			break
		}
	}
	if !bytes.equal(body[:], expected) {
		return fail(w, "message of %d bytes, want %d", len(body), len(expected), loc = loc)
	}
	return true
}

pong :: proc(w: ^WS, expected: []u8, loc := #caller_location) -> bool {
	f := read(w, loc) or_return
	if !f.final || f.opcode != PONG || !bytes.equal(f.payload, expected) {
		return fail(w, "pong: opcode %d payload %q", f.opcode, string(f.payload), loc = loc)
	}
	return true
}

// Closes with code and "bye", reads the echo, and expects the transport to end
// in order.
goodbye :: proc(w: ^WS, code: u16, loc := #caller_location) -> bool {
	payload := make([dynamic]u8, context.temp_allocator)
	append(&payload, u8(code >> 8), u8(code))
	append(&payload, ..text("bye"))
	write(w, CLOSE, true, payload[:], loc) or_return
	f := read(w, loc) or_return
	if !f.final || f.opcode != CLOSE || !bytes.equal(f.payload, payload[:]) {
		return fail(w, "close echo: opcode %d payload %x", f.opcode, f.payload, loc = loc)
	}
	return ordered_end(w, loc)
}

// The next read finds the connection closed in order.
ordered_end :: proc(w: ^WS, loc := #caller_location) -> bool {
	one: [1]u8
	n, status := peer.read(w.conn, one[:])
	if n != 0 || status != .Closed {
		return fail(w, "transport did not close in order: %d bytes, %v", n, status, loc = loc)
	}
	return true
}

code_of :: proc(f: Frame) -> int {
	return int(f.payload[0]) << 8 | int(f.payload[1]) if len(f.payload) >= 2 else -1
}

dial :: proc(s: Session, loc := #caller_location) -> (^peer.Conn, bool) {
	conn, result := peer.dial(
		s.port,
		{
			tls = s.secure,
			server_name = "synthetic.invalid",
			ca_file = "tests/fixtures/tls/rsa2048-valid.pem",
			alpn = {"http/1.1"},
			timeout = 30 * time.Second,
		},
	)
	if !testing.expectf(s.t, result.ok, "dial: %s (verify %d)", result.message, result.verify_result, loc = loc) {
		return nil, false
	}
	if s.secure && !testing.expectf(s.t, peer.alpn(conn) == "http/1.1", "WSS ALPN %q", peer.alpn(conn), loc = loc) {
		peer.close(conn)
		return nil, false
	}
	return conn, true
}

// Sends an upgrade request (with extra bytes right after it) and reads the
// response head.
upgrade :: proc(
	s: Session,
	path, origin, protocols, auth: string,
	extra: []u8 = nil,
	loc := #caller_location,
) -> (
	w: WS,
	response: peer.Response,
	ok: bool,
) {
	conn := dial(s, loc) or_return
	w = {t = s.t, conn = conn, limit = 65536 if len(path) >= 5 && path[:5] == "/slow" else 1024}
	request := make([dynamic]u8, context.temp_allocator)
	append(
		&request,
		..text(
			fmt.tprintf(
				"GET %s HTTP/1.1\r\nHost: synthetic.invalid\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n",
				path,
			),
		),
	)
	if origin != "" {
		append(&request, ..text(fmt.tprintf("Origin: %s\r\n", origin)))
	}
	if protocols != "" {
		append(&request, ..text(fmt.tprintf("Sec-WebSocket-Protocol: %s\r\n", protocols)))
	}
	if auth != "" {
		append(&request, ..text(fmt.tprintf("X-Test-Auth: %s\r\n", auth)))
	}
	append(&request, '\r', '\n')
	append(&request, ..extra)
	if !peer.write(conn, request[:]) {
		peer.abort(conn)
		return w, response, fail(&w, "upgrade request", loc = loc)
	}
	if s.single {
		conn.chunk = 1
	}
	status: peer.Status
	response, status = peer.read_head(conn)
	conn.chunk = peer.DEFAULT_CHUNK
	if status != .Ok {
		peer.abort(conn)
		return w, response, fail(&w, "upgrade response: %v", status, loc = loc)
	}
	return w, response, true
}

// An upgrade that passes every policy check, with chat.v2 selected.
normal :: proc(s: Session, path: string, extra: []u8 = nil, loc := #caller_location) -> (w: WS, ok: bool) {
	response: peer.Response
	w, response = upgrade(s, path, "https://allowed.invalid", "chat.v1, chat.v2", "allow", extra, loc) or_return
	accept, _ := peer.header(response, "Sec-WebSocket-Accept")
	selected, _ := peer.header(response, "Sec-WebSocket-Protocol")
	ok = testing.expectf(s.t, response.status == 101, "upgrade status %d", response.status, loc = loc)
	ok &&= testing.expectf(s.t, accept == ACCEPT, "Sec-WebSocket-Accept %q", accept, loc = loc)
	ok &&= testing.expectf(s.t, selected == "chat.v2", "selected subprotocol %q", selected, loc = loc)
	if !ok {
		peer.abort(w.conn)
	}
	return
}
