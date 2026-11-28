package saba_core

import "core:net"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import async "shared:async"
import credential_store "shared:async/tls/credentials/store"
import http3 "shared:async/http/v3"
import "shared:async/tls"

// What the HTTP/3 listener waits for wakes its task by itself. The task used
// to step every millisecond, with or without a connection, and that polling
// was the only thing behind the wakes these tests pin.

H3W_Server :: struct {
	config:  Server,
	control: Server_Control,
	ok:      bool,
	// /later answers once this gate is opened.
	gate:    Waiting_Gate,
}

h3w_handler :: proc(data: rawptr, conn: ^Connection, request: ^Request) -> Response {
	fixture := cast(^H3W_Server)data
	switch request.path {
	case "/default":
		return rm_default(conn)
	case "/yields":
		return waiting_yields()
	case "/later":
		return waiting_later(&fixture.gate, 20 * time.Second)
	}
	return {status = .OK, body = transmute([]u8)string("ok")}
}

// Starts a server with HTTP/3 on a loopback port. Returns its thread and the
// port, zero when it did not start.
h3w_start :: proc(fixture: ^H3W_Server, store: ^credential_store.Store) -> (^thread.Thread, int) {
	fixture.config = {
		handler = h3w_handler,
		handler_data = fixture,
		control = &fixture.control,
		workers = 1,
		http3 = {enabled = true, endpoint = {net.IP4_Loopback, 0}, credentials = store},
	}
	worker := thread.create_and_start_with_poly_data(fixture, proc(f: ^H3W_Server) {f.ok = serve(f.config)})
	// A startup bound only: generous, since a loaded machine can take seconds
	// to start serve, and nothing here measures it.
	until := time.tick_add(time.tick_now(), 60 * time.Second)
	for !server_ready(&fixture.control) && !thread.is_done(worker) && time.tick_diff(time.tick_now(), until) > 0 {
		time.sleep(time.Millisecond)
	}
	endpoint, ready := server_http3_endpoint(&fixture.control)
	return worker, endpoint.port if ready else 0
}

// A listener nobody talks to has no timer and no datagram to wait for: its
// task takes its first turns and then none.
@(test)
http3_idle_listener_is_not_polled :: proc(t: ^testing.T) {
	store := h3_limits_store()
	defer credential_store.destroy(&store)
	fixture: H3W_Server
	worker, port := h3w_start(&fixture, store)
	defer thread.destroy(worker)
	defer {
		stop_server(&fixture.control)
		thread.join(worker)
	}
	if !testing.expect(t, port > 0) {
		return
	}
	listener := &fixture.control._server.http3
	// The turns that started the listener are over by now.
	time.sleep(200 * time.Millisecond)
	before := sync.atomic_load(&listener._turns)
	time.sleep(time.Second)
	turns := sync.atomic_load(&listener._turns) - before
	testing.expectf(t, turns <= 5, "an idle listener ran %d turns in a second", turns)
}

// A producer that yields is asked again at once. Between two yields the peer
// sends nothing and no timer is due, so a listener that waited for a datagram
// would take far longer than the exchange allows.
@(test)
http3_yielding_producer_is_asked_again_at_once :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, time.Minute)
	store := h3_limits_store()
	defer credential_store.destroy(&store)
	fixture: H3W_Server
	worker, port := h3w_start(&fixture, store)
	defer thread.destroy(worker)
	defer {
		stop_server(&fixture.control)
		thread.join(worker)
	}
	if !testing.expect(t, port > 0) {
		return
	}
	roots := h3_limits_roots()
	defer tls.root_pool_destroy(&roots)
	pool := new(http3.Pool)
	defer {
		http3.pool_close(pool)
		free(pool)
	}
	result := http3.pool_exchange_request(
		pool,
		{net.IP4_Loopback, port},
		"127.0.0.1",
		{method = "GET", target = "/yields", authority = "127.0.0.1"},
		roots.roots[:roots.count],
		time.time_add(time.now(), 10 * time.Second),
	)
	testing.expect(t, result.error == .None, h3_test_error(&result))
	testing.expect_value(t, result.status, 200)
	testing.expect_value(t, h3_test_body(&result), "yielded")
}

H3W_Opener :: struct {
	fixture:      ^H3W_Server,
	turned, woke: bool,
}

// Opens the gate right after a turn of the listener, once the handler waits
// behind it and the turns of the request itself are over, and reports whether
// the listener then took a turn before its next one was due.
h3w_open_after_a_turn :: proc(opener: ^H3W_Opener) {
	fixture := opener.fixture
	until := time.tick_add(time.tick_now(), 30 * time.Second)
	for !waiting_gate_reached(&fixture.gate) && time.tick_diff(time.tick_now(), until) > 0 {
		time.sleep(time.Millisecond)
	}
	time.sleep(300 * time.Millisecond)
	listener := &fixture.control._server.http3
	opener.turned = h3w_turned(listener, sync.atomic_load(&listener._turns), 3 * http3.LISTENER_MAX_WAIT)
	turn := sync.atomic_load(&listener._turns)
	waiting_gate_open(&fixture.gate)
	opener.woke = h3w_turned(listener, turn, http3.LISTENER_MAX_WAIT - http3.LISTENER_MAX_WAIT / 8)
}

