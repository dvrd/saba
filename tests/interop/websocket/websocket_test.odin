// Saba's application WebSockets (RFC 6455) over TCP and TLS against a peer
// that shares none of its code: frames written and checked here, TLS from
// OpenSSL, and libcurl's WebSocket client for the ordinary exchange. Origin,
// authorization and subprotocol policy; every invalid frame closed with its
// exact code; output queue limits; closes started by either side, answered or
// not; and slow or stalled readers that must cost no thread and no unbounded
// memory, with everything retired when the server stops.
package saba_interop_websocket_test

import "core:bytes"
import "core:c"
import "core:fmt"
import "core:log"
import "core:sync"
import "core:testing"
import "core:time"
import curl "../../support/c/curl"
import fetch "../../support/fetch"
import harness "../../support/harness"
import peer "../../support/peer"

// The modes that measure time or threads run one at a time.
quiet: sync.Mutex

Mode :: #type proc(s: Session, server: ^Server) -> bool

// Runs mode over ws and then wss, each against a fresh server, and joins the
// server after it.
run :: proc(t: ^testing.T, mode: Mode, timed := false) {
	if timed {
		sync.lock(&quiet)
	}
	defer if timed {
		sync.unlock(&quiet)
	}
	for transport in ([]string{"ws", "wss"}) {
		server, launched := launch(t, transport)
		if !launched {
			return
		}
		passed := mode({t = t, port = server.port, secure = transport == "wss"}, &server)
		if !passed {
			log.errorf("%s failed", transport)
		}
		close(t, &server)
	}
}

ok_idle :: proc(s: Session, server: ^Server) -> (Metrics, bool) {
	return idle(s.t, server)
}

// Pings coalesced with the upgrade and split into one-byte writes, a ping
// between fragments, UTF-8 split over fragments, the exact message limit,
// empty and binary messages, the largest control frame, and a clean close.
@(test)
echo :: proc(t: ^testing.T) {
	run(t, echo_mode)
}

echo_mode :: proc(s: Session, server: ^Server) -> bool {
	echo_exchange(s) or_return
	m := ok_idle(s, server) or_return
	return testing.expectf(s.t, m.clean == 1 && m.unclean == 0, "%v", m)
}

echo_exchange :: proc(s: Session) -> bool {
	w := normal(s, "/ws", encode(PING, true, true, text("coalesced"))) or_return
	defer peer.close(w.conn)
	pong(&w, text("coalesced")) or_return
	for b in encode(PING, true, true, text("fragmented")) {
		one := [1]u8{b}
		peer.write(w.conn, one[:]) or_return
	}
	pong(&w, text("fragmented")) or_return
	write(&w, TEXT, false, text("hello ")) or_return
	write(&w, PING, true, text("interleave")) or_return
	write(&w, CONTINUATION, false, {0xe2}) or_return
	write(&w, CONTINUATION, false, {0x82}) or_return
	write(&w, CONTINUATION, true, {0xac}) or_return
	pong(&w, text("interleave")) or_return
	message(&w, TEXT, text("hello €")) or_return
	exact := repeat('E', 2048)
	write(&w, BINARY, false, exact[:1024]) or_return
	write(&w, CONTINUATION, true, exact[1024:]) or_return
	message(&w, BINARY, exact) or_return
	write(&w, TEXT, true, nil) or_return
	message(&w, TEXT, nil) or_return
	write(&w, BINARY, true, {0, 255, 128}) or_return
	message(&w, BINARY, {0, 255, 128}) or_return
	control := repeat('P', 125)
	write(&w, PING, true, control) or_return
	pong(&w, control) or_return
	return goodbye(&w, 1000)
}

// Each rejected upgrade has its status and a bounded body; then a valid one.
@(test)
policy :: proc(t: ^testing.T) {
	run(t, policy_mode)
}

