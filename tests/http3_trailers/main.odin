package main

import core "shared:saba/core"
import surf "shared:surf"
import http "shared:async/http"
import h3 "shared:async/http/v3"
import "shared:async/tls"
import credentials "shared:async/tls/credentials"
import store "shared:async/tls/credentials/store"
import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:sync"
import "core:strings"
import "core:thread"
import "core:time"

State :: struct {
	control: core.Server_Control,
	server:  core.Server,
	calls:   u64,
}
route :: proc(data: rawptr, _: ^core.Connection, request: ^core.Request) -> core.Response {
	state := cast(^State)data

	if request.path == "/plain" {
		return {status = .OK, body = transmute([]u8)string("plain")}
	}

	assert(request.version == "HTTP/3" && request.path == "/trailers")
	assert(strings.has_prefix(core.header_value(request, "host"), "localhost"))
	assert(
		len(request.trailers) == 1 &&
		request.trailers[0].name == "x-request-checksum" &&
		request.trailers[0].value == "abc",
	)
	assert(string(request.body) == "payload" || len(request.body) == 0)
	sync.atomic_add(&state.calls, 1)
	trailers := make([]core.Header, 1, request.allocator)
	trailers[0] = {"x-response-checksum", "ack"}

	return {status = .OK, body = transmute([]u8)string("echo"), trailers = trailers}
}
server :: proc(cert_path, key_path: string) {
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
	state: State
	state.server = {
		port = 0,
		workers = 2,
		handler = route,
		handler_data = &state,
		control = &state.control,
		http3 = {enabled = true, endpoint = {net.IP4_Loopback, 0}, credentials = owner},
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
client :: proc(port, cert_path: string, invalid: bool = false) {
	roots: tls.Root_Pool
	assert(tls.root_pool_load_file(&roots, cert_path) == nil)
	defer tls.root_pool_destroy(&roots)
	pool: h3.Pool
	defer h3.pool_close(&pool)
	config := surf.Config {
		http3 = true,
		http3_pool = &pool,
		timeout = 5 * time.Second,
		tls = {root_cas = roots.roots[:roots.count]},
	}

	url := fmt.aprintf("https://localhost:%s/trailers", port)
	defer delete(url)

	if invalid {
		bad_url := fmt.aprintf("https://localhost:%s/bad", port)
		defer delete(bad_url)
		response, error := surf.execute({method = .POST, url = bad_url}, config)
		assert(error.kind != .None)
		surf.response_destroy(&response)
	}

	trailer_headers := [1]http.Header{{"X-Request-Checksum", "abc"}}

	for body in ([]string{"payload", ""}) {
		response, error := surf.execute(
			{method = .POST, url = url, trailers = trailer_headers[:], body = transmute([]u8)body},
			config,
		)
		assert(error.kind == .None && response.status == 200 && string(response.body) == "echo")
		value, found := surf.response_trailer(&response, "X-Response-Checksum")
		assert(found && value == "ack")
		_, merged := surf.response_header(&response, "x-response-checksum")
		assert(!merged)
		surf.response_destroy(&response)
	}

	fmt.println("OK native HTTP3 trailers")
}
main :: proc() {
	context.logger = log.nil_logger()
	assert(len(os.args) == 4)

	if os.args[1] == "server" {
		server(os.args[2], os.args[3])
	} else {
		client(os.args[2], os.args[3], os.args[1] == "client-bad")
	}
}
