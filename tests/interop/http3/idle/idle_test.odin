// Saba's HTTP/3 idle timeout and request budgets against ngtcp2. The server
// has one connection slot, so a fresh connection is served only once the
// previous one is gone: that is how the suite sees Saba drop a connection.
package idle_test

import nghttp3 "../../../support/c/nghttp3"
import ngtcp2 "../../../support/c/ngtcp2"
import peer "../peer"
import "core:math"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

SERVER :: "tests/interop/http3/idle/server"
IDLE :: 400 * time.Millisecond

start :: proc(t: ^testing.T, mode: string) -> (peer.Server, bool) {
	testing.set_fail_timeout(t, 60 * time.Second)
	return peer.serve(t, SERVER, mode, peer.CERTIFICATE, peer.KEY)
}

open :: proc(
	t: ^testing.T,
	cl: ^peer.Client,
	port: int,
	idle := IDLE,
	loc := #caller_location,
) -> bool {
	return testing.expect(
		t,
		peer.connect(cl, {port = port, roots = peer.CERTIFICATE, idle_timeout = idle}),
		loc = loc,
	)
}

expect_ok :: proc(
	t: ^testing.T,
	cl: ^peer.Client,
	label: string,
	loc := #caller_location,
) -> bool {
	s := peer.get(cl, "/probe")
	return testing.expectf(
		t,
		s != nil && peer.status(s) == 200 && string(s.body[:]) == "idle-ok",
		"%s: GET /probe: %s",
		label,
		peer.describe(cl),
		loc = loc,
	)
}

// The idle timeout Saba advertised.
expect_negotiated :: proc(t: ^testing.T, cl: ^peer.Client, loc := #caller_location) {
	remote := ngtcp2.conn_get_remote_transport_params2(cl.conn)
	testing.expectf(
		t,
		remote != nil && time.Duration(remote.max_idle_timeout) == IDLE,
		"the server's max_idle_timeout is %v",
		time.Duration(remote.max_idle_timeout) if remote != nil else 0,
		loc = loc,
	)
}

// A fresh connection is served by the one-slot server. It waits for the slot
// with an idle timeout of its own long enough not to give up first.
expect_fresh :: proc(t: ^testing.T, port: int, loc := #caller_location) {
	fresh: peer.Client
	defer peer.destroy(&fresh)
	if open(t, &fresh, port, 30 * time.Second, loc = loc) {
		expect_ok(t, &fresh, "fresh connection", loc)
		peer.close(&fresh)
	}
}

// After a request, neither side sends anything: the connection ends on the
// negotiated idle timeout, silently (no CONNECTION_CLOSE from Saba), and the
// slot is free again.
@(test)
idle_expiry :: proc(t: ^testing.T) {
	server, ok := start(t, "idle")
	if !ok {
		return
	}
	defer peer.stop(t, &server)
	cl: peer.Client
	defer peer.destroy(&cl)
	if !open(t, &cl, server.port) || !expect_ok(t, &cl, "first") {
		return
	}
	expect_negotiated(t, &cl)
	peer.run(
		cl = &cl,
		timeout = 8 * time.Second,
		done = proc(cl: ^peer.Client, _: rawptr) -> bool {return cl.closed},
	)
	_, closed := cl.peer_close.?
	testing.expectf(t, cl.idle_closed && !closed, "want an idle timeout: %s", peer.describe(&cl))
	expect_fresh(t, server.port)
	testing.expect_value(t, peer.stop(t, &server), "RESULT calls=2 drops=0")
}

// While a connection is open, the single slot turns a second one away: the
// fresh connections the other tests open prove the first one ended.
@(test)
one_slot :: proc(t: ^testing.T) {
	server, ok := start(t, "idle")
	if !ok {
		return
	}
	defer peer.stop(t, &server)
	first: peer.Client
	defer peer.destroy(&first)
	if !open(t, &first, server.port, 30 * time.Second) || !expect_ok(t, &first, "first") {
		return
	}
	ngtcp2.conn_set_keep_alive_timeout(first.conn, ngtcp2.Duration(IDLE / 4))
	second: peer.Client
	defer peer.destroy(&second)
	if open(t, &second, server.port) {
		testing.expectf(
			t,
			!peer.handshake(&second, IDLE / 2),
			"a second connection was admitted: %s",
			peer.describe(&second),
		)
	}
	expect_ok(t, &first, "first, again")
	peer.close(&first)
	testing.expect_value(t, peer.stop(t, &server), "RESULT calls=2 drops=0")
}

// Authenticated PINGs every quarter of the idle timeout keep the connection
// open for 1.4 times that timeout; a second request is then served on it.
@(test)
authenticated_activity :: proc(t: ^testing.T) {
	server, ok := start(t, "idle")
	if !ok {
		return
	}
	defer peer.stop(t, &server)
	cl: peer.Client
	defer peer.destroy(&cl)
	if !open(t, &cl, server.port) || !expect_ok(t, &cl, "first") {
		return
	}
	expect_negotiated(t, &cl)
	interval := IDLE / 4
	ngtcp2.conn_set_keep_alive_timeout(cl.conn, ngtcp2.Duration(interval))
	window := time.Duration(f64(IDLE) * 1.4)
	before := cl.datagrams_out
	peer.run(&cl, window)
	pings := cl.datagrams_out - before
	count := int(math.ceil(f64(window) / f64(interval)))
	testing.expectf(
		t,
		!cl.closed && pings >= count - 1,
		"after %v: %d datagrams, %s",
		window,
		pings,
		peer.describe(&cl),
	)
	expect_ok(t, &cl, "after the pings")
	peer.close(&cl)
	testing.expect_value(t, peer.stop(t, &server), "RESULT calls=2 drops=0")
}

