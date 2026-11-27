// A Saba server whose HTTP/3 listener enforces request phase budgets: header
// 250ms, body 300ms, response 400ms (3s with progress), extended CONNECT
// accept 700ms and close 600ms. Each path fails or stalls in one phase. It
// prints READY <port>, serves until stdin has a byte or closes, and prints
// COUNTS <handled> <dropped>.
//
//	server <certificate.pem> <key.pem> [progress]
package main

import server "shared:saba"
import credentials "shared:async/tls/credentials"
import store "shared:async/tls/credentials/store"
import "core:fmt"
import "core:mem"
import owned "shared:async/owned"
import "core:net"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"
import async "shared:async"

State :: struct {
	config:       server.Server,
	control:      server.Server_Control,
	body:         [65536]u8,
	calls, drops: int,
	ok:           bool,
	stream_until: time.Tick,
	stream_done:  bool,
}
active: ^State
route :: proc(_: ^server.Connection, request: ^server.Request) -> server.Response {
	sync.atomic_add(&active.calls, 1)

	if request.path == "/producer-failure" {
		return {
			status = .OK,
			stream = {
				data = active,
				content_length = -1,
				next = proc(_: rawptr, _: ^server.Stream_IO) -> server.Stream_Step {return .Failed},
				drop = proc(data: rawptr) {sync.atomic_add(&(cast(^State)data).drops, 1)},
			},
		}
	}

	if request.path == "/stream-budget" {
		active.stream_until = time.tick_add(time.tick_now(), 600 * time.Millisecond)
		return {
			status = .OK,
			stream = {
				data = active,
				content_length = -1,
				timeout = 1500 * time.Millisecond,
				next = proc(data: rawptr, io: ^server.Stream_IO) -> server.Stream_Step {
					state := cast(^State)data
					remaining := time.tick_diff(time.tick_now(), state.stream_until)

					if remaining > 0 {
						_ = server.stream_wait(io, async.deadline_after(io.runtime, remaining))
						return .Waiting
					}

					if state.stream_done {
						return .Done
					}

					chunk, error := owned.copy_bounded(transmute([]u8)string("stream-ok"), 9, io.backing_allocator)

					if error.kind != .None {
						return .Failed
					}

					if server.stream_submit(io, &chunk) != .Accepted {
						owned.destroy(&chunk)
						return .Failed
					}

					state.stream_done = true
					return .Chunk
				},
				drop = proc(data: rawptr) {sync.atomic_add(&(cast(^State)data).drops, 1)},
			},
		}
	}

	if request.path == "/handler-failure" {
		return {
			deferred = {
				data = active,
				timeout = 100 * time.Millisecond,
				poll = proc(_: rawptr, _: ^server.Deferred_IO) -> (server.Response, server.Deferred_Step) {
					return {}, .Waiting
				},
				drop = proc(data: rawptr) {sync.atomic_add(&(cast(^State)data).drops, 1)},
			},
		}
	}

	if request.path == "/pending" || request.path == "/accept-pending" {
		return {
			deferred = {
				data = active,
				timeout = 2 * time.Second,
				poll = proc(_: rawptr, _: ^server.Deferred_IO) -> (server.Response, server.Deferred_Step) {
					return {}, .Waiting
				},
				drop = proc(data: rawptr) {sync.atomic_add(&(cast(^State)data).drops, 1)},
			},
		}
	}

	if request.protocol != "" {
		return {
			status = .OK,
			upgrade = {data = active, resume = proc(_: rawptr, io: ^server.Upgrade_IO) -> async.Resume_Result {
					buffer: [1]u8
					_, error := io.stream_read(io.stream_data, buffer[:], {})

					if error.kind == .Cancelled || error.kind == .Peer_Closed || error.kind == .Closed {
						return .Done
					}

					return .Waiting
				}, drop = proc(data: rawptr) {sync.atomic_add(&(cast(^State)data).drops, 1)}},
		}
	}

	body := transmute([]u8)string("healthy")

	if request.path == "/large" {
		body = active.body[:]
	}

	return {status = .OK, body = body}
}
main :: proc() {
	assert(len(os.args) == 3 || len(os.args) == 4)
	cert, ce := os.read_entire_file(os.args[1], context.allocator)
	assert(ce == nil)
	defer delete(cert)
	key, ke := os.read_entire_file(os.args[2], context.allocator)
	assert(ke == nil)
	defer delete(key)
	identity, error := credentials.create(cert, key, {}, context.allocator)
	assert(error == .None)
	owned, created := store.create({}, context.allocator)
	assert(created.kind == .None)
	defer assert(store.destroy(&owned).kind == .None)
	assert(store.replace(owned, &identity).kind == .None)
	state: State
	active = &state
	// The server is stopped and its worker joined before main returns: nothing reads this frame afterwards.
	defer active = nil
	state.config = {
		handler = route,
		control = &state.control,
		address = "127.0.0.1",
		port = 0,
		workers = 2,
		resources = {connection_limits = {64 * mem.Megabyte, 8, 8}},
		drain_timeout = 500 * time.Millisecond,
		timeouts = {header = 250 * time.Millisecond, body = 300 * time.Millisecond, response = 400 * time.Millisecond},
		http3 = {
			enabled = true,
			enable_connect_protocol = true,
			credentials = owned,
			endpoint = {net.IP4_Loopback, 0},
			request_timeout = 2 * time.Second,
			request_phases = {
				enabled = true,
				connect_accept = 700 * time.Millisecond,
				connect_close = 600 * time.Millisecond,
			},
		},
	}

	if len(os.args) == 4 {
		assert(os.args[3] == "progress")
		state.config.timeouts.response = 3 * time.Second
	}

	worker := thread.create_and_start_with_poly_data(
		&state,
		proc(state: ^State) {state.ok = server.serve(state.config)},
	)
	assert(worker != nil)
	defer thread.destroy(worker)
	joined := false

	defer if !joined {
		server.stop_server(&state.control)
		thread.join(worker)
	}

	until := time.tick_add(time.tick_now(), 5 * time.Second)

	for !server.server_ready(&state.control) && time.tick_diff(time.tick_now(), until) > 0 {
		time.sleep(time.Millisecond)
	}

	endpoint, ready := server.server_http3_endpoint(&state.control)
	assert(ready)
	fmt.println("READY", endpoint.port)
	os.flush(os.stdout)
	command: [1]u8
	_, _ = os.read(os.stdin, command[:])
	server.stop_server(&state.control)
	thread.join(worker)
	joined = true
	assert(state.ok)
	fmt.printf("COUNTS %d %d\n", state.calls, state.drops)
}
