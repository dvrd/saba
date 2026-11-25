package main

import saba "shared:saba/core"
import h3 "shared:async/http/v3"
import "shared:async/tls"
import credentials "shared:async/tls/credentials"
import store "shared:async/tls/credentials/store"
import "core:fmt"
import "core:log"
import "core:net"
import "shared:async/quic/conn"
import "core:os"
import "core:strconv"
import "core:sync"
import "core:thread"
import "core:time"

IDLE :: 400 * time.Millisecond
State :: struct {
	listener:     h3.Listener,
	control:      saba.Server_Control,
	server:       saba.Server,
	stop, query:  bool,
	calls, drops: u64,
	pending:      bool,
}
now_ms :: proc() -> i64 {
	return i64(time.tick_diff({}, time.tick_now())) / i64(time.Millisecond)
}
route :: proc(data: rawptr, _: ^saba.Connection, r: ^saba.Request) -> saba.Response {
	assert(r.version == "HTTP/3" && r.path == "/probe")
	state := cast(^State)data
	sync.atomic_add(&state.calls, 1)

	if state.pending {
		return {deferred = {data = state, poll = pending_poll, drop = pending_drop}}
	}

	return {status = .OK, body = transmute([]u8)string("idle-ok")}
}
pending_poll :: proc(_: rawptr, _: ^saba.Deferred_IO) -> (saba.Response, saba.Deferred_Step) {
	return {}, .Waiting
}
pending_drop :: proc(data: rawptr) {
	sync.atomic_add(&(cast(^State)data).drops, 1)
}
raw_route :: proc(data: rawptr, r: ^h3.Server_Request, out: ^h3.Server_Response) -> h3.Response_Status {
	assert(r.target == "/probe")
	state := cast(^State)data
	sync.atomic_add(&state.calls, 1)
	out^ = {
		status = 200,
		body   = transmute([]u8)string("idle-ok"),
	}

	return .Ready
}
server :: proc(mode, cert_path, key_path: string) {
	cert, ce := os.read_entire_file(cert_path, context.allocator)
	assert(ce == nil)
	defer delete(cert)
	key, ke := os.read_entire_file(key_path, context.allocator)
	assert(ke == nil)
	defer delete(key)
	identity, error := credentials.create(cert, key, {}, context.allocator)
	assert(error == .None)
	owner, se := store.create({}, context.allocator)
	assert(se.kind == .None)
	defer assert(store.destroy(&owner).kind == .None)
	assert(store.replace(owner, &identity).kind == .None)
	state := new(State)
	defer free(state)
	worker: ^thread.Thread

	if mode == "saba" || mode == "saba-pending" {
		state.server = {
			port = 0,
			workers = 2,
			handler = route,
			handler_data = state,
			control = &state.control,
			http3 = {
				enabled = true,
				endpoint = {net.IP4_Loopback, 0},
				credentials = owner,
				max_connections = 1,
				idle = {timeout = IDLE},
			},
			drain_timeout = 300 * time.Millisecond,
		}

		if mode == "saba-pending" {
			state.pending = true
			state.server.http3.request_timeout = 200 * time.Millisecond
			state.server.http3.idle = {
				timeout = 5 * time.Second,
			}

			state.server.timeouts.response = 10 * time.Second
			state.server.handler_timeout = 10 * time.Second
		}

		worker = thread.create_and_start_with_poly_data(state, proc(s: ^State) {assert(saba.serve(s.server))})
		assert(worker != nil)
		until := time.tick_add(time.tick_now(), 5 * time.Second)

		for !saba.server_ready(&state.control) && time.tick_diff(time.tick_now(), until) > 0 {
			time.sleep(time.Millisecond)
		}

		endpoint, ready := saba.server_http3_endpoint(&state.control)
		assert(ready)
		fmt.printf("READY %d\n", endpoint.port)
	} else {
		state.listener.config = {
			endpoint = {net.IP4_Loopback, 0},
			credentials = owner,
			max_connections = 1,
			idle = {timeout = IDLE},
			on_request = raw_route,
			on_request_user = state,
		}

		if mode == "request-budget" {
			state.listener.config.request_timeout = 50 * time.Millisecond
		}

		port, ok := h3.listener_listen(&state.listener)
		assert(ok)
		worker = thread.create_and_start_with_poly_data(state, proc(s: ^State) {
			for !sync.atomic_load(&s.stop) {
				h3.listener_step(&s.listener)

				if sync.atomic_exchange(&s.query, false) {
					found := false

					for p in s.listener.peers {
						if p != nil && p.adopted {
							info := conn.timing_stats(&p.transport, now_ms())
							found = true
							fmt.printf(
								"TIMING %d %d %d %d %v\n",
								info.remaining_ms,
								info.base_pto_ms,
								info.effective_timeout_ms,
								info.negotiated_timeout_ms,
								info.expired,
							)
						}
					}

					if !found {
						fmt.println("TIMING none")
					}

					os.flush(os.stdout)
				}

				thread.yield()
			}

			h3.listener_close(&s.listener)
		})
		assert(worker != nil)
		fmt.printf("READY %d\n", port)
	}

	os.flush(os.stdout)
	command: [1]u8

	for {
		n, e := os.read(os.stdin, command[:])

		if e != nil || n == 0 || command[0] == 's' {
			break
		}

		if command[0] == 't' {
			sync.atomic_store(&state.query, true)
		}
	}

	if mode == "saba" || mode == "saba-pending" {
		saba.stop_server(&state.control)
	} else {
		sync.atomic_store(&state.stop, true)
	}

	thread.join(worker)
	thread.destroy(worker)
	fmt.printf("RESULT calls=%d drops=%d\n", state.calls, state.drops)
}
client :: proc(port_text, cert_path: string) {
	roots: tls.Root_Pool
	assert(tls.root_pool_load_file(&roots, cert_path) == nil)
	defer tls.root_pool_destroy(&roots)
	port, ok := strconv.parse_u64(port_text)
	assert(ok)
	pool := new(h3.Pool)
	defer {
		h3.pool_close(pool)
		free(pool)
	}

	pool.config = {
		max_lanes = 1,
		idle = {timeout = IDLE},
	}

	for call in 0 ..< 2 {
		result := h3.pool_exchange_request(
			pool,
			{net.IP4_Loopback, int(port)},
			"localhost",
			{method = "GET", target = "/probe", authority = "localhost"},
			roots.roots[:roots.count],
			time.time_add(time.now(), 5 * time.Second),
		)
		assert(result.error == .None && result.status == 200 && string(result.body[:result.body_len]) == "idle-ok")
		info := result.timing
		fmt.printf(
			"RESPONSE %d %d %d %d %d %d\n",
			call,
			result.handshakes,
			info.remaining_ms,
			info.base_pto_ms,
			info.effective_timeout_ms,
			info.negotiated_timeout_ms,
		)
		os.flush(os.stdout)

		if call == 0 {
			command: [1]u8
			n, e := os.read(os.stdin, command[:])
			assert(e == nil && n == 1 && command[0] == 'r')
		}
	}
}
main :: proc() {
	context.logger = log.nil_logger()
	assert(len(os.args) == 4)

	if os.args[1] == "client" {
		client(os.args[2], os.args[3])
	} else {
		server(os.args[1], os.args[2], os.args[3])
	}
}
