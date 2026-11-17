package main

import core "shared:saba/core"
import ws "shared:saba/websocket"
import surf "shared:surf"
import codec "shared:websocket"
import tls "core:crypto/tls"
import credentials "core:crypto/tls/credentials"
import store "core:crypto/tls/credentials/store"
import rt "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import h3 "shared:http/v3"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"
import "core:strconv"
import async "shared:async"
import owned "core:mem/owned"

State :: struct {
	control:                                               core.Server_Control,
	config:                                                core.Server,
	tls_config:                                            core.TLS_Config,
	credentials:                                           ^store.Store,
	auth:                                                  tls.Client_Auth_Config,
	roots:                                                 tls.Root_Pool,
	opened, dropped, messages, http, resets, stream_drops: u64,
}
Slow :: struct {
	state: ^State,
	stage: int,
}
slow_next :: proc(data: rawptr, io: ^core.Stream_IO) -> core.Stream_Step {
	slow := cast(^Slow)data

	if slow.stage == 0 {
		slow.stage = 1
		_ = core.stream_wait(io, async.deadline_after(io.runtime, 50 * time.Millisecond))
		return .Waiting
	}

	if slow.stage >= 3 {
		return .Done
	}

	text := "http-" if slow.stage == 1 else "ok"
	chunk, e := owned.copy_bounded(transmute([]u8)text, len(text), io.backing_allocator)

	if e.kind != .None {
		return .Failed
	}

	if core.stream_submit(io, &chunk) != .Accepted {
		owned.destroy(&chunk)
		return .Failed
	}

	slow.stage += 1

	return .Chunk
}
slow_drop :: proc(data: rawptr) {
	slow := cast(^Slow)data
	sync.atomic_add(&slow.state.stream_drops, 1)
	free(slow, rt.heap_allocator())
}
Peer :: struct {
	state: ^State,
}
origin :: proc(_: rawptr, _: ^core.Request, value: string, present: bool) -> bool {
	return present && value == "https://allowed.invalid"
}
protocol :: proc(_: rawptr, _: ^core.Request, offered: []string) -> (string, bool) {
	for p in offered {
		if p == "chat.v2" {
			return p, true
		}
	}; return "", false
}
opened :: proc(data: rawptr, io: ^ws.IO) {
	peer := cast(^Peer)data
	assert(ws.subprotocol(io) == "chat.v2")
	sync.atomic_add(&peer.state.opened, 1)
}
message :: proc(data: rawptr, io: ^ws.IO, opcode: codec.Opcode, payload: []u8) {
	peer := cast(^Peer)data
	sync.atomic_add(&peer.state.messages, 1)
	assert(ws.send(io, opcode, payload) == .Accepted)
}
closed :: proc(data: rawptr, event: ^ws.Close_Event) {
	peer := cast(^Peer)data

	if event.transport.kind == .Cancelled {
		sync.atomic_add(&peer.state.resets, 1)
	}
}
drop :: proc(data: rawptr) {
	peer := cast(^Peer)data
	sync.atomic_add(&peer.state.dropped, 1)
	free(peer, rt.heap_allocator())
}
route :: proc(data: rawptr, connection: ^core.Connection, request: ^core.Request) -> core.Response {
	state := cast(^State)data

	if request.protocol != "" && request.protocol != "websocket" {
		return {status = .Not_Implemented}
	}

	identity := core.tls_peer_identity(connection)

	if state.auth.mode == .Require {
		assert(identity.authenticated)
	}

	if request.path == "/socket" {
		assert(request.version == "HTTP/3" && request.protocol == "websocket")
		peer := new(Peer, rt.heap_allocator())
		peer.state = state
		response, error := ws.upgrade(
			request,
			{check_origin = origin, select_subprotocol = protocol, max_frame_bytes = 256 * 1024},
			{data = peer, on_open = opened, on_message = message, on_close = closed, drop = drop},
		)

		if error.kind != .None {
			free(peer, rt.heap_allocator())
		}

		return response
	}

	if request.path == "/global-drain" {
		h3.listener_drain(&connection._task.runtime.http3.live)
	}

	if request.path == "/inspect" {
		for p in connection._task.runtime.http3.live.peers {
			if p != nil {
				fmt.printf(
					"SERVER phase=%v dead=%v reason=%s state=%v\n",
					p.transport.phase,
					p.dead,
					p.reason,
					p.shutdown,
				)

				for b in p.transport.bufs {
					if b.used && b.id & 3 == 0 {
						fmt.printf(
							"SBUF id=%d n=%d fin=%v ack=%v recv=%d recvfin=%v reset=%v\n",
							b.id,
							b.n,
							b.fin,
							b.fin_acked,
							b.recv_n,
							b.recv_fin,
							b.recv_reset,
						)
					}
				}

				for slot in p.in_streams {
					if slot.used && slot.extended {
						fmt.printf(
							"SWS id=%d released=%v connect=%v/%v/%v/%v\n",
							slot.id,
							slot.released,
							slot.connect.app_done,
							slot.connect.local_fin,
							slot.connect.remote_fin,
							slot.connect.fin_sent,
						)
					}
				}
			}
		}
	}

	if request.path == "/drain" {
		for p in connection._task.runtime.http3.live.peers {
			if p != nil {
				for slot in p.in_streams {
					if slot.request.target == "/drain" && !slot.released {
						_ = h3.live_begin_shutdown(p)
					}
				}
			}
		}

		slow := new(Slow, rt.heap_allocator())
		slow.state = state
		sync.atomic_add(&state.http, 1)
		return {status = .OK, stream = {data = slow, next = slow_next, drop = slow_drop, content_length = 7}}
	}

	sync.atomic_add(&state.http, 1)
	text := make([]u8, 64, request.allocator)
	digits := "0123456789abcdef"

	for byte, i in identity.certificate_sha256 {
		text[i * 2] = digits[byte >> 4]
		text[i * 2 + 1] = digits[byte & 15]
	}

	headers := make([]core.Header, 1, request.allocator)
	headers[0] = {"x-client-identity", string(text)}

	return {status = .OK, headers = headers, body = transmute([]u8)string("http-ok")}
}
server :: proc(cert_path, key_path: string, root_path: string = "") {
	state: State
	cert, ce := os.read_entire_file(cert_path, context.allocator)
	assert(ce == nil)
	defer delete(cert)
	key, ke := os.read_entire_file(key_path, context.allocator)
	assert(ke == nil)
	defer delete(key)
	owner, e := credentials.create(cert, key, {}, context.allocator)
	assert(e == .None)
	state.credentials, _ = store.create({}, context.allocator)
	assert(state.credentials != nil)
	defer store.destroy(&state.credentials)
	assert(store.replace(state.credentials, &owner).kind == .None)
	state.tls_config = {
		store             = state.credentials,
		handshake_timeout = 2 * time.Second,
		close_timeout     = 200 * time.Millisecond,
	}

	if root_path != "" {
		assert(tls.root_pool_load_file(&state.roots, root_path).kind == .None)
		state.auth = {
			mode  = .Require,
			roots = state.roots.roots[:state.roots.count],
		}

		state.tls_config.client_auth = &state.auth
	}

	defer tls.root_pool_destroy(&state.roots)
	state.config = {
		port = 0,
		workers = 2,
		tls = &state.tls_config,
		handler = route,
		handler_data = &state,
		control = &state.control,
		http3 = {
			enabled = true,
			enable_connect_protocol = true,
			qpack = {table_capacity = 4096, blocked_streams = 4},
			endpoint = {net.IP4_Loopback, 0},
			credentials = state.credentials,
		},
		keep_alive = {enabled = true},
		resources = {connection_limits = {64 * mem.Megabyte, 8, 8}},
		timeouts = {header = 3 * time.Second, body = time.Second, response = 3 * time.Second, idle = 5 * time.Second},
		drain_timeout = 500 * time.Millisecond,
	}

	worker := thread.create_and_start_with_poly_data(&state, proc(s: ^State) {assert(core.serve(s.config))})
	assert(worker != nil)
	until := time.tick_add(time.tick_now(), 5 * time.Second)

	for !core.server_ready(&state.control) && time.tick_diff(time.tick_now(), until) > 0 {
		time.sleep(time.Millisecond)
	}

	endpoint, ready := core.server_http3_endpoint(&state.control)
	assert(ready)
	fmt.printf("READY %d\n", endpoint.port)
	os.flush(os.stdout)
	command: [1]u8
	_, _ = os.read(os.stdin, command[:])
	core.stop_server(&state.control)
	thread.join(worker)
	thread.destroy(worker)
	fmt.printf(
		"RESULT opened=%d dropped=%d messages=%d http=%d resets=%d stream_drops=%d\n",
		state.opened,
		state.dropped,
		state.messages,
		state.http,
		state.resets,
		state.stream_drops,
	)
	assert(state.opened == state.dropped)
}
client_shutdown :: proc(port, cert_path: string) {
	roots: tls.Root_Pool
	assert(tls.root_pool_load_file(&roots, cert_path).kind == .None)
	defer tls.root_pool_destroy(&roots)
	pool: h3.Pool
	defer h3.pool_close(&pool)
	http: surf.HTTP_Client
	assert(
		surf.http_client_init(&http, {tls = {root_cas = roots.roots[:roots.count]}, http3 = true, http3_pool = &pool, timeout = 5 * time.Second}, {}, context.allocator).kind ==
		.None,
	)
	defer surf.http_client_close(&http)
	url := fmt.aprintf("https://localhost:%s/socket", port)
	defer delete(url)
	tunnel: surf.HTTP3_Tunnel
	socket: surf.WebSocket_Conn
	assert(
		surf.websocket_http3_open(&http, &tunnel, &socket, url, {origin = "https://allowed.invalid", subprotocols = {"chat.v2"}}).kind ==
		.None,
	)
	owner := tunnel.wire.owner
	drain := fmt.aprintf("https://localhost:%s/drain", port)
	defer delete(drain)
	response, error := surf.http_client_exchange(&http, {method = .GET, url = drain})
	assert(error.kind == .None && string(response.body) == "http-ok")
	surf.response_destroy(&response)
	assert(surf.websocket_write_message(&socket, .Text, transmute([]u8)string("after-goaway")).kind == .None)
	buffer: [64]u8
	_, n, we := surf.websocket_read_message(&socket, buffer[:])
	assert(we.kind == .None && string(buffer[:n]) == "after-goaway")
	assert(owner.shutdown.received && tunnel.wire.owner == owner)
	health := fmt.aprintf("https://localhost:%s/health", port)
	defer delete(health)
	response, error = surf.http_client_exchange(&http, {method = .GET, url = health})
	assert(error.kind == .None && string(response.body) == "http-ok")
	surf.response_destroy(&response)
	used := 0

	for slot in pool.slots {
		if slot.used {
			used += 1
		}
	}

	assert(used >= 2 && tunnel.wire.owner == owner)
	assert(surf.websocket_close(&socket, 1000, "").kind == .None)
	deadline := time.time_add(time.now(), 3 * time.Second)

	for !h3.client_retire_ready(owner) && time.diff(time.now(), deadline) > 0 {
		_ = h3.pool_maintain(&pool, deadline)
	}

	if !h3.client_retire_ready(owner) {
		inspect := fmt.aprintf("https://localhost:%s/inspect", port)
		defer delete(inspect)
		result, _ := surf.http_client_exchange(&http, {method = .GET, url = inspect})
		surf.response_destroy(&result)
		fmt.printf(
			"RETIRE phase=%v dead=%v err=%v state=%v control=%d/%d pending=%d\n",
			owner.transport.phase,
			owner.dead,
			owner.err,
			owner.shutdown,
			owner.control.sent,
			owner.control.n,
			owner.pending_output.n,
		)

		for b in owner.transport.bufs {
			if b.used {
				fmt.printf(
					"BUF id=%d n=%d fin=%v ack=%v stop=%v stopack=%v recv=%d recvfin=%v reset=%v\n",
					b.id,
					b.n,
					b.fin,
					b.fin_acked,
					b.want_stop,
					b.stop_acked,
					b.recv_n,
					b.recv_fin,
					b.reset,
				)
			}
		}
	}

	assert(h3.client_retire_ready(owner))
	second: surf.HTTP3_Tunnel
	second_socket: surf.WebSocket_Conn
	assert(
		surf.websocket_http3_open(&http, &second, &second_socket, url, {origin = "https://allowed.invalid", subprotocols = {"chat.v2"}}).kind ==
		.None,
	)
	global := fmt.aprintf("https://localhost:%s/global-drain", port)
	defer delete(global)
	response, error = surf.http_client_exchange(&http, {method = .GET, url = global})
	assert(error.kind == .None)
	surf.response_destroy(&response)
	assert(surf.websocket_write_message(&second_socket, .Text, transmute([]u8)string("global-live")).kind == .None)
	_, n, we = surf.websocket_read_message(&second_socket, buffer[:])
	assert(we.kind == .None && string(buffer[:n]) == "global-live")
	assert(surf.websocket_close(&second_socket, 1000, "").kind == .None)
	h3.pool_drain(&pool)
	deadline = time.time_add(time.now(), 3 * time.Second)

	for h3.pool_pending(&pool) && time.diff(time.now(), deadline) > 0 {
		_ = h3.pool_maintain(&pool, deadline)
	}

	assert(!h3.pool_pending(&pool))
	codec.message_release(&socket.message_state)
	codec.message_release(&second_socket.message_state)
	fmt.println("OK per-peer and global GOAWAY preserve WebSockets and ordinary requests")
}
client_peer :: proc(mode, port, cert_path: string) {
	roots: tls.Root_Pool
	assert(tls.root_pool_load_file(&roots, cert_path).kind == .None)
	defer tls.root_pool_destroy(&roots)
	pool: h3.Pool
	defer h3.pool_close(&pool)
	number, ok := strconv.parse_int(port)
	assert(ok)
	endpoint := net.Endpoint{net.IP4_Loopback, int(number)}

	if mode == "graceful" {
		http: surf.HTTP_Client
		assert(
			surf.http_client_init(&http, {tls = {root_cas = roots.roots[:roots.count]}, http3 = true, http3_pool = &pool, timeout = 4 * time.Second}, {}, context.allocator).kind ==
			.None,
		)
		defer surf.http_client_close(&http)
		url := fmt.aprintf("https://localhost:%s/socket", port)
		defer delete(url)
		tunnel: surf.HTTP3_Tunnel
		socket: surf.WebSocket_Conn
		assert(
			surf.websocket_http3_open(&http, &tunnel, &socket, url, {origin = "https://allowed.invalid", subprotocols = {"chat.v2"}}).kind ==
			.None,
		)
		h3.pool_drain(&pool)
		assert(surf.websocket_write_message(&socket, .Text, transmute([]u8)string("client-drain-live")).kind == .None)
		buffer: [64]u8
		_, n, e := surf.websocket_read_message(&socket, buffer[:])
		assert(e.kind == .None && string(buffer[:n]) == "client-drain-live")
		assert(surf.websocket_close(&socket, 1000, "").kind == .None)
		codec.message_release(&socket.message_state)
		deadline := time.time_add(time.now(), 4 * time.Second)

		for h3.pool_pending(&pool) && time.diff(time.now(), deadline) > 0 {
			_ = h3.pool_maintain(&pool, deadline)
		}

		assert(!h3.pool_pending(&pool))
		fmt.println("OK client GOAWAY preserves WS and closes H3_NO_ERROR")
		return
	}

	request := h3.Client_Request {
		method    = "GET",
		target    = "/health",
		authority = "localhost",
	}

	if mode == "reject" {
		request.method = "POST"
		request.body = transmute([]u8)string("never-replay")
	}

	result := h3.pool_exchange_request(
		&pool,
		endpoint,
		"localhost",
		request,
		roots.roots[:roots.count],
		time.time_add(time.now(), 4 * time.Second),
	)

	if mode == "reject" {
		assert(result.error == .Request_Rejected && result.rejected && result.goaway == u64(0) && result.sent)
		next := h3.pool_exchange_request(
			&pool,
			endpoint,
			"localhost",
			{method = "GET", target = "/health", authority = "localhost"},
			roots.roots[:roots.count],
			time.time_add(time.now(), 4 * time.Second),
		)
		assert(next.error == .None && string(next.body[:next.body_len]) == "http-ok")
	} else if mode == "decreasing" {
		assert(result.error == .None && result.goaway == u64(4))
	} else {
		c := pool.slots[0].client
		fmt.printf(
			"INVALID phase=%v confirmed=%v closeapp=%v code=%d reason=%s\n",
			c.transport.phase,
			c.transport.model.handshake_confirmed,
			c.transport.close_application,
			c.transport.close_error,
			string(result.reason[:result.reason_len]),
		)
		assert(result.error == .Protocol)
	}

	h3.pool_drain(&pool)
	deadline := time.time_add(time.now(), 2 * time.Second)

	for h3.pool_pending(&pool) && time.diff(time.now(), deadline) > 0 {
		_ = h3.pool_maintain(&pool, deadline)
	}

	fmt.printf("OK independent GOAWAY %s rejected=%v sent=%v\n", mode, result.rejected, result.sent)
}
main :: proc() {
	context.logger = log.nil_logger()
	assert(len(os.args) >= 4)

	if os.args[1] == "server" {
		server(os.args[2], os.args[3])
	} else if os.args[1] == "client" {
		client_shutdown(os.args[2], os.args[3])
	} else {
		client_peer(os.args[1], os.args[2], os.args[3])
	}
}