policy_mode :: proc(s: Session, server: ^Server) -> bool {
	Case :: struct {
		path, origin, protocols, auth: string,
		status:                        int,
	}
	cases := []Case {
		{"/ws", "https://wrong.invalid", "chat.v2", "allow", 403},
		{"/ws", "", "chat.v2", "allow", 403},
		{"/ws", "https://allowed.invalid", "chat.v2", "deny", 403},
		{"/ws", "https://allowed.invalid", "chat.v2", "", 403},
		{"/ws", "https://allowed.invalid", "bad protocol", "allow", 400},
		{"/ws", "https://allowed.invalid", "chat.v2, chat.v2", "allow", 400},
		{"/ws", "https://allowed.invalid", "other", "allow", 400},
		{"/not-websocket", "https://allowed.invalid", "chat.v2", "allow", 404},
	}
	for c in cases {
		w, response := upgrade(s, c.path, c.origin, c.protocols, c.auth) or_return
		testing.expectf(s.t, response.status == c.status, "%s %q %q %q: status %d, want %d", c.path, c.origin, c.protocols, c.auth, response.status, c.status)
		if response.content_length > 0 {
			testing.expectf(s.t, response.content_length <= 4096, "rejection body of %d bytes", response.content_length)
			_, _ = peer.read_exact(w.conn, min(response.content_length, 4096))
		}
		peer.close(w.conn)
	}
	w := normal(s, "/ws") or_return
	defer peer.close(w.conn)
	goodbye(&w, 1000) or_return
	_ = ok_idle(s, server) or_return
	return true
}

// Each protocol violation is answered with a close frame carrying its code,
// and no session closes clean.
@(test)
invalid_frames :: proc(t: ^testing.T) {
	run(t, invalid_mode)
}

invalid_mode :: proc(s: Session, server: ^Server) -> bool {
	Case :: struct {
		name: string,
		wire: []u8,
		code: int,
	}
	cases := []Case {
		{"unmasked", encode(TEXT, true, false, text("x")), 1002},
		{"rsv", {0xc1, 0x80, 1, 2, 3, 4}, 1002},
		{"opcode", {0x83, 0x80, 1, 2, 3, 4}, 1002},
		{"control-fragment", encode(PING, false, true, text("x")), 1002},
		{"control-size", encode(PING, true, true, repeat(0, 126)), 1002},
		{"nonminimal-length", {0x81, 0xfe, 0, 1, 1, 2, 3, 4, 'x' ~ 1}, 1002},
		{"bad-utf8", encode(TEXT, true, true, {0xff}), 1007},
		{"unexpected-continuation", encode(CONTINUATION, true, true, text("x")), 1002},
		{"close-one-byte", encode(CLOSE, true, true, {1}), 1002},
		{"close-bad-utf8", encode(CLOSE, true, true, {3, 232, 0xff}), 1007},
		{"frame-oversize", encode(BINARY, true, true, repeat(0, 1025)), 1009},
	}
	for c in cases {
		w := normal(s, "/ws") or_return
		peer.write(w.conn, c.wire) or_return
		f, read_ok := read(&w)
		testing.expectf(s.t, read_ok && f.opcode == CLOSE && code_of(f) == c.code, "%s: opcode %d payload %x, want close %d", c.name, f.opcode, f.payload, c.code)
		peer.close(w.conn)
	}
	// The message limit (2048) over fragments.
	{
		w := normal(s, "/ws") or_return
		write(&w, BINARY, false, repeat(0, 1024)) or_return
		write(&w, CONTINUATION, false, repeat(0, 1024)) or_return
		write(&w, CONTINUATION, true, {1}) or_return
		f, read_ok := read(&w)
		testing.expectf(s.t, read_ok && f.opcode == CLOSE && code_of(f) == 1009, "fragmented message bound: %x", f.payload)
		peer.close(w.conn)
	}
	// The fragment count limit (4).
	{
		w := normal(s, "/ws") or_return
		write(&w, BINARY, false, {1}) or_return
		for _ in 0 ..< 3 {
			write(&w, CONTINUATION, false, {1}) or_return
		}
		write(&w, CONTINUATION, true, {1}) or_return
		f, read_ok := read(&w)
		testing.expectf(s.t, read_ok && f.opcode == CLOSE && code_of(f) == 1009, "fragment count limit: %x", f.payload)
		peer.close(w.conn)
	}
	m := ok_idle(s, server) or_return
	return testing.expectf(s.t, m.clean == 0, "%v", m)
}

