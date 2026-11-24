package saba_offload_test

import receipts "../../testdata/ui_store"
import "core:crypto/tls"
import "core:crypto/tls/credentials"
import store "core:crypto/tls/credentials/store"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import pool "shared:async/offload"
import h2 "shared:http/v2"
import "shared:http/v2/hpack"
import h3 "shared:http/v3"
import server "shared:saba/core"
import adapter "shared:saba/offload"

PROGRESS_TIMEOUT :: 5 * time.Second
Progress_Protocol :: enum {
	HTTP2,
	HTTP3,
}

Progress_Server :: struct {
	config:           server.Server,
	control:          server.Server_Control,
	pool:             pool.Pool,
	started, release: sync.Sema,
	drops:            int,
	store:            ^receipts.State,
	ok:               bool,
}

progress_handler :: proc(
	data: rawptr,
	conn: ^server.Connection,
	request: ^server.Request,
) -> server.Response {
	state := cast(^Progress_Server)data
	switch request.path {
	case "/fast":
		return {status = .OK, body = transmute([]u8)string("fast")}
	case "/slow":
		work := pool.Work {
			data = state,
			run = proc(p: rawptr, _: pool.Work_Context) -> bool {
				s := cast(^Progress_Server)p
				sync.sema_post(&s.started)
				sync.sema_wait(&s.release)
				return true
			},
			drop = proc(p: rawptr) {sync.atomic_add(&(cast(^Progress_Server)p).drops, 1)},
		}
		response, accepted := adapter.response(
			&state.pool,
			&work,
			proc(_: rawptr, allocator: mem.Allocator) -> (server.Response, bool) {
				body, error := strings.clone("slow", allocator)
				return {status = .OK, body = transmute([]u8)body}, error == nil
			},
		)
		if accepted {
			return response
		}
		return {status = .Service_Unavailable}
	}
	if state.store != nil {
		return receipts.handle(state.store, conn, request)
	}
	return {status = .Not_Found}
}

progress_fixture :: proc(
	t: ^testing.T,
	state: ^Progress_Server,
	protocol: Progress_Protocol,
	exchange: proc(
		t: ^testing.T,
		state: ^Progress_Server,
		endpoint: net.Endpoint,
		roots: ^tls.Root_Pool,
	),
) {
	testing.set_fail_timeout(t, 30 * time.Second)
	cert := #load("../testdata/tls/localhost.pem")
	credential, created := credentials.create(
		cert,
		#load("../testdata/tls/rsa2048.pem"),
		{},
		context.allocator,
	)
	assert(created == .None)
	identity, allocated := store.create({}, context.allocator)
	assert(allocated.kind == .None && store.replace(identity, &credential).kind == .None)
	defer store.destroy(&identity)
	roots: tls.Root_Pool
	assert(tls.root_pool_parse(&roots, cert).kind == .None)
	defer tls.root_pool_destroy(&roots)

	assert(pool.init(&state.pool, {workers = 1, capacity = 1}) == .None)
	defer {
		pool.shutdown(&state.pool)
		assert(pool.join(&state.pool) == .None && pool.destroy(&state.pool) == .None)
		testing.expect_value(t, state.drops, 1 if state.store == nil else 0)
	}
	tls_config := server.TLS_Config {
		store = identity,
	}
	state.config = {
		address = "127.0.0.1",
		workers = 1,
		handler = progress_handler,
		handler_data = state,
		control = &state.control,
		tls = &tls_config,
		timeouts = {response = 15 * time.Second},
	}
	if protocol == .HTTP3 {
		state.config.http3 = {
			enabled     = true,
			endpoint    = {net.IP4_Loopback, 0},
			credentials = identity,
		}
	}

	worker := thread.create_and_start_with_poly_data(
		state,
		proc(s: ^Progress_Server) {s.ok = server.serve(s.config)},
	)
	assert(worker != nil)
	defer {
		sync.sema_post(&state.release)
		server.stop_server(&state.control)
		thread.join(worker)
		thread.destroy(worker)
		testing.expect(t, state.ok)
	}
	until := time.tick_add(time.tick_now(), PROGRESS_TIMEOUT)
	for !server.server_ready(&state.control) && time.tick_since(until) < 0 {
		thread.yield()
	}
	endpoint, ready := server.server_endpoint(&state.control)
	if protocol == .HTTP3 {
		endpoint, ready = server.server_http3_endpoint(&state.control)
	}
	if testing.expect(
		t,
		ready && endpoint.port > 0,
		"server did not publish a loopback endpoint",
	) {
		exchange(t, state, endpoint, &roots)
	}
}

