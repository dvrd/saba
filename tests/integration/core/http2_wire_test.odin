package saba_core

import "shared:async/tls"
import tlscredentials "shared:async/tls/credentials"
import credential_store "shared:async/tls/credentials/store"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import async "shared:async"
import h2 "shared:async/http/v2"

// Loopback wire regressions for the HTTP/2 owner: one real TLS listener and a
// hand-framed peer, so deadlines, flow control and resets are exercised end to end.
H2W_IDLE :: 300 * time.Millisecond
H2W_RESPONSE :: time.Second
H2W_PATIENCE :: 6 * time.Second

H2W_Server :: struct {
	config:  Server,
	control: Server_Control,
	tls:     TLS_Config,
	ok:      bool,
	handled: int,
	echoed:  int,
	limit:   int,
	// Nonzero replaces the default body timeout; observed turns on observability.
	body:     time.Duration,
	observed: bool,
	// The connection that served /refuse over an ordinary HTTP/2 stream.
	refused:  ^Connection_Task,
}

H2W_Frame :: struct {
	kind, flags: u8,
	stream:      u32,
	payload:     []u8,
}

H2W_Peer :: struct {
	conn:    tls.Conn,
	storage: [16384 + 9]u8,
}

h2w_hold :: proc(_: rawptr, _: ^Deferred_IO) -> (Response, Deferred_Step) {
	return {}, .Waiting
}

h2w_tunnel :: proc(data: rawptr, io: ^Upgrade_IO) -> async.Resume_Result {
	state := cast(^H2W_Server)data
	buffer: [64]u8

	for {
		n, error := upgrade_read(io, buffer[:], {})
		if error.kind == .Pending {
			return .Waiting
		}
		if error.kind != .None || n == 0 {
			return .Done
		}
		written, _ := upgrade_write(io, buffer[:n], {})
		sync.atomic_add(&state.echoed, written)
	}
}

h2w_handler :: proc(data: rawptr, conn: ^Connection, request: ^Request) -> Response {
	state := cast(^H2W_Server)data
	sync.atomic_add(&state.handled, 1)

	switch request.path {
	case "/hold":
		return {deferred = {poll = h2w_hold, drop = proc(_: rawptr) {}, timeout = 3 * time.Second}}
	case "/refuse":
		if conn != nil && conn._task != nil && conn._task.http2_request != nil {
			sync.atomic_store(&state.refused, conn._task.http2_request.parent)
		}
		return {status = .OK, body = transmute([]u8)string("an ordinary body the peer never grants credit for")}
	case "/tunnel":
		return {status = .OK, upgrade = {data = state, resume = h2w_tunnel, drop = proc(_: rawptr) {}}}
	case "/many":
		headers := make([]Header, 100, request.allocator)
		for &header in headers {
			header = {"x-filler", "value"}
		}
		return {status = .OK, headers = headers, body = transmute([]u8)string("many")}
	case "/huge":
		headers := make([]Header, 400, request.allocator)
		for &header in headers {
			header = {"x-filler", "value"}
		}
		return {status = .OK, headers = headers, body = transmute([]u8)string("huge")}
	case "/trailers":
		trailers := make([]Header, 1, request.allocator)
		trailers[0] = {"grpc-status", "0"}
		return {status = .OK, body = transmute([]u8)string("body"), trailers = trailers}
	case "/echo":
		return {status = .OK, body = request.body}
	}

	return {status = .OK, body = transmute([]u8)string("ok")}
}

h2w_body_limit :: proc(request: ^Request) -> int {
	return 64 * 1024 * 1024
}

h2w_run :: proc(t: ^testing.T, state: ^H2W_Server, exchange: proc(t: ^testing.T, state: ^H2W_Server, peer: ^H2W_Peer)) {
	testing.set_fail_timeout(t, 40 * time.Second)
	certificate := #load("../../tests/fixtures/tls/localhost.pem")
	credential, created := tlscredentials.create(
		certificate,
		#load("../../tests/fixtures/tls/rsa2048.pem"),
		{},
		context.allocator,
	)
	assert(created == .None)
	store, stored := credential_store.create({}, context.allocator)
	assert(stored.kind == .None && credential_store.replace(store, &credential).kind == .None)
	defer credential_store.destroy(&store)
	roots: tls.Root_Pool
	assert(tls.root_pool_parse(&roots, certificate) == nil)
	defer tls.root_pool_destroy(&roots)
	state.tls = {
		store = store,
	}
	state.config = {
		address = "127.0.0.1",
		workers = 1,
		handler = h2w_handler,
		handler_data = state,
		control = &state.control,
		tls = &state.tls,
		timeouts = {header = 2 * time.Second, body = time.Second, response = H2W_RESPONSE, idle = H2W_IDLE},
	}
	if state.limit != 0 {
		state.config.request_body_limit = h2w_body_limit
	}
	if state.body != 0 {
		state.config.timeouts.body = state.body
	}
	state.config.observability.enabled = state.observed

	worker := thread.create_and_start_with_poly_data(state, proc(s: ^H2W_Server) {s.ok = serve(s.config)})
	assert(worker != nil)
	defer {
		stop_server(&state.control)
		thread.join(worker)
		thread.destroy(worker)
		testing.expect(t, state.ok)
	}
	until := time.tick_add(time.tick_now(), 5 * time.Second)
	for !server_ready(&state.control) && time.tick_diff(time.tick_now(), until) > 0 {
		thread.yield()
	}
	endpoint, ready := server_endpoint(&state.control)
	if !testing.expect(t, ready && endpoint.port > 0, "server did not publish a loopback endpoint") {
		return
	}

	peer := new(H2W_Peer)
	defer free(peer)
	dialed := tls.dial(
		&peer.conn,
		"127.0.0.1",
		endpoint.port,
		{
			server_name = "localhost",
			root_cas = roots.roots[:roots.count],
			alpn_protocols = {"h2"},
			handshake_timeout = 5 * time.Second,
		},
	)
	if !testing.expect(t, dialed == nil, "TLS dial failed") {
		return
	}
	defer _ = tls.abort(&peer.conn)
	assert(tls.set_deadline(&peer.conn, time.time_add(time.now(), H2W_PATIENCE)) == nil)
	exchange(t, state, peer)
}

