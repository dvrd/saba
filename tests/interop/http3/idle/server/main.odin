// An HTTP/3-only Saba server with one connection slot, for the idle and
// request budgets. GET /probe answers idle-ok, except in pending mode, where
// the handler never answers. It prints READY <port>, serves until stdin has a
// byte or closes, and prints RESULT calls=<handled> drops=<dropped pending>.
//
//	server idle|request-budget|pending <certificate.pem> <key.pem>
//
// idle: a negotiated idle timeout of 400ms. request-budget: the same, with a
// 50ms pending-handler budget. pending: a 5s idle timeout and a 200ms
// pending-handler budget, which closes the connection when it runs out.
package main

import saba "shared:saba/core"
import credentials "shared:async/tls/credentials"
import store "shared:async/tls/credentials/store"
import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"

IDLE :: 400 * time.Millisecond

State :: struct {
	control:      saba.Server_Control,
	server:       saba.Server,
	calls, drops: u64,
	pending:      bool,
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

main :: proc() {
	context.logger = log.nil_logger()
	assert(len(os.args) == 4)
	mode := os.args[1]
	cert, ce := os.read_entire_file(os.args[2], context.allocator)
	assert(ce == nil)
	defer delete(cert)
	key, ke := os.read_entire_file(os.args[3], context.allocator)
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

	switch mode {
	case "idle":
	case "request-budget":
		state.server.http3.request_timeout = 50 * time.Millisecond
	case "pending":
		state.pending = true
		state.server.http3.request_timeout = 200 * time.Millisecond
		state.server.http3.idle = {
			timeout = 5 * time.Second,
		}
		state.server.timeouts.response = 10 * time.Second
		state.server.handler_timeout = 10 * time.Second
	case:
		panic("unknown mode")
	}

	worker := thread.create_and_start_with_poly_data(state, proc(s: ^State) {assert(saba.serve(s.server))})
	assert(worker != nil)
	// Polled until the listener is published or serve returns, with no bound of
	// its own: the test's ready timeout reports a server that never starts.
	for !saba.server_ready(&state.control) && !thread.is_done(worker) {
		time.sleep(time.Millisecond)
	}

	endpoint, ready := saba.server_http3_endpoint(&state.control)
	assert(ready)
	fmt.printf("READY %d\n", endpoint.port)
	os.flush(os.stdout)
	command: [1]u8
	_, _ = os.read(os.stdin, command[:])
	saba.stop_server(&state.control)
	thread.join(worker)
	thread.destroy(worker)
	fmt.printf("RESULT calls=%d drops=%d\n", state.calls, state.drops)
}