// One exchange opens one QUIC connection. The test thread only opens the fast
// connection after the slow job owns the sole offload worker.
progress_h3_exchange :: proc(
	endpoint: net.Endpoint,
	roots: ^tls.Root_Pool,
	path: string,
) -> h3.Client_Result {
	return h3.client_exchange_request(
		endpoint,
		"localhost",
		{method = "GET", target = path, authority = "localhost"},
		roots.roots[:roots.count],
		time.time_add(time.now(), 2 * PROGRESS_TIMEOUT),
	)
}

@(test)
one_worker_serves_fast_h3_peer_while_offload_is_running :: proc(t: ^testing.T) {
	state: Progress_Server
	progress_fixture(
		t,
		&state,
		.HTTP3,
		proc(
			t: ^testing.T,
			state: ^Progress_Server,
			endpoint: net.Endpoint,
			roots: ^tls.Root_Pool,
		) {
			Slow_Client :: struct {
				endpoint: net.Endpoint,
				roots:    ^tls.Root_Pool,
				result:   h3.Client_Result,
			}
			slow := Slow_Client {
				endpoint = endpoint,
				roots    = roots,
			}
			client := thread.create_and_start_with_poly_data(&slow, proc(c: ^Slow_Client) {
					c.result = progress_h3_exchange(c.endpoint, c.roots, "/slow")
				})
			assert(client != nil)
			defer {
				sync.sema_post(&state.release)
				thread.join(client)
				thread.destroy(client)
				testing.expect_value(t, slow.result.error, .None)
				testing.expect_value(t, slow.result.status, 200)
				testing.expect_value(t, string(slow.result.body[:slow.result.body_len]), "slow")
			}
			if !testing.expect(
				t,
				sync.sema_wait_with_timeout(&state.started, PROGRESS_TIMEOUT),
				"slow job did not start",
			) {
				return
			}
			fast := progress_h3_exchange(endpoint, roots, "/fast")
			testing.expect_value(t, fast.error, .None)
			testing.expect_value(t, fast.status, 200)
			testing.expect_value(t, string(fast.body[:fast.body_len]), "fast")
			testing.expect(t, !thread.is_done(client), "slow peer finished before release")
		},
	)
}

h2_send :: proc(conn: ^tls.Conn, bytes: []u8) -> bool {
	n, error := tls.write(conn, bytes)
	return error.kind == .None && n == len(bytes)
}

h2_request :: proc(
	conn: ^tls.Conn,
	encoder: ^hpack.Encoder,
	stream_id: u32,
	path: string,
	body := "",
) -> bool {
	headers, wire: [256]u8
	fields := []hpack.Field {
		{name = ":method", value = "PATCH" if len(body) > 0 else "GET"},
		{name = ":scheme", value = "https"},
		{name = ":authority", value = "localhost"},
		{name = ":path", value = path},
	}
	size, packed := hpack.encoder_encode(encoder, headers[:], fields)
	if packed.kind != .None {
		return false
	}
	n, encoded := h2.headers_frame_encode(
		wire[:],
		stream_id,
		{fragment = headers[:size], end_stream = len(body) == 0, end_headers = true},
	)
	if encoded.kind != .None || !h2_send(conn, wire[:n]) {
		return false
	}
	if len(body) == 0 {
		return true
	}
	n, encoded = h2.data_frame_encode(
		wire[:],
		stream_id,
		{data = transmute([]u8)body, end_stream = true},
	)
	return encoded.kind == .None && h2_send(conn, wire[:n])
}

h2_read_exact :: proc(conn: ^tls.Conn, bytes: []u8) -> bool {
	for at := 0; at < len(bytes); {
		n, error := tls.read(conn, bytes[at:])
		if error.kind != .None || n == 0 {
			return false
		}
		at += n
	}
	return true
}

// Check the whole response through END_STREAM. Any response frame for the
// other request is an ordering failure while the slow job is gated.
h2_expect_body :: proc(conn: ^tls.Conn, stream_id: u32, body: string) -> bool {
	header_wire: [h2.FRAME_HEADER_SIZE]u8
	payload: [h2.INITIAL_MAX_FRAME_SIZE]u8
	at := 0
	for h2_read_exact(conn, header_wire[:]) {
		header, decoded := h2.frame_header_decode(header_wire[:], len(payload))
		if decoded.error.kind != .None || !h2_read_exact(conn, payload[:header.length]) {
			return false
		}
		#partial switch header.kind {
		case .Settings:
			if header.flags & h2.FLAG_ACK == 0 {
				n, encoded := h2.settings_frame_encode(header_wire[:], nil, true)
				if encoded.kind != .None || !h2_send(conn, header_wire[:n]) {
					return false
				}
			}
		case .Headers, .Data:
			if header.stream_id != stream_id {
				return false
			}
			if header.kind == .Data {
				data, error := h2.data_payload_decode(
					{header = header, payload = payload[:header.length]},
				)
				if error.kind != .None ||
				   len(data.data) > len(body) - at ||
				   string(data.data) != body[at:][:len(data.data)] {
					return false
				}
				at += len(data.data)
			}
			if header.flags & h2.FLAG_END_STREAM != 0 {
				return at == len(body)
			}
		case .Goaway, .Rst_Stream:
			return false
		}
	}
	return false
}