h2w_send :: proc(peer: ^H2W_Peer, bytes: []u8) -> bool {
	n, error := tls.write(&peer.conn, bytes)
	return error == nil && n == len(bytes)
}

h2w_frame :: proc(out: ^[dynamic]u8, kind, flags: u8, stream: u32, payload: []u8) {
	size := len(payload)
	append(out, u8(size >> 16), u8(size >> 8), u8(size), kind, flags)
	append(out, u8(stream >> 24), u8(stream >> 16), u8(stream >> 8), u8(stream))
	append(out, ..payload)
}

// Literal header fields without indexing and without Huffman coding.
h2w_fields :: proc(out: ^[dynamic]u8, fields: [][2]string) {
	for field in fields {
		assert(len(field[0]) < 127 && len(field[1]) < 127)
		append(out, 0, u8(len(field[0])))
		append(out, field[0])
		append(out, u8(len(field[1])))
		append(out, field[1])
	}
}

h2w_headers :: proc(out: ^[dynamic]u8, stream: u32, end_stream: bool, fields: [][2]string) {
	block: [dynamic]u8
	defer delete(block)
	h2w_fields(&block, fields)
	h2w_frame(out, 1, 0x4 | (0x1 if end_stream else 0), stream, block[:])
}

h2w_get :: proc(out: ^[dynamic]u8, stream: u32, path: string) {
	h2w_headers(out, stream, true, {{":method", "GET"}, {":scheme", "https"}, {":authority", "localhost"}, {":path", path}})
}