// The output queue's message count (2) and byte bound, a ping answered past a
// full queue, and an output larger than the bound refused without closing.
@(test)
output_queue :: proc(t: ^testing.T) {
	run(t, queue_mode)
}

queue_mode :: proc(s: Session, server: ^Server) -> bool {
	{
		w := normal(s, "/ws") or_return
		defer peer.close(w.conn)
		write(&w, TEXT, true, text("queue-count")) or_return
		message(&w, TEXT, text("count-1")) or_return
		message(&w, TEXT, text("count-2")) or_return
		write(&w, PING, true, text("after-count")) or_return
		pong(&w, text("after-count")) or_return
		goodbye(&w, 1000) or_return
	}
	{
		w := normal(s, "/queue-bytes") or_return
		defer peer.close(w.conn)
		write(&w, TEXT, true, text("queue-bytes")) or_return
		message(&w, BINARY, repeat('A', 1024)) or_return
		message(&w, BINARY, repeat('C', 512)) or_return
		write(&w, PING, true, text("after-bytes")) or_return
		pong(&w, text("after-bytes")) or_return
		goodbye(&w, 1000) or_return
	}
	{
		w := normal(s, "/ws") or_return
		defer peer.close(w.conn)
		write(&w, TEXT, true, text("oversized-output")) or_return
		message(&w, TEXT, text("output-rejected")) or_return
		goodbye(&w, 1000) or_return
	}
	m := ok_idle(s, server) or_return
	ok := testing.expectf(s.t, m.queue_count == 1 && m.queue_bytes == 1 && m.out_limit == 1, "%v", m)
	ok &&= testing.expectf(s.t, m.writable_callbacks == 2, "%v", m)
	return ok
}

// The application closes after two messages: they arrive first, then its
// close, which the peer answers.
@(test)
application_close :: proc(t: ^testing.T) {
	run(t, application_close_mode)
}

application_close_mode :: proc(s: Session, server: ^Server) -> bool {
	{
		w := normal(s, "/ws") or_return
		defer peer.close(w.conn)
		write(&w, TEXT, true, text("application-close")) or_return
		message(&w, TEXT, text("before-close-1")) or_return
		message(&w, TEXT, text("before-close-2")) or_return
		f := read(&w) or_return
		want := []u8{3, 232, 'a', 'p', 'p', '-', 'd', 'o', 'n', 'e'}
		if !testing.expectf(s.t, f.opcode == CLOSE && bytes.equal(f.payload, want), "application close: opcode %d %q", f.opcode, string(f.payload)) {
			return false
		}
		write(&w, CLOSE, true, f.payload) or_return
		ordered_end(&w) or_return
	}
	m := ok_idle(s, server) or_return
	return testing.expectf(s.t, m.clean == 1 && m.unclean == 0, "%v", m)
}

// A close without a status code is echoed empty and the session is clean.
@(test)
empty_close :: proc(t: ^testing.T) {
	run(t, empty_close_mode)
}

empty_close_mode :: proc(s: Session, server: ^Server) -> bool {
	{
		w := normal(s, "/ws") or_return
		defer peer.close(w.conn)
		write(&w, CLOSE, true, nil) or_return
		f := read(&w) or_return
		if !testing.expectf(s.t, f.final && f.opcode == CLOSE && len(f.payload) == 0, "empty close echo: opcode %d %x", f.opcode, f.payload) {
			return false
		}
		ordered_end(&w) or_return
	}
	m := ok_idle(s, server) or_return
	return testing.expectf(s.t, m.clean == 1 && m.unclean == 0, "%v", m)
}

// The application closes and the peer never answers: the 200 ms close timeout
// ends the connection, unclean.
@(test)
application_noack :: proc(t: ^testing.T) {
	run(t, noack_mode, timed = true)
}

