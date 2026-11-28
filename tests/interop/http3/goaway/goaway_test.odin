// Saba's HTTP/3 GOAWAY against an nghttp3 client: the first datagram after
// the drain starts is lost, GOAWAY still arrives (non-increasing, a client
// stream ID), the client's own GOAWAY is accepted, an open WebSocket keeps
// working, a request past the GOAWAY ID is rejected, and once the last
// stream ends Saba closes the connection with H3_NO_ERROR.
package goaway_test

import nghttp3 "../../../support/c/nghttp3"
import peer "../peer"
import "core:testing"
import "core:time"

SERVER :: "tests/fixtures/apps/http3_shutdown"

Relay :: struct {
	armed:   bool,
	dropped: int,
}

@(test)
graceful_shutdown :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 60 * time.Second)
	server, ok := peer.serve(t, SERVER, peer.CERTIFICATE, peer.KEY)
	if !ok {
		return
	}
	defer peer.stop(t, &server)
	relay: Relay
	cl: peer.Client
	defer peer.destroy(&cl)
	config := peer.Config {
		port = server.port,
		roots = peer.CERTIFICATE,
		user = &relay,
		// Once armed, the server's first short header datagram is lost.
		receive = proc(cl: ^peer.Client, datagram: []u8) -> []u8 {
			relay := cast(^Relay)cl.config.user
			if relay.armed && relay.dropped == 0 && datagram[0] & 0x80 == 0 {
				relay.dropped += 1
				return nil
			}
			return datagram
		},
	}
	if !testing.expect(t, peer.connect(&cl, config)) {
		return
	}
	live := peer.ws_open(&cl)
	cancelled := peer.ws_open(&cl)
	if !testing.expectf(
		t,
		live.stream != nil &&
		peer.status(live.stream) == 200 &&
		cancelled.stream != nil &&
		peer.status(cancelled.stream) == 200,
		"CONNECT: %s",
		peer.describe(&cl),
	) {
		return
	}
	peer.run(&cl, 100 * time.Millisecond)
	relay.armed = true

	// The slow response to /drain completes after its connection drains.
	drain := peer.get(&cl, "/drain")
	testing.expectf(
		t,
		drain != nil && peer.status(drain) == 200 && string(drain.body[:]) == "http-ok",
		"GET /drain: %s",
		peer.describe(&cl),
	)
	if !testing.expectf(t, len(cl.goaways) > 0, "no GOAWAY: %s", peer.describe(&cl)) {
		return
	}
	for id, i in cl.goaways {
		testing.expectf(
			t,
			id % 4 == 0 && (i == 0 || id <= cl.goaways[i - 1]),
			"GOAWAY IDs %v",
			cl.goaways[:],
		)
	}
	// Streams 0, 4 and 8 were accepted; 12 and later are not.
	testing.expect_value(t, cl.goaways[len(cl.goaways) - 1], 12)

	// The client's GOAWAY, a notice then the final push ID 0.
	testing.expect_value(t, nghttp3.conn_submit_shutdown_notice(cl.h3), 0)
	testing.expect_value(t, nghttp3.conn_shutdown(cl.h3), 0)
	peer.cancel(cancelled.stream)
	echoed, echo_ok := peer.ws_exchange(
		&live,
		.Text,
		transmute([]u8)string("shutdown-live"),
		.Text,
	)
	testing.expectf(
		t,
		echo_ok && string(echoed) == "shutdown-live",
		"the WebSocket after GOAWAY: %s",
		peer.describe(&cl),
	)

	// nghttp3 refuses a request past the GOAWAY ID, so it goes out raw.
	rejected := peer.raw_stream(
		&cl,
		peer.headers_frame(
			{
				{":method", "GET"},
				{":scheme", "https"},
				{":authority", "localhost"},
				{":path", "/health"},
			},
		),
		true,
	)
	testing.expect_value(t, rejected.id, 12)
	peer.run(
		cl = &cl,
		timeout = 8 * time.Second,
		data = rejected,
		done = proc(cl: ^peer.Client, data: rawptr) -> bool {
			return cl.closed || (cast(^peer.Stream)data).reset >= 0
		},
	)
	testing.expect_value(t, rejected.reset, nghttp3.H3_REQUEST_REJECTED)
	testing.expectf(
		t,
		cancelled.stream.reset < 0 || cancelled.stream.reset == nghttp3.H3_REQUEST_CANCELLED,
		"the cancelled tunnel was reset with 0x%x",
		cancelled.stream.reset,
	)

	testing.expectf(
		t,
		peer.ws_close(&live),
		"the close handshake did not finish: %s",
		peer.describe(&cl),
	)
	peer.run(
		cl = &cl,
		timeout = 8 * time.Second,
		done = proc(cl: ^peer.Client, _: rawptr) -> bool {return cl.closed},
	)
	close, closed := cl.peer_close.?
	testing.expectf(
		t,
		closed && close.type == .Application && close.error_code == nghttp3.H3_NO_ERROR,
		"want the server to close with H3_NO_ERROR: %s",
		peer.describe(&cl),
	)
	testing.expect_value(t, relay.dropped, 1)
	testing.expect_value(
		t,
		peer.stop(t, &server),
		"RESULT opened=2 dropped=2 messages=1 http=1 resets=1 stream_drops=1",
	)
}
