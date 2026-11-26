package main

import core "shared:saba/core"
import ws "shared:saba/websocket"
import async "shared:async"
import codec "shared:async/websocket"
import tls "shared:async/tls"
import credentials "shared:async/tls/credentials"
import store "shared:async/tls/credentials/store"
import rt "base:runtime"
import "core:fmt"
import "core:bytes"
import "core:log"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:sync"
import "core:thread"
import "core:time"

State :: struct {
	control:                                 core.Server_Control,
	config:                                  core.Server,
	tls_config:                              core.TLS_Config,
	credentials:                             ^store.Store,
	auth:                                    tls.Client_Auth_Config,
	roots:                                   tls.Root_Pool,
	opened, dropped, messages, http, resets: u64,
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

	endpoint, ready := core.server_endpoint(&state.control)
	assert(ready)
	fmt.printf("READY %d\n", endpoint.port)
	os.flush(os.stdout)
	command: [1]u8
	_, _ = os.read(os.stdin, command[:])
	core.stop_server(&state.control)
	thread.join(worker)
	thread.destroy(worker)
	fmt.printf(
		"RESULT opened=%d dropped=%d messages=%d http=%d resets=%d\n",
		state.opened,
		state.dropped,
		state.messages,
		state.http,
		state.resets,
	)
	assert(state.opened == state.dropped)
}
identity_replace :: proc(identity: ^store.Store, cert, key: string) {
	certificate, ce := os.read_entire_file(cert, context.allocator)
	assert(ce == nil)
	defer delete(certificate)
	secret, ke := os.read_entire_file(key, context.allocator)
	assert(ke == nil)
	defer delete(secret)
	owner, e := credentials.create(certificate, secret, {}, context.allocator)
	assert(e == .None)
	assert(store.replace(identity, &owner).kind == .None)
}
identity_text :: proc(identity: ^store.Store) -> [64]u8 {
	lease, e := store.acquire(identity)
	assert(e.kind == .None)
	defer store.release(identity, &lease)
	fingerprint, fe := store.fingerprint(identity, lease)
	assert(fe.kind == .None)
	text: [64]u8
	digits := "0123456789abcdef"

	for byte, i in fingerprint {
		text[i * 2] = digits[byte >> 4]
		text[i * 2 + 1] = digits[byte & 15]
	}

	return text
}
// One GET of /health on connection conn: the body must be http-ok. Returns
// the identity the server saw on that connection.
health :: proc(d: ^Driver, conn: int, label: string = "") -> string {
	error := call(d, .Get, conn)
	g := &d.get
	if label != "" {
		fmt.printf("%s kind=%v status=%d body=%s\n", label, error.kind, g.status, string(g.body[:]))
	}
	assert(error.kind == .None && g.status == 200 && string(g.body[:]) == "http-ok")

	return string(g.identity[:g.identity_n])
}
send :: proc(d: ^Driver, socket: int, kind: async.WS_Message_Kind, payload: []u8) {
	d.kind, d.payload = kind, payload
	error := call(d, .Send, socket)
	assert(error.kind == .None)
}
receive :: proc(d: ^Driver, socket: int) -> (async.WS_Message_Kind, []u8, async.Error) {
	error := call(d, .Recv, socket)

	return d.message.kind, d.message.data, error
}
client :: proc(
	port, cert_path: string,
	identity_cert: string = "",
	identity_key: string = "",
	replacement_cert: string = "",
	replacement_key: string = "",
) {
	roots: tls.Root_Pool
	assert(tls.root_pool_load_file(&roots, cert_path) == nil)
	defer tls.root_pool_destroy(&roots)
	identity: ^store.Store
	if identity_cert != "" {
		identity, _ = store.create({}, context.allocator)
		assert(identity != nil)
		identity_replace(identity, identity_cert, identity_key)
	}
	defer if identity != nil {
		assert(store.destroy(&identity).kind == .None)
	}
	number, number_ok := strconv.parse_int(port)
	assert(number_ok)
	d := new(Driver)
	defer free(d)
	driver_start(d, number, &roots, identity)
	d.authority = fmt.aprintf("localhost:%s", port)
	defer delete(d.authority)
	d.path = fmt.aprintf("https://localhost:%s/health", port)
	defer delete(d.path)
	// Connection 0 carries both websockets and the plain requests.
	assert(call(d, .Dial, 0).kind == .None)
	assert(sync.atomic_load(&d.dials) == 1)
	d.sockets[0].conn = 0
	error := call(d, .Open, 0)
	fmt.printf("OPEN error=%v\n", error.kind)
	assert(error.kind == .None)
	assert(string(d.sockets[0].protocol[:d.sockets[0].protocol_n]) == "chat.v2")
	d.sockets[1].conn = 0
	assert(call(d, .Open, 1).kind == .None)
	assert(string(d.sockets[1].protocol[:d.sockets[1].protocol_n]) == "chat.v2")
	seen := health(d, 0)
	if identity != nil {
		expected := identity_text(identity)
		assert(seen == string(expected[:]))
	}
	if replacement_cert != "" {
		// The identity is fixed by a connection's handshake: after rotating
		// it, the open connection still presents the old one, and exactly one
		// new dial presents the new one.
		old := identity_text(identity)
		dials := sync.atomic_load(&d.dials)
		identity_replace(identity, replacement_cert, replacement_key)
		assert(call(d, .Dial, 1).kind == .None)
		assert(sync.atomic_load(&d.dials) == dials + 1)
		expected := identity_text(identity)
		assert(expected != old)
		seen = health(d, 1)
		assert(seen == string(expected[:]))
		seen = health(d, 0)
		assert(seen == string(old[:]))
		assert(call(d, .Shutdown, 1).kind == .None)
		assert(sync.atomic_load(&d.dials) == dials + 1)
	}
	send(d, 0, .Text, transmute([]u8)string("native-hello"))
	kind, data, read := receive(d, 0)
	fmt.printf("READ kind=%v n=%d\n", read.kind, len(data))
	assert(read.kind == .None && kind == .Text && string(data) == "native-hello")
	delete(data, rt.heap_allocator())
	// This exceeds both the HTTP2 stream window and Saba's64KiB body queue.
	// Incremental backpressure must complete without buffering an unbounded body.
	payload := make([]u8, 128 * 1024)
	defer delete(payload)
	for &byte, i in payload {
		byte = u8(i % 251)
	}
	send(d, 0, .Binary, payload)
	kind, data, read = receive(d, 0)
	fmt.printf("LARGE kind=%v n=%d opcode=%v\n", read.kind, len(data), kind)
	assert(read.kind == .None && kind == .Binary && len(data) == len(payload) && bytes.equal(payload, data))
	delete(data, rt.heap_allocator())
	assert(call(d, .Close, 0).kind == .None)
	assert(d.sockets[0].close.reason == .Local_Close && d.sockets[0].close.clean)
	send(d, 1, .Text, transmute([]u8)string("second-stream"))
	kind, data, read = receive(d, 1)
	assert(read.kind == .None && string(data) == "second-stream")
	delete(data, rt.heap_allocator())
	assert(call(d, .Close, 1).kind == .None)
	assert(d.sockets[1].close.reason == .Local_Close && d.sockets[1].close.clean)
	seen = health(d, 0, "AFTER")
	assert(call(d, .Shutdown, 0).kind == .None)
	// Every connection the client made was one it asked for.
	assert(sync.atomic_load(&d.dials) == (2 if replacement_cert != "" else 1))
	driver_stop(d)
	if identity != nil {
		view, e := store.stats(identity)
		assert(e.kind == .None && view.active_leases == 0)
	}
	fmt.println("OK native-http2-websocket")
}
main :: proc() {
	context.logger = log.nil_logger()
	assert(len(os.args) >= 4)

	if os.args[1] == "server" {
		server(os.args[2], os.args[3])
	} else if os.args[1] == "server-mtls" {
		assert(len(os.args) == 5)
		server(os.args[2], os.args[3], os.args[4])
	} else if os.args[1] == "client-mtls" {
		assert(len(os.args) == 8)
		client(os.args[2], os.args[3], os.args[4], os.args[5], os.args[6], os.args[7])
	} else {
		client(os.args[2], os.args[3])
	}
}