noack_mode :: proc(s: Session, server: ^Server) -> bool {
	{
		w := normal(s, "/ws") or_return
		defer peer.close(w.conn)
		started := time.tick_now()
		write(&w, TEXT, true, text("application-noack")) or_return
		f := read(&w) or_return
		want := []u8{3, 232, 'n', 'o', '-', 'a', 'c', 'k'}
		if !testing.expectf(s.t, f.opcode == CLOSE && bytes.equal(f.payload, want), "no-ack close: opcode %d %q", f.opcode, string(f.payload)) {
			return false
		}
		one: [1]u8
		n, status := peer.read(w.conn, one[:])
		elapsed := time.tick_since(started)
		testing.expectf(s.t, n == 0 && status != .Ok && status != .Timeout, "the unanswered close did not end the connection: %v", status)
		testing.expectf(s.t, elapsed >= 100 * time.Millisecond && elapsed < 2 * time.Second, "close cutoff after %v", elapsed)
	}
	m := ok_idle(s, server) or_return
	return testing.expectf(s.t, m.clean == 0 && m.unclean == 1 && m.close_timeouts == 1, "%v", m)
}

// The peer closes while an 8 MiB message is being sent: the rest of that
// message and the text queued behind it are discarded, and the close is
// echoed.
@(test)
peer_close_discard :: proc(t: ^testing.T) {
	run(t, peer_close_mode)
}

peer_close_mode :: proc(s: Session, server: ^Server) -> bool {
	{
		w := normal(s, "/slow") or_return
		defer peer.close(w.conn)
		write(&w, TEXT, true, text("peer-close-discard")) or_return
		f := read(&w) or_return
		if !testing.expectf(s.t, f.opcode == BINARY && !f.final, "first large frame: opcode %d final %v", f.opcode, f.final) {
			return false
		}
		total := 0
		for b, i in f.payload {
			if b != u8(i % 251) {
				return testing.expectf(s.t, false, "large byte %d", i)
			}
		}
		total += len(f.payload)
		bye := []u8{3, 232, 'b', 'y', 'e'}
		write(&w, CLOSE, true, bye) or_return
		closed := false
		for _ in 0 ..< 130 {
			f = read(&w) or_return
			if f.opcode == CLOSE {
				closed = testing.expectf(s.t, bytes.equal(f.payload, bye), "close echo %x", f.payload)
				break
			}
			if !testing.expectf(s.t, f.opcode == CONTINUATION && !f.final, "after the close: opcode %d final %v", f.opcode, f.final) {
				return false
			}
			for b, i in f.payload {
				if b != u8((total + i) % 251) {
					return testing.expectf(s.t, false, "large byte %d", total + i)
				}
			}
			total += len(f.payload)
		}
		if !testing.expectf(s.t, closed && total < MESSAGE_BOUND, "the unsent tail was delivered: %d bytes, closed %v", total, closed) {
			return false
		}
		log.infof("peer close after %d bytes of the large message", total)
	}
	m := ok_idle(s, server) or_return
	return testing.expectf(s.t, m.clean == 1 && m.unclean == 0, "%v", m)
}

// A frame (or a fragment) half sent while an 8 MiB message waits on a reader
// that does not read: the frame and message timeouts (1 s) retire the session
// although the socket is not writable, and the reader then gets less than the
// message.
@(test)
combined_frame :: proc(t: ^testing.T) {
	run(t, proc(s: Session, server: ^Server) -> bool {return combined_mode(s, server, false)}, timed = true)
}

@(test)
combined_fragment :: proc(t: ^testing.T) {
	run(t, proc(s: Session, server: ^Server) -> bool {return combined_mode(s, server, true)}, timed = true)
}

