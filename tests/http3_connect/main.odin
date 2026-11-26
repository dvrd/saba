package main

import core "shared:saba/core"
import ws "shared:saba/websocket"
import surf "shared:surf"
import codec "shared:async/websocket"
import tls "shared:async/tls"
import credentials "shared:async/tls/credentials"
import store "shared:async/tls/credentials/store"
import budget "shared:async/sync/budget"
import rt "base:runtime"
import "core:fmt"
import "core:bytes"
import "core:log"
import "core:mem"
import "core:net"
import h3 "shared:async/http/v3"
import "core:os"
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
identity_check :: proc(identity: ^store.Store, response: ^surf.Response) {
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

	actual, found := surf.response_header(response, "x-client-identity")
	assert(found && actual == string(text[:]))
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
	pool: h3.Pool
	defer h3.pool_close(&pool)
	cache: surf.Alt_Svc_Cache
	value := fmt.aprintf("h3=\":%s\"; ma=60", port)
	defer delete(value)
	assert(surf.alt_svc_note(&cache, "localhost", value, true, true, time.now(), 8443))
	http: surf.HTTP_Client
	protocols := [2]string{"h2", "http/1.1"}
	assert(
		surf.http_client_init(&http, {tls = {root_cas = roots.roots[:roots.count], alpn_protocols = protocols[:], client_credentials = identity}, timeout = 5 * time.Second, http3 = true, http3_pool = &pool, alt_svc = &cache, http3_qpack = {table_capacity = 4096, blocked_streams = 4}}, {}, context.allocator).kind ==
		.None,
	)
	defer surf.http_client_close(&http)
	url := fmt.aprintf("https://localhost:8443/socket")
	defer delete(url)
	health := fmt.aprintf("https://localhost:8443/health")
	defer delete(health)
	conn: surf.WebSocket_Conn
	tunnel: surf.HTTP3_Tunnel
	error := surf.websocket_http3_open(
		&http,
		&tunnel,
		&conn,
		url,
		{origin = "https://allowed.invalid", subprotocols = {"chat.v2"}},
	)
	fmt.printf("OPEN error=%v phase=%v\n", error.kind, error.phase)
	assert(error.kind == .None)
	defer codec.message_release(&conn.message_state)
	assert(surf.websocket_subprotocol(&conn) == "chat.v2")
	conn2: surf.WebSocket_Conn
	tunnel2: surf.HTTP3_Tunnel
	assert(
		surf.websocket_http3_open(&http, &tunnel2, &conn2, url, {origin = "https://allowed.invalid", subprotocols = {"chat.v2"}}).kind ==
		.None,
	)
	defer codec.message_release(&conn2.message_state)
	conn3: surf.WebSocket_Conn
	tunnel3: surf.HTTP3_Tunnel
	assert(
		surf.websocket_http3_open(&http, &tunnel3, &conn3, url, {origin = "https://allowed.invalid", subprotocols = {"chat.v2"}}).kind ==
		.None,
	)
	tunnel3.read_deadline = time.time_add(time.now(), -time.Millisecond)
	expired: [1]u8
	_, _, expired_error := surf.websocket_read_message(&conn3, expired[:])
	assert(expired_error.kind != .None)
	codec.message_release(&conn3.message_state)
	for _ in 0 ..< 6 {
		health_response, health_error := surf.http_client_exchange(&http, {method = .GET, url = health})
		assert(health_error.kind == .None && string(health_response.body) == "http-ok")
		surf.response_destroy(&health_response)
	}
	response, re := surf.http_client_exchange(&http, {method = .GET, url = health})
	assert(re.kind == .None && string(response.body) == "http-ok")
	if identity != nil {
		identity_check(identity, &response)
	}
	surf.response_destroy(&response)
	if replacement_cert != "" {
		dials := surf.http_client_dials(&http)
		identity_replace(identity, replacement_cert, replacement_key)
		response, re = surf.http_client_exchange(&http, {method = .GET, url = health})
		assert(re.kind == .None && string(response.body) == "http-ok")
		identity_check(identity, &response)
		surf.response_destroy(&response)
		_ = dials
	}
	assert(surf.websocket_write_message(&conn, .Text, transmute([]u8)string("native-hello")).kind == .None)
	buffer: [128]u8
	opcode, n, read := surf.websocket_read_message(&conn, buffer[:])
	fmt.printf("READ kind=%v n=%d\n", read.kind, n)
	assert(read.kind == .None && opcode == .Text && string(buffer[:n]) == "native-hello")
	// This exceeds both the HTTP2 stream window and Saba's64KiB body queue.
	// Incremental backpressure must complete without buffering an unbounded body.
	payload := make([]u8, 128 * 1024)
	defer delete(payload)
	for &byte, i in payload {
		byte = u8(i % 251)
	}
	assert(surf.websocket_write_message(&conn, .Binary, payload).kind == .None)
	received := make([]u8, len(payload))
	defer delete(received)
	opcode, n, read = surf.websocket_read_message(&conn, received)
	fmt.printf("LARGE kind=%v n=%d opcode=%v\n", read.kind, n, opcode)
	assert(read.kind == .None && opcode == .Binary && n == len(payload) && bytes.equal(payload, received))
	assert(surf.websocket_close(&conn, 1000, "").kind == .None)
	assert(surf.websocket_write_message(&conn2, .Text, transmute([]u8)string("second-stream")).kind == .None)
	opcode, n, read = surf.websocket_read_message(&conn2, buffer[:])
	assert(read.kind == .None && string(buffer[:n]) == "second-stream")
	assert(surf.websocket_close(&conn2, 1000, "").kind == .None)
	response, re = surf.http_client_exchange(&http, {method = .GET, url = health})
	fmt.printf("AFTER kind=%v phase=%v status=%d body=%s\n", re.kind, re.phase, response.status, string(response.body))
	assert(re.kind == .None && string(response.body) == "http-ok")
	surf.response_destroy(&response)
	assert(pool.slots[0].client.qpack.stats.encoded_inserts > 0)
	live_tunnel: surf.HTTP3_Tunnel
	live_socket: surf.WebSocket_Conn
	assert(
		surf.websocket_http3_open(&http, &live_tunnel, &live_socket, url, {origin = "https://allowed.invalid", subprotocols = {"chat.v2"}}).kind ==
		.None,
	)
	surf.http_client_close(&http)
	assert(live_tunnel.wire.owner == nil)
	codec.message_release(&live_socket.message_state)
	h3.pool_close(&pool)
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
	pool: h3.Pool
	defer h3.pool_close(&pool)
	http: surf.HTTP_Client
	assert(
		surf.http_client_init(&http, {tls = {root_cas = roots.roots[:roots.count]}, http3 = true, http3_pool = &pool, timeout = 3 * time.Second}, {}, context.allocator).kind ==
		.None,
	)
	defer surf.http_client_close(&http)
	url := fmt.aprintf("https://localhost:%s/socket", port)
	defer delete(url)
	tunnel: surf.HTTP3_Tunnel
	connection: surf.WebSocket_Conn
	error := surf.websocket_http3_open(&http, &tunnel, &connection, url, {subprotocols = {"chat.v2"}})
	assert(error.kind != .None && error.write_effect == .Not_Sent && tunnel.wire.owner == nil)
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
