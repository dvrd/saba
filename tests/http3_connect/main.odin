package main

import core "shared:saba/core"
import ws "shared:saba/websocket"
import async "shared:async"
import codec "shared:async/websocket"
import tls "shared:async/tls"
import credentials "shared:async/tls/credentials"
import store "shared:async/tls/credentials/store"
import budget "shared:async/budget"
import rt "base:runtime"
import "core:fmt"
import "core:bytes"
import "core:log"
import "core:mem"
import "core:net"
import h3 "shared:async/http/v3"
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
server :: proc(cert_path, key_path: string, root_path: string = "", load_mode: bool = false) {
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
	defer assert(store.destroy(&state.credentials).kind == .None)
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

	// The load profile reserves transport slots for both active and draining peers.
	// Ordinary functional modes retain the library default of 32 total slots.
	if load_mode {
		state.config.http3.max_connections = 64
	}

	worker := thread.create_and_start_with_poly_data(&state, proc(s: ^State) {assert(core.serve(s.config))})
	assert(worker != nil)
	until := time.tick_add(time.tick_now(), 5 * time.Second)

	for !core.server_ready(&state.control) && time.tick_diff(time.tick_now(), until) > 0 {
		time.sleep(time.Millisecond)
	}

	endpoint, ready := core.server_http3_endpoint(&state.control)
	assert(ready)
	retained, retained_ok := core.retain_server_resources(&state.control)
	assert(retained_ok)
	fmt.printf("READY %d\n", endpoint.port)
	os.flush(os.stdout)

	if load_mode {
		fmt.println("LOAD_CONFIG total_transport_slots=64 profile_client_limit=32 includes_closing=true")
		os.flush(os.stdout)
	}

	command: [1]u8
	_, _ = os.read(os.stdin, command[:])
	core.stop_server(&state.control)
	thread.join(worker)
	thread.destroy(worker)
	// This observes Saba's configured managed scope, not the QUIC transport heap.
	view, view_error := budget.snapshot(retained)
	assert(view_error == .None)
	assert(view.used.bytes == 0 && view.used.streams == 0 && view.used.jobs == 0 && view.scope_nodes == 1)
	budget.release_scope(&retained)
	fmt.println("SABA_RESOURCES bytes=0 streams=0 jobs=0 scope_nodes=1")
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
// One GET of /health: the body must be http-ok. Returns the identity the
// server saw on the lane that carried it.
health :: proc(c: ^Client, label: string = "") -> [64]u8 {
	g := get(c, "/health")
	defer get_destroy(g)
	if g.error.kind != .None {
		fmt.printf("GET failed error=%v failure=%v\n", g.error, g.failure)
	}
	if label != "" {
		fmt.printf("%s kind=%v status=%d body=%s\n", label, g.error.kind, g.status, string(g.body[:]))
	}
	assert(g.error.kind == .None && g.status == 200 && string(g.body[:]) == "http-ok")
	identity: [64]u8
	copy(identity[:], g.identity[:g.identity_n])

	return identity
}
lanes_inserted :: proc(pool: ^h3.Pool, user: rawptr) {
	inserts := cast(^u64)user
	for slot in pool.slots {
		if slot.used && slot.client != nil {
			inserts^ += slot.client.qpack.stats.encoded_inserts
		}
	}
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
	// Requests name the origin localhost:8443 while the pool dials the HTTP/3
	// port, as an Alt-Svc alternative would be reached.
	c := new(Client)
	defer free(c)
	client_start(c, number, "localhost:8443", &roots, identity)
	conn, error := socket_open(c)
	fmt.printf("OPEN error=%v status=%d\n", error.kind, conn.status)
	assert(error.kind == .None && conn.status == 200)
	assert(socket_protocol(conn) == "chat.v2")
	conn2, error2 := socket_open(c)
	assert(error2.kind == .None && socket_protocol(conn2) == "chat.v2")
	// A websocket whose reads wait too long fails: nothing arrives within its
	// idle timeout, so the read ends with .Timeout instead of blocking.
	conn3, error3 := socket_open(c, {idle_timeout = 500 * time.Millisecond, ping_interval = async.WS_PING_OFF})
	assert(error3.kind == .None)
	_, expired, expired_error := socket_receive(conn3)
	assert(expired_error.kind != .None && expired == nil && conn3.close.reason == .Timeout)
	socket_wait(conn3)
	socket_destroy(conn3)
	for _ in 0 ..< 6 {
		_ = health(c)
	}
	seen := health(c)
	if identity != nil {
		expected := identity_text(identity)
		assert(seen == expected)
	}
	if replacement_cert != "" {
		// A rotated identity is presented on exactly one new lane: the pool
		// does not reuse a lane whose credentials are stale.
		old := identity_text(identity)
		dials := sync.atomic_load(&c.dials)
		identity_replace(identity, replacement_cert, replacement_key)
		expected := identity_text(identity)
		assert(expected != old)
		seen = health(c)
		assert(seen == expected)
		assert(sync.atomic_load(&c.dials) == dials + 1)
	}
	assert(socket_send(conn, .Text, transmute([]u8)string("native-hello")).kind == .None)
	kind, data, read := socket_receive(conn)
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
	assert(socket_send(conn, .Binary, payload).kind == .None)
	kind, data, read = socket_receive(conn)
	fmt.printf("LARGE kind=%v n=%d opcode=%v\n", read.kind, len(data), kind)
	assert(read.kind == .None && kind == .Binary && len(data) == len(payload) && bytes.equal(payload, data))
	delete(data, rt.heap_allocator())
	assert(socket_close(conn).kind == .None)
	assert(conn.close.reason == .Local_Close && conn.close.clean)
	assert(socket_send(conn2, .Text, transmute([]u8)string("second-stream")).kind == .None)
	kind, data, read = socket_receive(conn2)
	assert(read.kind == .None && string(data) == "second-stream")
	delete(data, rt.heap_allocator())
	assert(socket_close(conn2).kind == .None)
	assert(conn2.close.reason == .Local_Close && conn2.close.clean)
	_ = health(c, "AFTER")
	inserts: u64
	with_pool(c, lanes_inserted, &inserts)
	assert(inserts > 0)
	// A websocket still open when the client goes away is reset with
	// H3_REQUEST_CANCELLED, and its tunnel gives back everything it held.
	live, live_error := socket_open(c)
	assert(live_error.kind == .None)
	socket_cancel(live)
	assert(live.ended && live.tunnel._self == nil && live.close.reason == .Cancelled)
	socket_destroy(live)
	socket_destroy(conn)
	socket_destroy(conn2)
	assert(client_drain(c))
	client_stop(c)
	if identity != nil {
		view, e := store.stats(identity)
		assert(e.kind == .None && view.active_leases == 0)
	}
	fmt.println("OK native-http3-websocket")
}
negative :: proc(port, cert_path: string) {
	roots: tls.Root_Pool
	assert(tls.root_pool_load_file(&roots, cert_path) == nil)
	defer tls.root_pool_destroy(&roots)
	number, number_ok := strconv.parse_int(port)
	assert(number_ok)
	c := new(Client)
	defer free(c)
	authority := fmt.aprintf("localhost:%s", port)
	defer delete(authority)
	client_start(c, number, authority, &roots, nil)
	socket, error := socket_open(c)
	socket_wait(socket)
	fmt.printf("NEGATIVE error=%v failure=%v client=%v\n", error.kind, socket.failure.error.kind, socket.failure.client)
	// The server did not enable extended CONNECT: the tunnel fails before its
	// request is sent (the peer fails the run if a CONNECT arrives), no
	// answer came, and the tunnel freed what it held.
	assert(error.kind != .None && socket.status == 0 && socket.tunnel._self == nil)
	assert(socket.failure.error.kind != .None)
	socket_destroy(socket)
	client_stop(c)
	fmt.println("OK no CONNECT before negotiation")
}
main :: proc() {
	context.logger = log.nil_logger()
	assert(len(os.args) >= 4)

	if os.args[1] == "server" {
		server(os.args[2], os.args[3])
	} else if os.args[1] == "server-load" {
		assert(len(os.args) == 4)
		server(os.args[2], os.args[3], "", true)
	} else if os.args[1] == "server-mtls" {
		assert(len(os.args) == 5)
		server(os.args[2], os.args[3], os.args[4])
	} else if os.args[1] == "client-mtls" {
		assert(len(os.args) == 8)
		client(os.args[2], os.args[3], os.args[4], os.args[5], os.args[6], os.args[7])
	} else if os.args[1] == "negative" {
		negative(os.args[2], os.args[3])
	} else {
		client(os.args[2], os.args[3])
	}
}
