// An HTTP/3 Saba server for graceful shutdown. /socket opens an echoing
// WebSocket (origin https://allowed.invalid, subprotocol chat.v2); /drain
// sends GOAWAY on its own connection and on every connection with an open
// WebSocket, then streams http-ok slowly; /global-drain drains the whole
// listener; /inspect prints the listener's peers; any other path answers
// http-ok. It prints READY <port>, serves until stdin has a byte or closes,
// and prints RESULT opened=<n> dropped=<n> messages=<n> http=<n> resets=<n>
// stream_drops=<n>.
//
//	http3_shutdown <certificate.pem> <key.pem>
package main

import core "shared:saba/core"
import ws "shared:saba/websocket"
import codec "shared:async/websocket"
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
import async "shared:async"
import owned "shared:async/owned"

State :: struct {
	control:                                               core.Server_Control,
	config:                                                core.Server,
	tls_config:                                            core.TLS_Config,
	credentials:                                           ^store.Store,
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

main :: proc() {
	context.logger = log.nil_logger()
	assert(len(os.args) == 3)
	cert_path, key_path := os.args[1], os.args[2]
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
		handshake_timeout = 10 * time.Second, // not under test; generous for a loaded machine
		close_timeout     = 200 * time.Millisecond,
	}

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
	// Polled until the listener is published or serve returns, with no bound of
	// its own: the test's ready timeout reports a server that never starts.
	for !core.server_ready(&state.control) && !thread.is_done(worker) {
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
