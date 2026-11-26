package main

import core "shared:saba/core"
import ws "shared:saba/websocket"
import codec "shared:async/websocket"
import tls "shared:async/tls"
import credentials "shared:async/tls/credentials"
import store "shared:async/tls/credentials/store"
import rt "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import h3 "shared:async/http/v3"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"
import "core:strconv"
import async "shared:async"
import owned "shared:async/owned"

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
		// Per-peer GOAWAY: the connection that carries this request, and every
		// connection that carries an open websocket. A client lane carries one
		// tunnel at a time, so a client's websocket and this request may
		// arrive on different connections; a client on one connection sees
		// both on it. Other connections keep serving.
		for p in connection._task.runtime.http3.live.peers {
			if p != nil {
				for slot in p.in_streams {
					if slot.used && !slot.released && (slot.request.target == "/drain" || slot.extended) {
						_ = h3.live_begin_shutdown(p)
						break
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
		assert(tls.root_pool_load_file(&state.roots, root_path) == nil)
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
lanes_used :: proc(pool: ^h3.Pool, user: rawptr) {
	used := cast(^int)user
	for slot in pool.slots {
		if slot.used {
			used^ += 1
		}
	}
}
Lane_Check :: struct {
	lane:     ^h3.Client,
	socket:   ^Socket,
	goaway:   bool,
	retired:  bool,
	same:     bool,
	deadline: time.Time,
}
lane_goaway :: proc(pool: ^h3.Pool, user: rawptr) {
	check := cast(^Lane_Check)user
	check.goaway = check.lane.shutdown.received
	// The websocket's tunnel is still on the lane it opened on.
	check.same = check.socket.tunnel._connect != nil && check.socket.tunnel._connect.owner == check.lane
}
lane_retire :: proc(pool: ^h3.Pool, user: rawptr) {
	check := cast(^Lane_Check)user
	check.retired = h3.client_retire_ready(check.lane)
	if !check.retired {
		_ = h3.pool_maintain(pool, check.deadline)
		check.retired = h3.client_retire_ready(check.lane)
	}
}
lane_print :: proc(pool: ^h3.Pool, user: rawptr) {
	owner := (cast(^Lane_Check)user).lane
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
echo :: proc(socket: ^Socket, text: string) {
	assert(socket_send(socket, .Text, transmute([]u8)text).kind == .None)
	_, data, error := socket_receive(socket)
	assert(error.kind == .None && string(data) == text)
	delete(data, rt.heap_allocator())
}
expect_ok :: proc(c: ^Client, path: string) {
	g := get(c, path)
	defer get_destroy(g)
	assert(g.error.kind == .None && g.status == 200 && string(g.body[:]) == "http-ok")
}
client_shutdown :: proc(port, cert_path: string) {
	roots: tls.Root_Pool
	assert(tls.root_pool_load_file(&roots, cert_path) == nil)
	defer tls.root_pool_destroy(&roots)
	number, number_ok := strconv.parse_int(port)
	assert(number_ok)
	authority := fmt.aprintf("localhost:%s", port)
	defer delete(authority)
	c := new(Client)
	defer free(c)
	client_start(c, number, authority, &roots, nil)
	socket, error := socket_open(c)
	assert(error.kind == .None && socket.lane != nil)
	check := Lane_Check {
		lane   = socket.lane,
		socket = socket,
	}
	// The server drains the websocket's connection (and the request's own)
	// while the slow response is still in flight: that response completes.
	expect_ok(c, "/drain")
	echo(socket, "after-goaway")
	until := time.time_add(time.now(), 3 * time.Second)
	for !check.goaway && time.diff(time.now(), until) > 0 {
		with_pool(c, lane_goaway, &check)
		if !check.goaway {
			echo(socket, "after-goaway")
		}
	}
	assert(check.goaway && check.same)
	expect_ok(c, "/health")
	used := 0
	with_pool(c, lanes_used, &used)
	with_pool(c, lane_goaway, &check)
	assert(used >= 2 && check.same)
	assert(socket_close(socket).kind == .None)
	assert(socket.close.reason == .Local_Close && socket.close.clean)
	check.deadline = time.time_add(time.now(), 3 * time.Second)

	for !check.retired && time.diff(time.now(), check.deadline) > 0 {
		with_pool(c, lane_retire, &check)
		if !check.retired {
			time.sleep(time.Millisecond)
		}
	}

	if !check.retired {
		g := get(c, "/inspect")
		get_destroy(g)
		with_pool(c, lane_print, &check)
	}

	assert(check.retired)
	second, second_error := socket_open(c)
	assert(second_error.kind == .None)
	expect_ok(c, "/global-drain")
	echo(second, "global-live")
	assert(socket_close(second).kind == .None)
	assert(second.close.reason == .Local_Close && second.close.clean)
	assert(client_drain(c))
	socket_destroy(socket)
	socket_destroy(second)
	client_stop(c)
	fmt.println("OK per-peer and global GOAWAY preserve WebSockets and ordinary requests")
}
client_peer :: proc(mode, port, cert_path: string) {
	roots: tls.Root_Pool
	assert(tls.root_pool_load_file(&roots, cert_path) == nil)
	defer tls.root_pool_destroy(&roots)
	number, ok := strconv.parse_int(port)
	assert(ok)

	if mode == "graceful" {
		authority := fmt.aprintf("localhost:%s", port)
		defer delete(authority)
		c := new(Client)
		defer free(c)
		client_start(c, int(number), authority, &roots, nil)
		socket, error := socket_open(c)
		assert(error.kind == .None)
		// The client's own GOAWAY: the open websocket keeps working, then
		// every lane closes with H3_NO_ERROR.
		with_pool(c, proc(pool: ^h3.Pool, _: rawptr) {h3.pool_drain(pool)})
		echo(socket, "client-drain-live")
		assert(socket_close(socket).kind == .None)
		assert(client_drain(c, 4 * time.Second))
		socket_destroy(socket)
		client_stop(c)
		fmt.println("OK client GOAWAY preserves WS and closes H3_NO_ERROR")
		return
	}

	pool: h3.Pool
	defer h3.pool_close(&pool)
	endpoint := net.Endpoint{net.IP4_Loopback, int(number)}

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