h2w_preface :: proc(peer: ^H2W_Peer, settings: []u8 = nil) -> bool {
	wire: [dynamic]u8
	defer delete(wire)
	append(&wire, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
	h2w_frame(&wire, 4, 0, 0, settings)
	return h2w_send(peer, wire[:])
}

h2w_read_exact :: proc(peer: ^H2W_Peer, bytes: []u8) -> bool {
	for at := 0; at < len(bytes); {
		n, error := tls.read(&peer.conn, bytes[at:])
		if error != nil || n == 0 {
			return false
		}
		at += n
	}
	return true
}

// Blocks for the next frame; false is end of connection or the peer deadline.
// SETTINGS are acknowledged here. PING is left unanswered unless asked.
h2w_next :: proc(peer: ^H2W_Peer, answer_ping := false) -> (H2W_Frame, bool) {
	header := peer.storage[:9]
	if !h2w_read_exact(peer, header) {
		return {}, false
	}
	size := int(header[0]) << 16 | int(header[1]) << 8 | int(header[2])
	frame := H2W_Frame {
		kind   = header[3],
		flags  = header[4],
		stream = (u32(header[5]) << 24 | u32(header[6]) << 16 | u32(header[7]) << 8 | u32(header[8])) & 0x7fffffff,
	}
	if size > len(peer.storage) - 9 || !h2w_read_exact(peer, peer.storage[9:][:size]) {
		return {}, false
	}
	frame.payload = peer.storage[9:][:size]
	reply: [dynamic]u8
	defer delete(reply)
	if frame.kind == 4 && frame.flags & 1 == 0 {
		h2w_frame(&reply, 4, 1, 0, nil)
	}
	if answer_ping && frame.kind == 6 && frame.flags & 1 == 0 {
		h2w_frame(&reply, 6, 1, 0, frame.payload)
	}
	if len(reply) > 0 {
		_ = h2w_send(peer, reply[:])
	}
	return frame, true
}

h2w_code :: proc(frame: H2W_Frame) -> u32 {
	payload := frame.payload
	if frame.kind == 7 && len(payload) >= 8 {
		return u32(payload[4]) << 24 | u32(payload[5]) << 16 | u32(payload[6]) << 8 | u32(payload[7])
	}
	if frame.kind == 3 && len(payload) >= 4 {
		return u32(payload[0]) << 24 | u32(payload[1]) << 16 | u32(payload[2]) << 8 | u32(payload[3])
	}
	return 0
}

// Static-table statuses are one indexed octet; anything else is reported as 0.
h2w_status :: proc(frame: H2W_Frame) -> int {
	if frame.kind != 1 || len(frame.payload) == 0 {
		return -1
	}
	switch frame.payload[0] {
	case 0x88:
		return 200
	case 0x8c:
		return 400
	case 0x8e:
		return 500
	}
	return 0
}

// An idle connection used to be handed its already expired idle deadline as
// the transport budget: GOAWAY never left, the socket never closed and the
// owner task spun. It must now announce GOAWAY and close within the bound.
@(test)
h2_idle_connection_sends_goaway_and_closes :: proc(t: ^testing.T) {
	state: H2W_Server
	h2w_run(t, &state, proc(t: ^testing.T, state: ^H2W_Server, peer: ^H2W_Peer) {
		started := time.tick_now()
		if !testing.expect(t, h2w_preface(peer)) {
			return
		}
		goaway := false
		for {
			frame, ok := h2w_next(peer)
			if !ok {
				break
			}
			if frame.kind == 7 {
				goaway = true
				testing.expect_value(t, h2w_code(frame), u32(0))
			}
		}
		elapsed := time.tick_since(started)
		testing.expect(t, goaway, "idle connection closed without GOAWAY, or never closed")
		testing.expect(t, elapsed >= H2W_IDLE, "closed before the idle timeout")
		testing.expect(t, elapsed < H2W_IDLE + H2W_RESPONSE + 2 * time.Second, "idle connection was not closed in time")
	})
}

// With a stream open past the idle deadline the owner stopped reading: a new
// request on the same connection was never dispatched.
@(test)
h2_connection_keeps_reading_while_a_stream_outlives_the_idle_timeout :: proc(t: ^testing.T) {
	state: H2W_Server
	h2w_run(t, &state, proc(t: ^testing.T, state: ^H2W_Server, peer: ^H2W_Peer) {
		wire: [dynamic]u8
		defer delete(wire)
		h2w_get(&wire, 1, "/hold")
		if !testing.expect(t, h2w_preface(peer) && h2w_send(peer, wire[:])) {
			return
		}
		time.sleep(3 * H2W_IDLE)
		clear(&wire)
		h2w_get(&wire, 3, "/")
		if !testing.expect(t, h2w_send(peer, wire[:])) {
			return
		}
		started := time.tick_now()
		answered := false
		for !answered {
			frame, ok := h2w_next(peer)
			if !ok {
				break
			}
			if frame.stream == 3 && frame.kind == 1 {
				testing.expect_value(t, h2w_status(frame), 200)
				answered = true
			}
		}
		testing.expect(t, answered, "request sent after the idle deadline was never answered")
		testing.expect(t, time.tick_since(started) < 2 * time.Second)
		testing.expect_value(t, sync.atomic_load(&state.handled), 2)
	})
}

// An extended CONNECT answered with an ordinary response, to a peer granting
// no flow-control credit, kept the connection open and spinning forever. The
// body must stay unsent and the connection must still close on time.
@(test)
h2_credit_starved_refused_tunnel_does_not_pin_the_connection :: proc(t: ^testing.T) {
	state: H2W_Server
	h2w_run(t, &state, proc(t: ^testing.T, state: ^H2W_Server, peer: ^H2W_Peer) {
		wire: [dynamic]u8
		defer delete(wire)
		h2w_headers(
			&wire,
			1,
			false,
			{{":method", "CONNECT"}, {":protocol", "websocket"}, {":scheme", "https"}, {":authority", "localhost"}, {":path", "/refuse"}},
		)
		// SETTINGS_INITIAL_WINDOW_SIZE = 0
		if !testing.expect(t, h2w_preface(peer, []u8{0, 4, 0, 0, 0, 0}) && h2w_send(peer, wire[:])) {
			return
		}
		started := time.tick_now()
		answered, goaway := false, false
		for {
			frame, ok := h2w_next(peer)
			if !ok {
				break
			}
			answered ||= frame.kind == 1 && frame.stream == 1
			goaway ||= frame.kind == 7
			testing.expect(t, frame.kind != 0 || len(frame.payload) == 0, "body sent without flow-control credit")
		}
		testing.expect(t, answered, "refused tunnel was never answered")
		testing.expect(t, goaway, "connection with a credit-starved stream never closed")
		testing.expect(t, time.tick_since(started) < 2 * H2W_RESPONSE + H2W_IDLE + 2 * time.Second)
	})
}

// More DATA frames than the tunnel's input queue holds used to reset the
// stream. They are now held back until the tunnel has read.
@(test)
h2_tunnel_burst_of_small_data_frames_is_backpressured_not_reset :: proc(t: ^testing.T) {
	state: H2W_Server
	h2w_run(t, &state, proc(t: ^testing.T, state: ^H2W_Server, peer: ^H2W_Peer) {
		FRAMES :: 3 * H2_BODY_CHUNKS
		wire: [dynamic]u8
		defer delete(wire)
		h2w_headers(
			&wire,
			1,
			false,
			{{":method", "CONNECT"}, {":protocol", "websocket"}, {":scheme", "https"}, {":authority", "localhost"}, {":path", "/tunnel"}},
		)
		for i in 0 ..< FRAMES {
			h2w_frame(&wire, 0, 0, 1, []u8{u8('a' + i)})
		}
		if !testing.expect(t, h2w_preface(peer) && h2w_send(peer, wire[:])) {
			return
		}
		echoed: [FRAMES]u8
		count := 0
		for count < FRAMES {
			frame, ok := h2w_next(peer)
			if !ok {
				break
			}
			if !testing.expect(t, frame.kind != 3, "tunnel was reset by a burst of small DATA frames") {
				return
			}
			if frame.kind == 0 && frame.stream == 1 {
				count += copy(echoed[count:], frame.payload)
			}
		}
		if testing.expect_value(t, count, FRAMES) {
			for byte, i in echoed {
				testing.expect_value(t, byte, u8('a' + i))
			}
		}
	})
}

// CVE-2023-44487: HEADERS immediately followed by RST_STREAM ran the handler
// for every pair with no limit. The connection now ends with ENHANCE_YOUR_CALM.
@(test)
h2_rapid_reset_ends_the_connection_with_enhance_your_calm :: proc(t: ^testing.T) {
	state: H2W_Server
	h2w_run(t, &state, proc(t: ^testing.T, state: ^H2W_Server, peer: ^H2W_Peer) {
		if !testing.expect(t, h2w_preface(peer)) {
			return
		}
		wire: [dynamic]u8
		defer delete(wire)
		calm := false
		stream := u32(1)
		// Each round is synchronised on its PING so no request is left unread
		// when the server closes.
		rounds: for _ in 0 ..< 2 * H2_RESET_BURST {
			clear(&wire)
			h2w_get(&wire, stream, "/")
			h2w_frame(&wire, 3, 0, stream, []u8{0, 0, 0, 8})
			h2w_frame(&wire, 6, 0, 0, []u8{1, 2, 3, 4, 5, 6, 7, 8})
			stream += 2
			if !h2w_send(peer, wire[:]) {
				break
			}
			for {
				frame, ok := h2w_next(peer)
				if !ok {
					break rounds
				}
				if frame.kind == 7 {
					testing.expect_value(t, h2w_code(frame), u32(11))
					calm = true
					break rounds
				}
				if frame.kind == 6 && frame.flags & 1 != 0 {
					break
				}
			}
		}
		testing.expect(t, calm, "rapid reset was never answered with GOAWAY(ENHANCE_YOUR_CALM)")
		handled := sync.atomic_load(&state.handled)
		testing.expect(t, handled <= H2_RESET_BURST + H2_RESET_REFILL * 10, "handler kept running for reset streams")
	})
}

// Ordinary cancellation stays inside the allowance: a burst is tolerated and
// idle seconds restore it, never above the burst.
@(test)
h2_reset_allowance_refills_and_tolerates_ordinary_cancellation :: proc(t: ^testing.T) {
	session: HTTP2_Session
	limits := h2_make_limits(8)
	testing.expect_value(t, limits.unproductive_frames, H2_RESET_BURST)
	if !testing.expect(
		t,
		h2.connection_init(&session.engine, {role = .Server, limits = limits}, {max_stream_capacity = 16}, context.allocator).kind ==
		.None,
	) {
		return
	}
	defer h2.connection_destroy(&session.engine)
	left :: proc(session: ^HTTP2_Session) -> int {
		stats, _ := h2.connection_stats(&session.engine)
		return stats.unproductive_left
	}

	// Spend the whole burst with PRIORITY frames after the client preface.
	wire: [dynamic]u8
	defer delete(wire)
	append(&wire, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
	h2w_frame(&wire, 4, 0, 0, nil)
	for _ in 0 ..< H2_RESET_BURST {
		h2w_frame(&wire, 2, 0, 1, []u8{0, 0, 0, 0, 0})
	}
	at := 0
	for _ in 0 ..< 4096 {
		fed := h2.connection_feed(&session.engine, wire[at:], 0)
		if !testing.expect_value(t, fed.error.kind, h2.Error_Kind.None) {
			return
		}
		at += fed.consumed
		for {
			view, borrowed := h2.connection_output_front(&session.engine)
			if !borrowed {
				break
			}
			_ = h2.connection_output_advance(&session.engine, view.token, len(view.bytes))
		}
		for {
			event, polled := h2.connection_poll(&session.engine)
			if !polled {
				break
			}
			_ = h2.connection_event_release(&session.engine, event.token)
		}
		if at == len(wire) && fed.status != .Yield {
			break
		}
	}
	testing.expect_value(t, at, len(wire))
	testing.expect_value(t, left(&session), 0)

	// Less than a second restores nothing; two idle seconds restore two refills.
	session.reset_refill = time.tick_now()
	h2_refill(&session)
	testing.expect_value(t, left(&session), 0)
	session.reset_refill = time.tick_add(time.tick_now(), -2 * time.Second)
	h2_refill(&session)
	testing.expect_value(t, left(&session), 2 * H2_RESET_REFILL)
	session.reset_refill = time.tick_add(time.tick_now(), -time.Hour)
	h2_refill(&session)
	testing.expect_value(t, left(&session), H2_RESET_BURST)
}

// Targets no handler expects are answered 400, an over-limit content-length
// 413, and neither reaches the handler nor resets the stream.
@(test)
h2_empty_target_and_oversized_length_are_answered_without_the_handler :: proc(t: ^testing.T) {
	state: H2W_Server
	h2w_run(t, &state, proc(t: ^testing.T, state: ^H2W_Server, peer: ^H2W_Peer) {
		wire: [dynamic]u8
		defer delete(wire)
		h2w_headers(&wire, 1, true, {{":method", "GET"}, {":scheme", "ftp"}, {":authority", "localhost"}, {":path", ""}})
		h2w_headers(&wire, 3, true, {{":method", "CONNECT"}, {":authority", "localhost:443"}})
		h2w_headers(
			&wire,
			5,
			false,
			{{":method", "POST"}, {":scheme", "https"}, {":authority", "localhost"}, {":path", "/echo"}, {"content-length", "999999"}},
		)
		if !testing.expect(t, h2w_preface(peer) && h2w_send(peer, wire[:])) {
			return
		}
		statuses: [3]int
		seen := 0
		for seen < 3 {
			frame, ok := h2w_next(peer)
			if !ok {
				break
			}
			if !testing.expect(t, frame.kind != 3, "malformed request was reset instead of answered") {
				return
			}
			if frame.kind == 1 && frame.stream <= 5 {
				statuses[frame.stream / 2] = h2w_status(frame)
				seen += 1
			}
		}
		testing.expect_value(t, seen, 3)
		testing.expect_value(t, statuses[0], 400)
		testing.expect_value(t, statuses[1], 400)
		// 413 is not in the static table, so it is a literal: neither 200 nor absent.
		testing.expect_value(t, statuses[2], 0)
		testing.expect_value(t, sync.atomic_load(&state.handled), 0)
	})
}

// 100 response headers are within the request-side header count limit and
// must be delivered; a section that cannot be represented becomes a 500.
@(test)
h2_large_response_header_sets_are_delivered_or_answered_500 :: proc(t: ^testing.T) {
	state: H2W_Server
	h2w_run(t, &state, proc(t: ^testing.T, state: ^H2W_Server, peer: ^H2W_Peer) {
		wire: [dynamic]u8
		defer delete(wire)
		h2w_get(&wire, 1, "/many")
		h2w_get(&wire, 3, "/huge")
		if !testing.expect(t, h2w_preface(peer) && h2w_send(peer, wire[:])) {
			return
		}
		statuses: [2]int
		seen := 0
		for seen < 2 {
			frame, ok := h2w_next(peer)
			if !ok {
				break
			}
			if !testing.expect(t, frame.kind != 3, "large header set was reset instead of answered") {
				return
			}
			if frame.kind == 1 && frame.stream <= 3 {
				statuses[frame.stream / 2] = h2w_status(frame)
				seen += 1
			}
		}
		testing.expect_value(t, seen, 2)
		testing.expect_value(t, statuses[0], 200)
		testing.expect_value(t, statuses[1], 500)
	})
}

// The body buffer follows received bytes. With a large application limit a
// HEADERS frame alone used to commit the whole limit per stream.
@(test)
h2_request_body_buffer_grows_with_received_data :: proc(t: ^testing.T) {
	request := new(H2_Request)
	defer free(request)
	task := &request.task
	init_connection_arena(task)
	defer release_task_storage(task)
	request.limit = 64 * 1024 * 1024
	testing.expect_value(t, len(task.request.body), 0)
	testing.expect(t, h2_request_body_reserve(request, 10))
	testing.expect_value(t, len(task.request.body), H2_BODY_INITIAL)
	copy(task.request.body, "0123456789")
	request.body_len = 10
	testing.expect(t, h2_request_body_reserve(request, H2_BODY_INITIAL + 1))
	testing.expect_value(t, len(task.request.body), 2 * H2_BODY_INITIAL)
	testing.expect_value(t, string(task.request.body[:10]), "0123456789")
	testing.expect(t, h2_request_body_reserve(request, 100_000))
	testing.expect(t, len(task.request.body) >= 100_000 && len(task.request.body) < 1024 * 1024)
	// A known content-length never reserves beyond itself.
	request.limit = 5000
	request.body_len = 0
	task.request.body = nil
	testing.expect(t, h2_request_body_reserve(request, 4097))
	testing.expect_value(t, len(task.request.body), 4097)
	testing.expect(t, h2_request_body_reserve(request, 4098))
	testing.expect_value(t, len(task.request.body), 5000)
}

@(test)
h2_request_body_is_assembled_across_data_frames :: proc(t: ^testing.T) {
	state := H2W_Server {
		limit = 1,
	}
	h2w_run(t, &state, proc(t: ^testing.T, state: ^H2W_Server, peer: ^H2W_Peer) {
		SIZE :: 3 * H2_BODY_INITIAL + 17
		body := make([]u8, SIZE)
		defer delete(body)
		for &byte, i in body {
			byte = u8('A' + i % 26)
		}
		wire: [dynamic]u8
		defer delete(wire)
		h2w_headers(&wire, 1, false, {{":method", "POST"}, {":scheme", "https"}, {":authority", "localhost"}, {":path", "/echo"}})
		for at := 0; at < SIZE; at += 1000 {
			end := min(SIZE, at + 1000)
			h2w_frame(&wire, 0, 0x1 if end == SIZE else 0, 1, body[at:end])
		}
		if !testing.expect(t, h2w_preface(peer) && h2w_send(peer, wire[:])) {
			return
		}
		received := make([]u8, SIZE)
		defer delete(received)
		count := 0
		for {
			frame, ok := h2w_next(peer)
			if !ok || frame.kind == 3 {
				break
			}
			if frame.kind == 0 && frame.stream == 1 {
				count += copy(received[count:], frame.payload)
				if frame.flags & 1 != 0 {
					break
				}
			}
		}
		if testing.expect_value(t, count, SIZE) {
			testing.expect(t, string(received) == string(body), "echoed body differs from the request body")
		}
	})
}

// A response with trailers ends its stream with a second field section.
@(test)
h2_response_trailers_follow_the_body :: proc(t: ^testing.T) {
	state: H2W_Server
	h2w_run(t, &state, proc(t: ^testing.T, state: ^H2W_Server, peer: ^H2W_Peer) {
		wire: [dynamic]u8
		defer delete(wire)
		h2w_get(&wire, 1, "/trailers")
		if !testing.expect(t, h2w_preface(peer) && h2w_send(peer, wire[:])) {
			return
		}
		status, sections, data := 0, 0, 0
		ended_by: u8
		for {
			frame, ok := h2w_next(peer)
			if !ok {
				break
			}
			if frame.stream != 1 {
				continue
			}
			if !testing.expect(t, frame.kind != 3, "a response with trailers was reset") {
				return
			}
			if frame.kind == 1 {
				sections += 1
				if sections == 1 {
					status = h2w_status(frame)
				}
			}
			if frame.kind == 0 {
				data += len(frame.payload)
			}
			if frame.flags & 0x1 != 0 && frame.kind <= 1 {
				ended_by = frame.kind
				break
			}
		}
		testing.expect_value(t, status, 200)
		testing.expect_value(t, data, 4)
		testing.expect_value(t, sections, 2)
		testing.expect_value(t, ended_by, 1)
	})
}

// Streams armed together expire together. Resetting the first must not hand the
// transport a write budget taken from the next stream's deadline, microseconds
// away: that write timed out and dropped the connection after one or two
// resets, without a GOAWAY, and every other stream on it was lost.
@(test)
h2_streams_expiring_together_are_all_reset_and_the_connection_survives :: proc(t: ^testing.T) {
	state := H2W_Server {
		body     = 400 * time.Millisecond,
		observed = true,
	}
	h2w_run(t, &state, proc(t: ^testing.T, state: ^H2W_Server, peer: ^H2W_Peer) {
		STALLED :: 32
		wire: [dynamic]u8
		defer delete(wire)
		for i in 0 ..< STALLED {
			post := [][2]string{{":method", "POST"}, {":scheme", "https"}, {":authority", "localhost"}, {":path", "/echo"}}
			h2w_headers(&wire, u32(2 * i + 1), false, post)
		}
		if !testing.expect(t, h2w_preface(peer) && h2w_send(peer, wire[:])) {
			return
		}
		reset := make(map[u32]bool)
		defer delete(reset)
		for len(reset) < STALLED {
			frame, ok := h2w_next(peer, true)
			if !testing.expect(t, ok, "connection ended before every stalled stream was reset") {
				break
			}
			if !testing.expect(t, frame.kind != 7, "GOAWAY before every stalled stream was reset") {
				break
			}
			if frame.kind == 3 {
				reset[frame.stream] = true
			}
		}
		testing.expect_value(t, len(reset), STALLED)
		clear(&wire)
		h2w_get(&wire, 2 * STALLED + 1, "/")
		if !testing.expect(t, h2w_send(peer, wire[:])) {
			return
		}
		answered := false
		for !answered {
			frame, ok := h2w_next(peer, true)
			if !ok {
				break
			}
			if frame.stream == 2 * STALLED + 1 && frame.kind == 1 {
				testing.expect_value(t, h2w_status(frame), 200)
				answered = true
			}
		}
		testing.expect(t, answered, "the connection did not serve a request after the resets")
	})
}

// A response stream used to be released as soon as its last frame was queued.
// To a peer that grants no flow-control credit the queued body never left, the
// stream was never reset and the owner polled it until the connection closed.
// The stream is now held until its output drains or its response deadline
// passes, then reset, and the connection keeps serving.
@(test)
h2_zero_window_response_is_reset_at_its_deadline :: proc(t: ^testing.T) {
	state: H2W_Server
	h2w_run(t, &state, proc(t: ^testing.T, state: ^H2W_Server, peer: ^H2W_Peer) {
		wire: [dynamic]u8
		defer delete(wire)
		h2w_get(&wire, 1, "/refuse")
		// SETTINGS_INITIAL_WINDOW_SIZE = 0
		if !testing.expect(t, h2w_preface(peer, []u8{0, 4, 0, 0, 0, 0}) && h2w_send(peer, wire[:])) {
			return
		}
		started := time.tick_now()
		resumes_started: u64
		reset := false
		for !reset {
			frame, ok := h2w_next(peer, true)
			if !testing.expect(t, ok, "connection ended before the starved stream was reset") {
				return
			}
			if !testing.expect(t, frame.kind != 7, "GOAWAY before the starved stream was reset") {
				return
			}
			testing.expect(t, frame.kind != 0 || len(frame.payload) == 0, "body sent without flow-control credit")
			if frame.kind == 1 && frame.stream == 1 {
				resumes_started = h2w_resumes(state)
			}
			if frame.kind == 3 && frame.stream == 1 {
				testing.expect_value(t, h2w_code(frame), u32(8))
				reset = true
			}
		}
		elapsed := time.tick_since(started)
		resumes := h2w_resumes(state) - resumes_started
		testing.expectf(t, elapsed >= H2W_RESPONSE / 2, "reset after %v, before the response deadline", elapsed)
		testing.expectf(t, elapsed < H2W_RESPONSE + time.Second, "reset after %v", elapsed)
		// Waiting for credit is not spinning on it: at most the owner's
		// millisecond timer wakes the connection.
		testing.expectf(t, resumes > 0 && f64(resumes) < 3 * f64(elapsed / time.Millisecond), "%d owner turns while waiting %v for credit", resumes, elapsed)

		// A response without a body needs no credit: it ends.
		clear(&wire)
		h2w_headers(&wire, 3, true, {{":method", "HEAD"}, {":scheme", "https"}, {":authority", "localhost"}, {":path", "/"}})
		if !testing.expect(t, h2w_send(peer, wire[:])) {
			return
		}
		ended := false
		for !ended {
			frame, ok := h2w_next(peer, true)
			if !testing.expect(t, ok && frame.kind != 7, "bodiless response on a starved stream never ended") {
				return
			}
			testing.expect(t, frame.kind != 3, "bodiless response on a starved stream was reset")
			ended = frame.stream == 3 && frame.kind <= 1 && frame.flags & 1 != 0
		}

		// The connection still serves a stream the peer does grant credit to.
		clear(&wire)
		h2w_get(&wire, 5, "/")
		h2w_frame(&wire, 8, 0, 5, []u8{0, 0, 0, 100})
		if !testing.expect(t, h2w_send(peer, wire[:])) {
			return
		}
		answered, body := false, false
		for !body {
			frame, ok := h2w_next(peer, true)
			if !ok {
				break
			}
			if frame.stream == 5 && frame.kind == 1 {
				testing.expect_value(t, h2w_status(frame), 200)
				answered = true
			}
			if frame.stream == 5 && frame.kind == 0 && frame.flags & 1 != 0 {
				body = true
			}
		}
		testing.expect(t, answered && body, "the connection did not serve a request after the reset")
	})
}

// Owner turns of the connection that served /refuse.
h2w_resumes :: proc(state: ^H2W_Server) -> u64 {
	task := sync.atomic_load(&state.refused)
	if task == nil || task.tls_state == nil {
		return 0
	}
	return sync.atomic_load(&task.tls_state.executor.resumes)
}

// A DATA event a full tunnel cannot take yet used to stay borrowed across owner
// turns. It is now deferred: no borrow outlives the pass, the engine queue
// keeps the event at its head and its credit stays withheld.
@(test)
h2_event_for_a_full_tunnel_is_deferred_not_held :: proc(t: ^testing.T) {
	session: HTTP2_Session
	session.limits = h2_make_limits(8)
	if !testing.expect(
		t,
		h2.connection_init(&session.engine, {role = .Server, limits = session.limits}, {max_stream_capacity = 16}, context.allocator).kind ==
		.None,
	) {
		return
	}
	session.engine_ready = true
	defer h2.connection_destroy(&session.engine)
	upgrades: [1]^H2_Upgrade
	session.upgrades = upgrades[:]
	task: Connection_Task
	task.http2 = &session

	wire: [dynamic]u8
	defer delete(wire)
	append(&wire, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
	h2w_frame(&wire, 4, 0, 0, nil)
	h2w_headers(&wire, 1, false, {{":method", "POST"}, {":scheme", "https"}, {":authority", "localhost"}, {":path", "/"}})
	h2w_frame(&wire, 0, 0, 1, []u8{'a', 'b', 'c'})
	at := 0
	for _ in 0 ..< 64 {
		fed := h2.connection_feed(&session.engine, wire[at:], 0)
		if !testing.expect_value(t, fed.error.kind, h2.Error_Kind.None) {
			return
		}
		at += fed.consumed
		for {
			view, borrowed := h2.connection_output_front(&session.engine)
			if !borrowed {
				break
			}
			_ = h2.connection_output_advance(&session.engine, view.token, len(view.bytes))
		}
		if at == len(wire) && fed.status != .Yield {
			break
		}
	}
	if !testing.expect_value(t, at, len(wire)) {
		return
	}

	// Everything ahead of the DATA event, the stream's HEADERS among it.
	handle: h2.Stream_Handle
	for handle.stream_id == 0 {
		event, polled := h2.connection_poll(&session.engine)
		if !testing.expect(t, polled, "no HEADERS event") {
			return
		}
		if headers, is_headers := event.payload.(h2.Headers_Event); is_headers {
			handle = headers.stream
		}
		_ = h2.connection_event_release(&session.engine, event.token)
	}

	// A tunnel on that stream whose input queue is full.
	tunnel := H2_Upgrade {
		handle      = handle,
		accepted    = true,
		input_count = H2_BODY_CHUNKS,
	}
	upgrades[0] = &tunnel
	defer upgrades[0] = nil

	for _ in 0 ..< 2 {
		h2_pump_events(&task)
		stats, _ := h2.connection_stats(&session.engine)
		testing.expect(t, !stats.event_borrowed, "the event stays borrowed after the owner pass")
	}

	// Once the tunnel has room the same event is next.
	event, polled := h2.connection_poll(&session.engine)
	if testing.expect(t, polled, "the deferred event was lost") {
		data, is_data := event.payload.(h2.Data_Event)
		testing.expect(t, is_data && data.stream == handle, "the deferred event is not the tunnel's DATA")
		_ = h2.connection_event_release(&session.engine, event.token)
	}
}

// A client may keep uploading after an early 413 until it reads the answer.
// Its late DATA advances no request, but it is not abuse: the connection must
// not spend its unproductive-frame allowance on it and end the client with
// ENHANCE_YOUR_CALM. Both an over-limit content-length and a body that
// outgrows the limit are covered.
@(test)
h2_upload_after_an_early_413_is_reset_with_no_error_and_in_flight_data_is_tolerated :: proc(t: ^testing.T) {
	state: H2W_Server
	h2w_run(t, &state, proc(t: ^testing.T, state: ^H2W_Server, peer: ^H2W_Peer) {
		// Data already in flight when the reset reaches the client: a full
		// initial window of 1 KB frames, as a real client sends it.
		LATE :: 48
		if !testing.expect(t, h2w_preface(peer)) {
			return
		}
		wire: [dynamic]u8
		defer delete(wire)
		filler: [1024]u8

		for stream in ([]u32{1, 3}) {
			clear(&wire)
			post := [][2]string{{":method", "POST"}, {":scheme", "https"}, {":authority", "localhost"}, {":path", "/echo"}}
			if stream == 1 {
				h2w_headers(&wire, stream, false, {post[0], post[1], post[2], post[3], {"content-length", "999999"}})
			} else {
				h2w_headers(&wire, stream, false, post)
				for _ in 0 ..< 5 {
					h2w_frame(&wire, 0, 0, stream, filler[:])
				}
			}
			if !testing.expect(t, h2w_send(peer, wire[:])) {
				return
			}
			rejected := false
			for !rejected {
				frame, ok := h2w_next(peer, true)
				if !testing.expectf(t, ok && frame.kind != 7, "stream %d: connection ended before the 413", stream) {
					return
				}
				rejected = frame.kind == 1 && frame.stream == stream
			}

			// Frames already in flight when the 413 arrived, then a PING to
			// learn that the server has read them all.
			clear(&wire)
			for _ in 0 ..< LATE {
				h2w_frame(&wire, 0, 0, stream, filler[:])
			}
			h2w_frame(&wire, 6, 0, 0, []u8{1, 2, 3, 4, 5, 6, 7, u8(stream)})
			if !testing.expect(t, h2w_send(peer, wire[:])) {
				return
			}
			acknowledged, reset := false, false
			for !acknowledged {
				frame, ok := h2w_next(peer, true)
				if !testing.expectf(t, ok, "stream %d: connection ended after late DATA", stream) {
					return
				}
				if !testing.expectf(t, frame.kind != 7, "stream %d: GOAWAY(%d) after late DATA", stream, h2w_code(frame)) {
					return
				}
				if frame.kind == 3 && frame.stream == stream {
					testing.expectf(t, h2w_code(frame) == 0, "stream %d: reset with %d, not NO_ERROR", stream, h2w_code(frame))
					reset = true
				}
				acknowledged = frame.kind == 6 && frame.flags & 1 != 0 && frame.payload[7] == u8(stream)
			}
			// RFC 9113 section 8.1: the server stops a body it will not read.
			testing.expectf(t, reset, "stream %d: no RST_STREAM(NO_ERROR) after the early 413", stream)
		}

		// And the connection still serves.
		clear(&wire)
		h2w_get(&wire, 5, "/")
		if !testing.expect(t, h2w_send(peer, wire[:])) {
			return
		}
		answered := false
		for !answered {
			frame, ok := h2w_next(peer, true)
			if !ok || frame.kind == 7 {
				break
			}
			answered = frame.kind == 1 && frame.stream == 5 && h2w_status(frame) == 200
		}
		testing.expect(t, answered, "the connection did not serve a request after the rejected uploads")
		testing.expect_value(t, sync.atomic_load(&state.handled), 1)
	})
}