Forger :: struct {
	fd:       posix.FD,
	remote:   posix.sockaddr_in,
	packet:   [dynamic]u8,
	limit:    int,
	sent:     int,
	stop:     bool,
	captured: bool,
}

// Datagrams that carry a valid header and connection ID but a forged AEAD tag
// arrive every 10ms from the client's own address: they must not keep the
// connection alive. Saba drops it on time, so a fresh connection is served
// while the forgeries are still arriving.
@(test)
forged_activity :: proc(t: ^testing.T) {
	server, ok := start(t, "idle")
	if !ok {
		return
	}
	defer peer.stop(t, &server)
	forger: Forger
	defer delete(forger.packet)
	cl: peer.Client
	defer peer.destroy(&cl)
	config := peer.Config {
		port = server.port,
		roots = peer.CERTIFICATE,
		idle_timeout = IDLE,
		user = &forger,
		// The last genuine short header packet, its tag flipped.
		send = proc(cl: ^peer.Client, datagram: []u8) {
			forger := cast(^Forger)cl.config.user
			for p in peer.packets(datagram, 0) {
				if p.type == .Short {
					clear(&forger.packet)
					append(&forger.packet, ..p.bytes)
					forger.packet[len(forger.packet) - 1] ~= 1
					forger.captured = true
				}
			}
			peer.transmit(cl, datagram)
		},
	}
	if !testing.expect(t, peer.connect(&cl, config)) || !expect_ok(t, &cl, "first") {
		return
	}
	expect_negotiated(t, &cl)
	if !testing.expect(t, forger.captured, "no short header datagram to forge") {
		return
	}
	forger.fd = cl.fd
	forger.remote = cl.remote
	forger.limit = int((IDLE + 2 * time.Second) / (10 * time.Millisecond))
	worker := thread.create_and_start_with_poly_data(&forger, proc(f: ^Forger) {
		for !sync.atomic_load(&f.stop) && f.sent < f.limit {
			posix.sendto(
				f.fd,
				raw_data(f.packet[:]),
				len(f.packet),
				{},
				cast(^posix.sockaddr)&f.remote,
				size_of(f.remote),
			)
			sync.atomic_add(&f.sent, 1)
			time.sleep(10 * time.Millisecond)
		}
	})
	// The client keeps acknowledging until its own idle timer ends it, as
	// before. Past the idle timeout (and its three-PTO floor) the first
	// Initial of a fresh connection finds the slot free, unless the
	// forgeries kept the old connection.
	peer.run(&cl, 2 * IDLE)
	expect_fresh(t, server.port)
	sent := sync.atomic_load(&forger.sent)
	sync.atomic_store(&forger.stop, true)
	thread.join(worker)
	thread.destroy(worker)
	testing.expectf(
		t,
		0 < sent && sent < forger.limit,
		"%d forged datagrams (limit %d)",
		sent,
		forger.limit,
	)
	testing.expect_value(t, peer.stop(t, &server), "RESULT calls=2 drops=0")
}

// The 50ms pending-handler budget bounds a request, not the connection: after
// 0.4 times the idle timeout without traffic the connection still serves.
@(test)
request_budget :: proc(t: ^testing.T) {
	server, ok := start(t, "request-budget")
	if !ok {
		return
	}
	defer peer.stop(t, &server)
	cl: peer.Client
	defer peer.destroy(&cl)
	if !open(t, &cl, server.port) || !expect_ok(t, &cl, "first") {
		return
	}
	delay := time.Duration(f64(IDLE) * 0.4)
	peer.run(&cl, delay)
	testing.expectf(t, !cl.closed, "after %v: %s", delay, peer.describe(&cl))
	expect_ok(t, &cl, "after the budget")
	peer.close(&cl)
	testing.expect_value(t, peer.stop(t, &server), "RESULT calls=2 drops=0")
}

// A handler that never answers: when its 200ms budget runs out (without a
// request phase policy), Saba closes the connection with
// H3_REQUEST_CANCELLED, sends no response, and drops the pending work.
@(test)
pending_request_timeout :: proc(t: ^testing.T) {
	server, ok := start(t, "pending")
	if !ok {
		return
	}
	defer peer.stop(t, &server)
	cl: peer.Client
	defer peer.destroy(&cl)
	if !open(t, &cl, server.port, 5 * time.Second) || !testing.expect(t, peer.handshake(&cl)) {
		return
	}
	started := time.tick_now()
	s := peer.request(&cl, {path = "/probe"})
	peer.run(
		cl = &cl,
		timeout = 3 * time.Second,
		done = proc(cl: ^peer.Client, _: rawptr) -> bool {return cl.closed},
	)
	elapsed := time.tick_since(started)
	close, closed := cl.peer_close.?
	testing.expectf(
		t,
		closed && close.type == .Application && close.error_code == nghttp3.H3_REQUEST_CANCELLED,
		"want an application CONNECTION_CLOSE 0x10c: %s",
		peer.describe(&cl),
	)
	testing.expectf(
		t,
		100 * time.Millisecond < elapsed && elapsed < 3 * time.Second,
		"closed after %v",
		elapsed,
	)
	testing.expectf(t, s != nil && len(s.headers) == 0, "the pending handler produced a response")
	testing.expect_value(t, peer.stop(t, &server), "RESULT calls=1 drops=1")
}
