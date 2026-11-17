package main

import core "shared:saba/core"
import ws "shared:saba/websocket"
import assets "shared:saba/assets"
import codec "shared:websocket"
import tls "core:crypto/tls"
import credentials "core:crypto/tls/credentials"
import store "core:crypto/tls/credentials/store"
import owned "core:mem/owned"
import async "shared:async"
import rt "base:runtime"
import "core:fmt"
import "core:os"
import "core:mem"
import budget "core:sync/budget"
import "core:sync"
import "core:thread"
import "core:time"

State :: struct {
	control:                                                               core.Server_Control,
	config:                                                                core.Server,
	tls_config:                                                            core.TLS_Config,
	credentials:                                                           ^store.Store,
	auth:                                                                  tls.Client_Auth_Config,
	roots:                                                                 tls.Root_Pool,
	opened, dropped, messages, http, resets, created, disposed, cancelled: u64,
	release:                                                               bool,
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
	identity := core.tls_peer_identity(connection)

	if state.auth.mode == .Require {
		assert(identity.authenticated)
	}

	if request.path == "/socket" {
		assert(request.version == "HTTP/2" && request.protocol == "websocket")
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

	if request.path == "/hold" || request.path == "/stream" || request.path == "/bulk" {
		work := new(Work, rt.heap_allocator())
		work.state = state
		work.bulk = request.path == "/bulk"
		work.cancellation, _ = core.retain_request_context(request.cancellation)
		sync.atomic_add(&state.created, 1)

		if request.path == "/hold" {
			return {deferred = {data = work, poll = poll, drop = dispose}}
		}

		return {
			status = .OK,
			stream = {
				data = work,
				next = next,
				drop = dispose,
				content_length = 128 * 1024 if work.bulk else 7,
				max_chunk_bytes = 16384,
			},
		}
	}

	if request.path == "/drain" {
		assert(core.drain_server(&state.control, 3 * time.Second))
	}

	if request.path == "/asset" {
		return assets.representation_response(request, transmute([]u8)string("asset-body"), "text/plain")
	}

	if request.path == "/no-content" {
		return {status = .No_Content}
	}

	if request.path == "/pressure" {
		_, _ = make([]u8, 33 * mem.Megabyte, request.allocator)
	}

	if request.path == "/release" {
		sync.atomic_store(&state.release, true)
	}

	sync.atomic_add(&state.http, 1)

	return {status = .OK, body = transmute([]u8)string("http-ok")}
}
server :: proc(cert_path, key_path: string, root_path: string = "", load: bool = false) {
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

	if load {
		state.tls_config.handshake_timeout = 0
	} // Use the existing production default10s.
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
		keep_alive = {enabled = true},
		timeouts = {
			header = 10 * time.Second,
			body = 10 * time.Second,
			response = 10 * time.Second,
			idle = 10 * time.Second,
		},
		drain_timeout = 500 * time.Millisecond,
	}

	worker := thread.create_and_start_with_poly_data(&state, proc(s: ^State) {assert(core.serve(s.config))})
	assert(worker != nil)
	until := time.tick_add(time.tick_now(), 5 * time.Second)

	for !core.server_ready(&state.control) && time.tick_diff(time.tick_now(), until) > 0 {
		time.sleep(time.Millisecond)
	}

	endpoint, ready := core.server_endpoint(&state.control)
	assert(ready)
	retained, retained_ok := core.retain_server_resources(&state.control)
	assert(retained_ok)
	fmt.printf("READY %d\n", endpoint.port)
	os.flush(os.stdout)

	if load {
		fmt.printf("LOAD_CONFIG workers=2 handshake_timeout_seconds=10 ")
		fmt.printf("global_bytes=268435456 connection_bytes=67108864 operation_bytes=33554432\n")
		os.flush(os.stdout)
	}

	command: [1]u8
	_, _ = os.read(os.stdin, command[:])
	core.stop_server(&state.control)
	thread.join(worker)
	thread.destroy(worker)
	view, ve := budget.snapshot(retained)
	assert(
		ve == .None && view.used.bytes == 0 && view.used.streams == 0 && view.used.jobs == 0 && view.scope_nodes == 1,
	)
	budget.release_scope(&retained)
	fmt.println("RESOURCES retired-zero")
	fmt.printf(
		"RESULT opened=%d dropped=%d messages=%d http=%d resets=%d\n",
		state.opened,
		state.dropped,
		state.messages,
		state.http,
		state.resets,
	)
	assert(state.opened == state.dropped)
	fmt.printf("WORK created=%d disposed=%d cancelled=%d\n", state.created, state.disposed, state.cancelled)
	assert(state.created == state.disposed)
}

Work :: struct {
	state:        ^State,
	cancellation: core.Request_Context,
	sent, bulk:   bool,
	offset:       int,
}
dispose :: proc(data: rawptr) {
	work := cast(^Work)data

	if core.request_cancelled(work.cancellation) {
		sync.atomic_add(&work.state.cancelled, 1)
	}

	core.release_request_context(&work.cancellation)
	sync.atomic_add(&work.state.disposed, 1)
	free(work, rt.heap_allocator())
}
poll :: proc(data: rawptr, io: ^core.Deferred_IO) -> (core.Response, core.Deferred_Step) {
	work := cast(^Work)data

	if !sync.atomic_load(&work.state.release) {
		return {}, .Waiting
	}

	return {status = .OK, body = transmute([]u8)string("held-ok")}, .Ready
}
next :: proc(data: rawptr, io: ^core.Stream_IO) -> core.Stream_Step {
	work := cast(^Work)data

	if !sync.atomic_load(&work.state.release) {
		_ = core.stream_wait(io, async.deadline_after(io.runtime, time.Millisecond))
		return .Waiting
	}

	if work.bulk {
		if work.offset == 128 * 1024 {
			return .Done
		}

		chunk, e := owned.allocate(16384, io.backing_allocator)

		if e.kind != .None {
			return .Failed
		}

		for &byte in chunk.data {
			byte = 'b'
		}

		if core.stream_submit(io, &chunk) != .Accepted {
			owned.destroy(&chunk)
			return .Failed
		}

		work.offset += 16384
		return .Chunk
	}

	if work.sent {
		return .Done
	}

	chunk, e := owned.copy_bounded(transmute([]u8)string("held-ok"), 16384, io.backing_allocator)

	if e.kind != .None {
		return .Failed
	}

	if core.stream_submit(io, &chunk) != .Accepted {
		owned.destroy(&chunk)
		return .Failed
	}

	work.sent = true

	return .Chunk
}
main :: proc() {
	assert(len(os.args) == 3 || (len(os.args) == 4 && os.args[3] == "load"))
	server(os.args[1], os.args[2], load = len(os.args) == 4)
}
