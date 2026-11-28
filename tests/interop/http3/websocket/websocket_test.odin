// WebSockets over HTTP/3 (RFC 9220) between Saba and an nghttp3 client that
// frames RFC 6455 messages itself: extended CONNECT is refused for a foreign
// origin, an unoffered subprotocol and an unknown protocol, two tunnels
// share a connection with ordinary requests, and each ends on its own.
package websocket_test

import nghttp3 "../../../support/c/nghttp3"
import ngtcp2 "../../../support/c/ngtcp2"
import peer "../peer"
import "core:bytes"
import "core:testing"
import "core:time"

SERVER :: "tests/fixtures/apps/http3_websocket"

// A refused CONNECT is answered with status, and the client resets it.
expect_refused :: proc(
	t: ^testing.T,
	cl: ^peer.Client,
	status: int,
	origin := "https://allowed.invalid",
	subprotocol := "chat.v2",
	protocol := "websocket",
	loc := #caller_location,
) {
	socket := peer.ws_open(cl, origin = origin, subprotocol = subprotocol, protocol = protocol)
	s := socket.stream
	if testing.expectf(
		t,
		s != nil && peer.status(s) == status,
		"CONNECT (%s, %s, %s): %d, want %d: %s",
		origin,
		subprotocol,
		protocol,
		peer.status(s) if s != nil else 0,
		status,
		peer.describe(cl),
		loc = loc,
	) {
		ngtcp2.conn_shutdown_stream_write(cl.conn, 0, s.id, nghttp3.H3_REQUEST_CANCELLED)
	}
}

expect_echo :: proc(
	t: ^testing.T,
	socket: ^peer.Socket,
	opcode: peer.Ws_Opcode,
	payload: []u8,
	want: peer.Ws_Opcode,
	loc := #caller_location,
) {
	echoed, ok := peer.ws_exchange(socket, opcode, payload, want)
	testing.expectf(
		t,
		ok && bytes.equal(echoed, payload),
		"%v of %d bytes: %v of %d bytes came back: %s",
		opcode,
		len(payload),
		want,
		len(echoed),
		peer.describe(socket.stream.client),
		loc = loc,
	)
}

expect_health :: proc(t: ^testing.T, cl: ^peer.Client, loc := #caller_location) {
	s := peer.get(cl, "/health")
	testing.expectf(
		t,
		s != nil && peer.status(s) == 200 && string(s.body[:]) == "http-ok",
		"GET /health: %s",
		peer.describe(cl),
		loc = loc,
	)
}

@(test)
independent_client :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 60 * time.Second)
	server, ok := peer.serve(t, SERVER, peer.CERTIFICATE, peer.KEY)
	if !ok {
		return
	}
	defer peer.stop(t, &server)
	cl: peer.Client
	defer peer.destroy(&cl)
	if !testing.expect(t, peer.connect(&cl, {port = server.port, roots = peer.CERTIFICATE})) {
		return
	}
	expect_refused(t, &cl, 403, origin = "https://denied.invalid")
	expect_refused(t, &cl, 400, subprotocol = "unoffered")
	expect_refused(t, &cl, 501, protocol = "unknown")

	first := peer.ws_open(&cl)
	second := peer.ws_open(&cl)
	for socket in ([]peer.Socket{first, second}) {
		s := socket.stream
		if !testing.expectf(
			t,
			s != nil && peer.status(s) == 200,
			"CONNECT: %s",
			peer.describe(&cl),
		) {
			return
		}
		testing.expect_value(t, peer.header(s, "sec-websocket-protocol"), "chat.v2")
		testing.expect(t, !s.ended, "the tunnel ended with its response")
		// RFC 9220 leaves out the HTTP/1.1 handshake headers.
		testing.expect(
			t,
			peer.header(s, "sec-websocket-accept") == "" && peer.header(s, "upgrade") == "",
		)
	}
	expect_health(t, &cl)

	expect_echo(t, &first, .Text, transmute([]u8)string("independent"), .Text)
	expect_echo(t, &first, .Ping, transmute([]u8)string("ping"), .Pong)
	// Larger than a flow control window and Saba's 64KiB body queue.
	payload := make([]u8, 128 * 1024, context.temp_allocator)
	for &b, i in payload {
		b = u8(i % 251)
	}
	expect_echo(t, &first, .Binary, payload, .Binary)
	testing.expectf(
		t,
		peer.ws_close(&first),
		"the close handshake did not finish: %s",
		peer.describe(&cl),
	)

	// The second tunnel is untouched, then cancelled with
	// H3_REQUEST_CANCELLED in both directions; the connection keeps serving.
	expect_echo(t, &second, .Text, transmute([]u8)string("survivor"), .Text)
	peer.cancel(second.stream)
	expect_health(t, &cl)
	peer.close(&cl)
	testing.expect_value(
		t,
		peer.stop(t, &server),
		"RESULT opened=2 dropped=2 messages=3 http=2 resets=1",
	)
}