combined_mode :: proc(s: Session, server: ^Server, fragment: bool) -> bool {
	prefix := encode(TEXT, false, true, text("x")) if fragment else []u8{0x81}
	single := s
	single.single = true
	w := normal(single, "/combined-fragment" if fragment else "/combined-frame", prefix) or_return
	defer peer.close(w.conn)
	started := time.tick_now()
	_ = harness.expect_line(s.t, server.p, "COMBINED") or_return
	metrics, pending := wait_metrics(
		s.t,
		server,
		proc(m: Metrics) -> bool {return m.active == 1 && m.scope_bytes >= 8 * 1024 * 1024},
		500 * time.Millisecond,
	)
	if !pending {
		return false
	}
	deadline := time.tick_add(time.tick_now(), 500 * time.Millisecond)
	for {
		command(s.t, server, "b") or_return
		line := harness.expect_line(s.t, server.p, "PRESSURE ") or_return
		if line == "PRESSURE true false" {
			break
		}
		if time.tick_since(deadline) >= 0 {
			return testing.expectf(s.t, false, "no kernel write pressure observed: %s", line)
		}
		time.sleep(5 * time.Millisecond)
	}
	retired := wait_metrics(s.t, server, proc(m: Metrics) -> bool {return m.active == 0}, 2500 * time.Millisecond) or_return
	elapsed := time.tick_since(started)
	ok := testing.expectf(s.t, elapsed >= 500 * time.Millisecond && elapsed < 2500 * time.Millisecond, "retired after %v", elapsed)
	ok &&= testing.expectf(s.t, retired.combined_timeouts == 1 && retired.unclean == 1 && retired.clean == 0, "%v", retired)
	ok &&= testing.expectf(s.t, retired.scope_bytes == 0, "%v", retired)
	if s.secure {
		ok &&= testing.expectf(s.t, retired.write_waits > 0 && retired.partial_writes > 0, "%v", retired)
	}
	log.infof("pending %v, retired after %v", metrics.scope_bytes, elapsed)
	// Only now the peer reads: what reached it is less than the message.
	count, _ := peer.read_to_end(w.conn, 9 * 1024 * 1024)
	ok &&= testing.expectf(s.t, count < MESSAGE_BOUND, "the held reader received the whole message: %d bytes", count)
	return ok
}

// While an 8 MiB message waits on a slow reader on the only worker, 24 more
// sessions open and a plain request is answered: no thread is added and the
// budget stays bounded. The reader then gets the whole message.
@(test)
slow_reader :: proc(t: ^testing.T) {
	run(t, slow_mode, timed = true)
}

// Opens and finishes one echo session, so lazy runtime state is warm before
// threads are counted.
warm :: proc(s: Session, server: ^Server) -> (count: int, ok: bool) {
	echo_exchange(s) or_return
	_ = ok_idle(s, server) or_return
	counted: bool
	count, counted = harness.threads(server.p)
	return count, testing.expectf(s.t, counted, "could not count the server's threads")
}

slow_mode :: proc(s: Session, server: ^Server) -> bool {
	baseline := warm(s, server) or_return
	large := normal(s, "/slow") or_return
	defer peer.close(large.conn)
	write(&large, TEXT, true, text("slow")) or_return
	if !testing.expect(s.t, peer.peek(large.conn) == .Ok, "the large output did not start") {
		return false
	}
	started := time.tick_now()
	parked := make([dynamic]WS, context.temp_allocator)
	defer for w in parked {
		peer.close(w.conn)
	}
	for _ in 0 ..< 24 {
		w := normal(s, "/ws") or_return
		append(&parked, w)
	}
	cheap := dial(s) or_return
	peer.write_string(cheap, "GET /fast HTTP/1.1\r\nHost: synthetic.invalid\r\nConnection: close\r\n\r\n") or_return
	response, status := peer.read_response(cheap, "GET", 128)
	peer.close(cheap)
	testing.expectf(s.t, status == .Ok && response.status == 200 && string(response.body[:]) == "websocket79-ok\n", "cheap request: %v %d %q", status, response.status, string(response.body[:]))
	elapsed := time.tick_since(started)
	testing.expectf(s.t, elapsed < 8 * time.Second, "the one worker made no progress for %v", elapsed)
	held := wait_metrics(s.t, server, proc(m: Metrics) -> bool {return m.active >= 25}) or_return
	testing.expectf(s.t, held.scope_bytes <= 64 * 1024 * 1024, "%v", held)
	if count, counted := harness.threads(server.p); counted {
		testing.expectf(s.t, count == baseline, "%d threads while held, %d before", count, baseline)
	}
	expected := make([]u8, MESSAGE_BOUND, context.temp_allocator)
	for &v, i in expected {
		v = u8(i % 251)
	}
	message(&large, BINARY, expected) or_return
	goodbye(&large, 1000) or_return
	for w in parked {
		peer.close(w.conn)
	}
	clear(&parked)
	log.infof("24 sessions and a request beside the slow reader in %v", elapsed)
	m := ok_idle(s, server) or_return
	if s.secure {
		return testing.expectf(s.t, m.write_waits > 0 && m.partial_writes > 0, "%v", m)
	}
	return true
}

