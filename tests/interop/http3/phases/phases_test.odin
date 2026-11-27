// Saba's HTTP/3 request phase budgets against an nghttp3 client: a stalled
// phase resets only its own stream, a slow reader that still grants credit
// gets its whole response, and a streamed response has a budget of its own.
package phases_test

import nghttp3 "../../../support/c/nghttp3"
import peer "../peer"
import "core:bytes"
import "core:testing"
import "core:time"

SERVER :: "tests/interop/http3/phases/server"
CERTIFICATE :: "tests/fixtures/tls/rsa2048-valid.pem"
KEY :: "tests/fixtures/tls/rsa2048.pem"
LARGE :: 65536

start :: proc(
	t: ^testing.T,
	cl: ^peer.Client,
	window: u64,
	arguments: ..string,
) -> (
	server: peer.Server,
	ok: bool,
) {
	testing.set_fail_timeout(t, 60 * time.Second)
	args := make([dynamic]string, context.temp_allocator)
	append(&args, CERTIFICATE, KEY)
	append(&args, ..arguments)
	server = peer.serve(t, SERVER, ..args[:]) or_return
	config := peer.Config {
		port          = server.port,
		roots         = CERTIFICATE,
		server_name   = "synthetic.invalid",
		stream_window = window,
	}
	if !testing.expect(t, peer.connect(cl, config)) ||
	   !testing.expectf(t, peer.handshake(cl), "handshake: %s", peer.describe(cl)) {
		peer.stop(t, &server, "")
		return server, false
	}
	return server, true
}

post :: proc(cl: ^peer.Client, path: string, open := false, withhold := false) -> ^peer.Stream {
	return peer.request(
		cl,
		{
			method = "POST",
			path = path,
			authority = "fixture.invalid",
			open = open,
			withhold = withhold,
		},
	)
}

connect :: proc(cl: ^peer.Client, path: string) -> ^peer.Stream {
	return peer.request(
		cl,
		{
			method = "CONNECT",
			protocol = "websocket",
			path = path,
			authority = "fixture.invalid",
			open = true,
		},
	)
}

// Runs until every stream is reset; the connection must stay open.
await_resets :: proc(
	t: ^testing.T,
	cl: ^peer.Client,
	streams: []^peer.Stream,
	loc := #caller_location,
) -> bool {
	State :: struct {
		streams: []^peer.Stream,
	}
	state := State{streams}
	done := peer.run(cl, 5 * time.Second, proc(cl: ^peer.Client, data: rawptr) -> bool {
			if cl.closed {
				return true
			}
			for s in (cast(^State)data).streams {
				if s.reset < 0 {
					return false
				}
			}
			return true
		}, &state)
	return testing.expectf(
		t,
		done && !cl.closed,
		"streams not reset: %s",
		peer.describe(cl),
		loc = loc,
	)
}

await_ended :: proc(
	t: ^testing.T,
	s: ^peer.Stream,
	label: string,
	loc := #caller_location,
) -> bool {
	peer.await(s, 5 * time.Second)
	return testing.expectf(
		t,
		s.ended && s.reset < 0 && !s.client.closed,
		"%s: ended=%v reset=%d %s",
		label,
		s.ended,
		s.reset,
		peer.describe(s.client),
		loc = loc,
	)
}

