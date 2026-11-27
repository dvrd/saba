// An HTTP/3-only Saba server with one connection slot: GET /probe answers
// wire-ok, and /head204, /head304 and /head200 answer HEAD requests. It
// prints READY <port>, serves until stdin has a byte or closes, and prints
// RESULT calls=<handled requests>.
//
//	http3_probe <certificate.pem> <key.pem>
package main

import core "shared:saba/core"
import credentials "shared:async/tls/credentials"
import store "shared:async/tls/credentials/store"
import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"

State :: struct {
	control: core.Server_Control,
	server:  core.Server,
	calls:   u64,
}

route :: proc(data: rawptr, _: ^core.Connection, request: ^core.Request) -> core.Response {
	assert(request.version == "HTTP/3")
	state := cast(^State)data
	sync.atomic_add(&state.calls, 1)

	if request.path == "/head204" {
		assert(request.method == "HEAD")
		return {status = .No_Content}
	}

	if request.path == "/head304" {
		assert(request.method == "HEAD" && core.header_value(request, "if-none-match") == "\"asset-v1\"")
		headers := make([]core.Header, 1, request.allocator)
		headers[0] = {"etag", "\"asset-v1\""}
		return {status = .Not_Modified, headers = headers}
	}

	if request.path == "/head200" {
		assert(request.method == "HEAD")
		return {status = .OK, body = transmute([]u8)string("hello")}
	}

	assert(request.path == "/probe")

	return {status = .OK, body = transmute([]u8)string("wire-ok")}
}

main :: proc() {
	context.logger = log.nil_logger()
	assert(len(os.args) == 3)
	cert, ce := os.read_entire_file(os.args[1], context.allocator)
	assert(ce == nil)
	defer delete(cert)
	key, ke := os.read_entire_file(os.args[2], context.allocator)
	assert(ke == nil)
	defer delete(key)
	identity, error := credentials.create(cert, key, {}, context.allocator)
	assert(error == .None)
	owner, se := store.create({}, context.allocator)
	assert(se.kind == .None)
	defer assert(store.destroy(&owner).kind == .None)
	assert(store.replace(owner, &identity).kind == .None)
	state: State
	state.server = {
		port = 0,
		workers = 2,
		handler = route,
		handler_data = &state,
		control = &state.control,
		http3 = {enabled = true, endpoint = {net.IP4_Loopback, 0}, credentials = owner, max_connections = 1},
		drain_timeout = 300 * time.Millisecond,
	}

	worker := thread.create_and_start_with_poly_data(&state, proc(s: ^State) {assert(core.serve(s.server))})
	assert(worker != nil)
	defer thread.destroy(worker)
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
	fmt.printf("RESULT calls=%d\n", state.calls)
}