// 24 parked sessions, one with a frame half sent, when the server stops:
// every one is closed, and no thread was added for them.
@(test)
hold :: proc(t: ^testing.T) {
	run(t, hold_mode, timed = true)
}

hold_mode :: proc(s: Session, server: ^Server) -> bool {
	baseline := warm(s, server) or_return
	parked := make([dynamic]WS, context.temp_allocator)
	defer for w in parked {
		peer.close(w.conn)
	}
	for _ in 0 ..< 24 {
		w := normal(s, "/ws") or_return
		append(&parked, w)
	}
	peer.write(parked[0].conn, {0x81, 0x84, 1}) or_return
	held := wait_metrics(s.t, server, proc(m: Metrics) -> bool {return m.active >= 24}) or_return
	testing.expectf(s.t, held.scope_bytes <= 64 * 1024 * 1024, "%v", held)
	if count, counted := harness.threads(server.p); counted {
		testing.expectf(s.t, count == baseline, "%d threads while held, %d before", count, baseline)
	}
	_ = join(s.t, server) or_return
	for w, i in parked {
		buffer: [256]u8
		_, status := peer.read(w.conn, buffer[:])
		if status == .Ok {
			_, status = peer.read(w.conn, buffer[:])
		}
		testing.expectf(s.t, status != .Ok && status != .Timeout, "the stop did not close parked session %d: %v", i, status)
	}
	return true
}

// libcurl's WebSocket client: text and binary echo, a ping it sends and the
// pong it reads, and a close it starts.
@(test)
curl_client :: proc(t: ^testing.T) {
	run(t, curl_mode)
}

curl_mode :: proc(s: Session, server: ^Server) -> bool {
	scheme := "wss" if s.secure else "ws"
	client := fetch.client_make()
	defer fetch.client_destroy(&client)
	opened := fetch.websocket_open(
		&client,
		{
			url = fmt.tprintf("%s://synthetic.invalid:%d/ws", scheme, s.port),
			resolve = fmt.tprintf("synthetic.invalid:%d:127.0.0.1", s.port),
			ca_file = "tests/fixtures/tls/rsa2048-valid.pem",
			headers = {"Origin: https://allowed.invalid", "Sec-WebSocket-Protocol: chat.v1, chat.v2", "X-Test-Auth: allow"},
		},
	)
	if !testing.expectf(s.t, opened.code == curl.CURLE_OK && opened.status == 101, "curl upgrade: %d %s", opened.status, opened.message) {
		return false
	}
	selected, _ := fetch.header(opened, "Sec-WebSocket-Protocol")
	testing.expect_value(s.t, selected, "chat.v2")
	Exchange :: struct {
		flags:   c.uint,
		payload: string,
	}
	exchanges := []Exchange{{curl.CURLWS_TEXT, "curl-text"}, {curl.CURLWS_BINARY, "\x00\x01\x02curl"}, {curl.CURLWS_PING, "curl-ping"}}
	for exchange in exchanges {
		sent := fetch.websocket_send(&client, transmute([]u8)exchange.payload, exchange.flags)
		testing.expectf(s.t, sent == curl.CURLE_OK, "curl send: %d", sent)
		want := c.int(exchange.flags if exchange.flags != curl.CURLWS_PING else curl.CURLWS_PONG)
		flags, payload, received := fetch.websocket_receive(&client)
		testing.expectf(s.t, received == curl.CURLE_OK, "curl receive: %d", received)
		testing.expectf(s.t, flags & want != 0 && string(payload) == exchange.payload, "curl got flags %x %q, want %x %q", flags, string(payload), want, exchange.payload)
	}
	sent := fetch.websocket_send(&client, {3, 232}, curl.CURLWS_CLOSE)
	testing.expectf(s.t, sent == curl.CURLE_OK, "curl close: %d", sent)
	flags, payload, received := fetch.websocket_receive(&client)
	testing.expectf(s.t, received == curl.CURLE_OK && flags & curl.CURLWS_CLOSE != 0, "curl close echo: %d flags %x %x", received, flags, payload)
	fetch.client_destroy(&client)
	m := ok_idle(s, server) or_return
	return testing.expectf(s.t, m.clean == 1 && m.unclean == 0, "%v", m)
}