// Both cases open exactly one TLS connection. A response for the blocked
// stream during h2_expect_body on stream 3 is a test failure.
h2_progress_exchange :: proc(
	t: ^testing.T,
	state: ^Progress_Server,
	endpoint: net.Endpoint,
	roots: ^tls.Root_Pool,
) {
	conn: tls.Conn
	dialed := tls.dial(
		&conn,
		"127.0.0.1",
		endpoint.port,
		{
			server_name = "localhost",
			root_cas = roots.roots[:roots.count],
			alpn_protocols = {"h2"},
			handshake_timeout = PROGRESS_TIMEOUT,
		},
	)
	if !testing.expect_value(t, dialed.kind, .None) {
		return
	}
	defer _ = tls.abort(&conn)
	deadline := time.time_add(time.now(), 2 * PROGRESS_TIMEOUT)
	assert(tls.set_deadline(&conn, deadline).kind == .None)
	if !testing.expect_value(t, tls.connection_state(&conn).negotiated_protocol, "h2") {
		return
	}
	encoder: hpack.Encoder
	assert(hpack.encoder_init(&encoder, hpack.DEFAULT_LIMITS, 0, context.allocator).kind == .None)
	defer hpack.encoder_destroy(&encoder)
	path, submission, expected := string("/slow"), string(""), string("slow")
	if state.store != nil {
		path = "/api/items/42"
		submission = `{"operationId":"h2-save","expectedRevision":1,"title":"from h2"}`
		expected = `{"id":"42","title":"from h2","revision":2}`
	}
	settings: [h2.FRAME_HEADER_SIZE]u8
	size, encoded := h2.settings_frame_encode(settings[:], nil)
	assert(encoded.kind == .None)
	if !testing.expect(
		   t,
		   h2_send(&conn, transmute([]u8)string(h2.CLIENT_PREFACE)) &&
		   h2_send(&conn, settings[:size]),
	   ) ||
	   !testing.expect(t, h2_request(&conn, &encoder, 1, path, submission)) ||
	   !testing.expect(
			   t,
			   sync.sema_wait_with_timeout(&state.started, PROGRESS_TIMEOUT),
			   "slow job did not start",
		   ) {
		return
	}
	if !testing.expect(t, h2_request(&conn, &encoder, 3, "/fast")) ||
	   !testing.expect(
			   t,
			   h2_expect_body(&conn, 3, "fast"),
			   "fast stream did not complete while slow job was held",
		   ) {
		return
	}
	if state.store != nil {
		if !testing.expect(
			t,
			h2_request(&conn, &encoder, 5, "/api/items/42/operations/h2-save") &&
			h2_expect_body(&conn, 5, `{"state":"pending"}`),
			"the blocked write must already own its durable reservation",
		) {
			return
		}
	}
	sync.sema_post(&state.release)
	testing.expect(
		t,
		h2_expect_body(&conn, 1, expected),
		"slow stream did not resume after offload completion",
	)
	if state.store != nil {
		testing.expect(
			t,
			h2_request(&conn, &encoder, 7, "/api/items/42/operations/h2-save") &&
			h2_expect_body(
				&conn,
				7,
				`{"state":"terminal","status":200,"body":{"id":"42","title":"from h2","revision":2}}`,
			),
			"the released write must have its matching terminal receipt",
		)
	}
}

@(test)
one_worker_serves_fast_h2_stream_while_offload_is_running :: proc(t: ^testing.T) {
	state: Progress_Server
	progress_fixture(t, &state, .HTTP2, h2_progress_exchange)
}

@(test)
one_worker_serves_fast_h2_stream_during_durable_save :: proc(t: ^testing.T) {
	directory, error := os.make_directory_temp("", "saba-h2-save-*", context.temp_allocator)
	assert(error == nil)
	defer _ = os.remove_all(directory)
	storage: receipts.State
	assert(
		receipts.open(
			&storage,
			fmt.tprintf("%s/store.db", directory),
			proc(_: ^server.Request) -> receipts.Identity {return {"tenant", "alice", .Allowed}},
			proc(tenant, caller: string) -> bool {return tenant == "tenant" && caller == "alice"},
		),
	)
	defer receipts.close(&storage)
	assert(receipts.seed(&storage, "tenant"))
	state := Progress_Server {
		store = &storage,
	}
	storage.checkpoint_data = &state
	storage.checkpoint = proc(data: rawptr, stage: receipts.Stage, _: string) {
		if stage == .Reserved {
			s := cast(^Progress_Server)data
			sync.sema_post(&s.started)
			sync.sema_wait(&s.release)
		}
	}
	progress_fixture(t, &state, .HTTP2, h2_progress_exchange)
}