// Whether the listener takes a turn within limit of the moment it had taken
// since turns.
h3w_turned :: proc(listener: ^Http3, since: u64, limit: time.Duration) -> bool {
	until := time.tick_add(time.tick_now(), limit)
	for sync.atomic_load(&listener._turns) == since && time.tick_diff(time.tick_now(), until) > 0 {
		time.sleep(time.Millisecond)
	}
	return sync.atomic_load(&listener._turns) != since
}

// A deferred response wakes the listener through its signal. A listener that
// holds a connection takes a turn at least every LISTENER_MAX_WAIT, and the
// gate opens right after one: a listener that waited for the next such turn
// would not take one within that time.
@(test)
http3_deferred_response_wakes_the_listener :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, time.Minute)
	store := h3_limits_store()
	defer credential_store.destroy(&store)
	fixture: H3W_Server
	defer waiting_gate_close(&fixture.gate)
	worker, port := h3w_start(&fixture, store)
	defer thread.destroy(worker)
	defer {
		stop_server(&fixture.control)
		thread.join(worker)
	}
	if !testing.expect(t, port > 0) {
		return
	}
	roots := h3_limits_roots()
	defer tls.root_pool_destroy(&roots)
	pool := new(http3.Pool)
	defer {
		http3.pool_close(pool)
		free(pool)
	}
	opener := H3W_Opener {
		fixture = &fixture,
	}
	helper := thread.create_and_start_with_poly_data(&opener, h3w_open_after_a_turn)
	result := http3.pool_exchange_request(
		pool,
		{net.IP4_Loopback, port},
		"127.0.0.1",
		{method = "GET", target = "/later", authority = "127.0.0.1"},
		roots.roots[:roots.count],
		time.time_add(time.now(), 20 * time.Second),
	)
	thread.join(helper)
	thread.destroy(helper)
	testing.expect(t, result.error == .None, h3_test_error(&result))
	testing.expect_value(t, result.status, 200)
	testing.expect_value(t, h3_test_body(&result), "later")
	testing.expect(t, opener.turned, "the listener took no turn while it held a waiting request")
	testing.expect(t, opener.woke, "the ready response did not wake the listener before its next turn was due")
}

H3W_Tunnel :: struct {
	take, give: int,
	result:     async.Resume_Result,
}

// Reads take bytes and writes give bytes, then answers result.
h3w_tunnel_resume :: proc(data: rawptr, io: ^Upgrade_IO) -> async.Resume_Result {
	script := cast(^H3W_Tunnel)data
	buffer: [64]u8
	if script.take > 0 {
		_, _ = io.stream_read(io.stream_data, buffer[:script.take], {})
	}
	if script.give > 0 {
		_, _ = io.stream_write(io.stream_data, buffer[:script.give], {})
	}
	return script.result
}

// The listener moves a tunnel's bytes once a step: one buffer in before the
// handler and one out after it. A handler that took input, queued output or
// yielded may have more to do than that, and no datagram says so: the
// listener is told to step again. A handler that moved nothing is not.
@(test)
http3_tunnel_that_moved_bytes_is_stepped_again :: proc(t: ^testing.T) {
	runtime := new(Server_Runtime)
	defer free(runtime)
	owner := new(Http3)
	defer free(owner)
	owner.runtime = runtime
	state := new(Http3_Request)
	defer free(state)
	state.owner = owner
	script: H3W_Tunnel
	state.connection.upgrade = {
		data   = &script,
		resume = h3w_tunnel_resume,
	}
	endpoint := new(http3.Connect_Stream)
	defer free(endpoint)
	// Only tested against nil by the reads and writes of a tunnel.
	endpoint.transport = cast(type_of(endpoint.transport))rawptr(owner)

	again :: proc(owner: ^Http3, state: ^Http3_Request, endpoint: ^http3.Connect_Stream) -> bool {
		owner._again = false
		_ = http3_upgrade_resume(state, endpoint)
		return owner._again
	}

	script = {result = .Waiting}
	testing.expect(t, !again(owner, state, endpoint), "a handler that moved nothing asked for another step")

	endpoint.input_n = 16
	script = {take = 8, result = .Waiting}
	testing.expect(t, again(owner, state, endpoint), "a handler that took input was not stepped again")

	script = {give = 8, result = .Waiting}
	testing.expect(t, again(owner, state, endpoint), "a handler that queued output was not stepped again")

	script = {result = .Yield}
	testing.expect(t, again(owner, state, endpoint), "a handler that yielded was not stepped again")

	// The input left over and the output queued stay where they are.
	script = {result = .Waiting}
	testing.expect(t, !again(owner, state, endpoint), "a handler that moved nothing asked for another step")
}