// With 256 bytes of credit per stream, six requests each stall or fail in a
// different phase, and only their own streams are reset: a response whose
// reader never grants more credit (H3_REQUEST_CANCELLED once the 400ms
// response budget is spent), an incomplete HEADERS frame (header budget), a
// body that never arrives (body budget), a failing producer and a handler
// that misses its deadline (H3_INTERNAL_ERROR). The healthy requests next to
// them are answered, an extended CONNECT whose handler never accepts is
// reset after its 700ms accept budget, and an accepted tunnel outlives every
// ordinary budget.
@(test)
isolation :: proc(t: ^testing.T) {
	cl: peer.Client
	defer peer.destroy(&cl)
	server, ok := start(t, &cl, 256)
	if !ok {
		return
	}
	defer peer.stop(t, &server, "COUNTS ")
	large := post(&cl, "/large", withhold = true)
	// The first byte of a HEADERS frame type, and nothing after it.
	partial := peer.raw_stream(&cl, {0x01}, false)
	body := post(&cl, "/body", open = true)
	producer := post(&cl, "/producer-failure")
	handler := post(&cl, "/handler-failure")
	healthy := post(&cl, "/healthy")
	if !await_ended(t, healthy, "/healthy") {
		return
	}
	testing.expect_value(t, string(healthy.body[:]), "healthy")
	if !await_resets(t, &cl, {large, partial, body, producer, handler}) {
		return
	}
	testing.expect_value(t, large.reset, nghttp3.H3_REQUEST_CANCELLED)
	testing.expect_value(t, partial.reset, nghttp3.H3_REQUEST_CANCELLED)
	testing.expect_value(t, body.reset, nghttp3.H3_REQUEST_CANCELLED)
	testing.expect_value(t, producer.reset, nghttp3.H3_INTERNAL_ERROR)
	testing.expect_value(t, handler.reset, nghttp3.H3_INTERNAL_ERROR)
	testing.expectf(
		t,
		!large.ended && len(large.body) < LARGE,
		"the constrained response completed: %d bytes",
		len(large.body),
	)
	// The server kept within the credit it was given, and the client really
	// withheld more.
	testing.expectf(
		t,
		large.received <= 256 && large.withheld > 0,
		"the constrained stream reached offset %d",
		large.received,
	)

	after := post(&cl, "/healthy")
	accept := connect(&cl, "/accept-pending")
	tunnel := connect(&cl, "/tunnel")
	Pair :: struct {
		after, tunnel: ^peer.Stream,
	}
	pair := Pair{after, tunnel}
	ready := peer.run(
		cl = &cl,
		timeout = 5 * time.Second,
		data = &pair,
		done = proc(cl: ^peer.Client, data: rawptr) -> bool {
			p := cast(^Pair)data
			return cl.closed || p.after.ended && len(p.tunnel.headers) > 0
		},
	)
	testing.expectf(
		t,
		ready && !cl.closed && after.ended && len(tunnel.headers) > 0,
		"after the resets: %s",
		peer.describe(&cl),
	)
	testing.expect_value(t, string(after.body[:]), "healthy")
	testing.expect_value(t, peer.status(tunnel), 200)
	if !await_resets(t, &cl, {accept}) {
		return
	}
	testing.expect_value(t, accept.reset, nghttp3.H3_REQUEST_CANCELLED)
	// Deliberately cross the ordinary phase budgets.
	peer.run(&cl, 300 * time.Millisecond)
	testing.expectf(
		t,
		tunnel.reset < 0 && !tunnel.ended && !cl.closed,
		"the tunnel ended: reset=%d %s",
		tunnel.reset,
		peer.describe(&cl),
	)
	peer.cancel(tunnel)
	peer.run(&cl, 50 * time.Millisecond)
	peer.close(&cl)
}

// 64 bytes of stream credit, granted again as the client reads: the 64KiB
// response arrives whole, in small stream frames, within its 3s budget.
@(test)
progress :: proc(t: ^testing.T) {
	cl: peer.Client
	defer peer.destroy(&cl)
	server, ok := start(t, &cl, 64, "progress")
	if !ok {
		return
	}
	defer peer.stop(t, &server, "COUNTS ")
	stream := post(&cl, "/large")
	if !await_ended(t, stream, "/large") {
		return
	}
	zeros := make([]u8, LARGE, context.temp_allocator)
	testing.expectf(
		t,
		bytes.equal(stream.body[:], zeros),
		"the response is %d bytes",
		len(stream.body),
	)
	small := false
	for n in stream.chunks {
		small ||= 5 < n && n < 64
	}
	testing.expectf(t, small, "no small stream frame among the first: %v", stream.chunks[:])
	peer.close(&cl)
}

// A streamed response waits 600ms before its only chunk: past the 400ms
// ordinary response budget, inside its own 1500ms stream budget.
@(test)
stream_budget :: proc(t: ^testing.T) {
	cl: peer.Client
	defer peer.destroy(&cl)
	server, ok := start(t, &cl, 0)
	if !ok {
		return
	}
	defer peer.stop(t, &server, "COUNTS ")
	started := time.tick_now()
	stream := post(&cl, "/stream-budget")
	if !await_ended(t, stream, "/stream-budget") {
		return
	}
	elapsed := time.tick_since(started)
	testing.expect_value(t, string(stream.body[:]), "stream-ok")
	testing.expectf(t, elapsed >= 550 * time.Millisecond, "the response took %v", elapsed)
	peer.close(&cl)
}
