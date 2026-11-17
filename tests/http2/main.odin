package main

import server "../../core"
import credentials "core:crypto/tls/credentials"
import store "core:crypto/tls/credentials/store"
import "core:fmt"
import "core:log"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"

State :: struct {
	control:     server.Server_Control,
	config:      server.Server,
	tls_config:  server.TLS_Config,
	credentials: ^store.Store,
	handled:     u64,
}

route :: proc(data: rawptr, conn: ^server.Connection, request: ^server.Request) -> server.Response {
	state := cast(^State)data
	sync.atomic_add(&state.handled, 1)
	body := request.body
	if len(body) == 0 do body = transmute([]u8)string("ok")
	fmt.printf("REQ %s %s %d\n", request.method, request.path, len(request.body))
	os.flush(os.stdout)

	return {status = .OK, body = body}
}

tls_event :: proc(data: rawptr, event: ^server.TLS_Event) {
	if event.kind != .Handshake do return
	protocol := event.negotiated_protocol
	if protocol == "" do protocol = "-"
	fmt.printf("ALPN %s %v\n", protocol, event.handshake_complete)
	os.flush(os.stdout)
}

serve :: proc(state: ^State) {
	context.logger = log.nil_logger()
	ok := server.serve(state.config)
	fmt.printf("FINISHED %v\n", ok)
	os.flush(os.stdout)
}

main :: proc() {
	assert(len(os.args) == 3)
	context.logger = log.nil_logger()
	state: State
	cert, cert_error := os.read_entire_file(os.args[1], context.allocator)
	assert(cert_error == nil)
	defer delete(cert)
	key, key_error := os.read_entire_file(os.args[2], context.allocator)
	assert(key_error == nil)
	defer delete(key)
	credential, created := credentials.create(cert, key, {}, context.allocator)
	assert(created == .None)
	credentials_store, store_error := store.create({}, context.allocator)
	assert(store_error.kind == .None)
	state.credentials = credentials_store
	defer store.destroy(&state.credentials)
	assert(store.replace(state.credentials, &credential).kind == .None)
	state.tls_config = {
		store             = state.credentials,
		handshake_timeout = 2 * time.Second,
		close_timeout     = 200 * time.Millisecond,
		on_event          = tls_event,
		data              = &state,
	}

	state.config = {
		port = 0,
		workers = 1,
		handler = route,
		handler_data = &state,
		control = &state.control,
		tls = &state.tls_config,
		keep_alive = {enabled = true},
		observability = {enabled = true},
		timeouts = {
			header = 2 * time.Second,
			body = 400 * time.Millisecond,
			response = 2 * time.Second,
			idle = 2 * time.Second,
		},
		drain_timeout = 500 * time.Millisecond,
	}

	worker := thread.create_and_start_with_poly_data(&state, serve)
	assert(worker != nil)
	limit := time.tick_add(time.tick_now(), 5 * time.Second)

	for !server.server_ready(&state.control) && time.tick_diff(time.tick_now(), limit) > 0 {
		time.sleep(time.Millisecond)
	}

	endpoint, ready := server.server_endpoint(&state.control)
	assert(ready)
	fmt.printf("READY %d\n", endpoint.port)
	os.flush(os.stdout)

	for {
		command: [1]u8
		n, error := os.read(os.stdin, command[:])
		if error != nil || n == 0 do break
		if command[0] == 's' do server.stop_server(&state.control)
	}

	server.stop_server(&state.control)
	thread.join(worker)
	thread.destroy(worker)
}
