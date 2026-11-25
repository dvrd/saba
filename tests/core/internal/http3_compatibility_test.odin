package saba_core

import http3 "shared:async/http/v3"
import "core:fmt"
import "core:net"
import "core:thread"
import "core:strings"
import "core:testing"
import "core:time"
import async "shared:async"
import budget "shared:async/sync/budget"
import credential_store "shared:async/tls/credentials/store"

Saba_Hit :: struct {
	calls:    int,
	path:     [160]u8,
	path_len: int,
	body:     [1024]u8,
	body_len: int,
}

saba_hit_init :: proc(hit: ^Saba_Hit) {
	text := "saba-h3"
	copy(hit.body[:], text)
	hit.body_len = len(text)
}

saba_hit_handler :: proc(data: rawptr, conn: ^Connection, request: ^Request) -> Response {
	hit := cast(^Saba_Hit)data
	hit.calls += 1
	n := len(request.path)
	if n > len(hit.path) {
		n = len(hit.path)
	}
	copy(hit.path[:n], request.path[:n])
	hit.path_len = n
	_ = conn

	return {status = .OK, body = hit.body[:hit.body_len]}
}

@(test)
saba_http3_disabled :: proc(t: ^testing.T) {
	hit: Saba_Hit
	saba_hit_init(&hit)
	off := new(Http3)
	defer free(off)
	off.config.handler = saba_hit_handler
	off.config.handler_data = &hit
	port, ok := http3_listen(off)
	fmt.printf("saba-disabled port %d ok %v\n", port, ok)
	testing.expect(t, !ok && port == 0)
	bare := new(Http3)
	defer free(bare)
	bare.config.enabled = true
	port, ok = http3_listen(bare)
	fmt.printf("saba-no-handler port %d ok %v\n", port, ok)
	testing.expect(t, !ok && port == 0)
}

@(test)
saba_http3_route :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 20 * time.Second)
	hit: Saba_Hit
	saba_hit_init(&hit)
	session := new(Http3)
	defer free(session)
	defer saba_http3_fixture_destroy(session)
	session.config = {
		enabled      = true,
		handler      = saba_hit_handler,
		handler_data = &hit,
	}

	saba_http3_fixture(t, session)
	port, ok := http3_listen(session)
	testing.expect(t, ok, "HTTP3 listener")
	if !ok {
		return
	}
	result := h3_test_exchange(port, {target = "/saba"}, 5 * time.Second, session)
	testing.expect(t, result.error == .None, h3_test_error(&result))
	testing.expect_value(t, result.status, 200)
	testing.expect_value(t, h3_test_body(&result), "saba-h3")
	testing.expect_value(t, string(hit.path[:hit.path_len]), "/saba")
	testing.expect_value(t, hit.calls, 1)
	testing.expect(t, !session.rejected)
}

@(test)
saba_http3_trusted_certificate :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 20 * time.Second)
	hit: Saba_Hit
	saba_hit_init(&hit)
	session := new(Http3)
	defer free(session)
	defer saba_http3_fixture_destroy(session)
	session.config = {
		enabled      = true,
		handler      = saba_hit_handler,
		handler_data = &hit,
	}

	saba_http3_fixture(t, session)
	port, ok := http3_listen(session)
	testing.expect(t, ok, "HTTP3 listener")
	if !ok {
		return
	}
	result := h3_test_exchange(port, {target = "/trusted"}, 5 * time.Second, session)
	testing.expect(t, result.error == .None, h3_test_error(&result))
	testing.expect_value(t, result.status, 200)
	testing.expect_value(t, h3_test_body(&result), "saba-h3")
	testing.expect_value(t, string(hit.path[:hit.path_len]), "/trusted")
}

@(test)
saba_http3_untrusted :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 15 * time.Second)
	hit: Saba_Hit
	saba_hit_init(&hit)
	session := new(Http3)
	defer free(session)
	defer saba_http3_fixture_destroy(session)
	session.config = {
		enabled      = true,
		handler      = saba_hit_handler,
		handler_data = &hit,
	}

	saba_http3_fixture(t, session)
	port, ok := http3_listen(session)
	testing.expect(t, ok, "HTTP3 listener")
	if !ok {
		return
	}
	result := h3_test_exchange(port, {target = "/nope"}, 3 * time.Second, session, untrusted = true)
	testing.expect(t, result.error == .Certificate, h3_test_error(&result))
	testing.expect_value(t, hit.calls, 0)
}

@(test)
saba_http3_drain :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 15 * time.Second)
	hit: Saba_Hit
	saba_hit_init(&hit)
	session := new(Http3)
	defer free(session)
	defer saba_http3_fixture_destroy(session)
	session.config = {
		enabled      = true,
		handler      = saba_hit_handler,
		handler_data = &hit,
	}

	saba_http3_fixture(t, session)
	port, ok := http3_listen(session)
	testing.expect(t, ok, "HTTP3 listener")
	if !ok {
		return
	}
	http3.listener_drain(&session.live)
	result := h3_test_exchange(port, {target = "/drain"}, 2 * time.Second, session)
	testing.expect(t, result.error != .None)
	testing.expect_value(t, hit.calls, 0)
	testing.expect_value(t, session.calls, 0)
}

@(test)
saba_http3_body_cap :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 15 * time.Second)
	hit: Saba_Hit
	saba_hit_init(&hit)
	session := new(Http3)
	defer free(session)
	defer saba_http3_fixture_destroy(session)
	session.config = {
		enabled      = true,
		handler      = saba_hit_handler,
		handler_data = &hit,
		max_body     = 4,
	}

	saba_http3_fixture(t, session)
	port, ok := http3_listen(session)
	testing.expect(t, ok, "HTTP3 listener")
	if !ok {
		return
	}
	result := h3_test_exchange(port, {target = "/cap"}, 3 * time.Second, session)
	testing.expect(t, session.rejected)
	testing.expect(t, result.error != .None)
	testing.expect(t, h3_test_body(&result) != "saba-h3")
}

Saba_Relay :: struct {
	socket:              net.UDP_Socket,
	server:              net.Endpoint,
	owner:               ^Http3,
	application_dropped: bool,
	client:              net.Endpoint,
	have_client:         bool,
	client_packets:      int,
	dropped:             bool,
	reordered:           bool,
	slowed:              bool,
	held:                [2048]u8,
	held_n:              int,
	hold_waits:          int,
}

saba_relay_packet :: proc(relay: ^Saba_Relay, packet: []u8, from: net.Endpoint) {
	if from.port == relay.server.port {
		prepared := false

		if relay.owner != nil {
			for p in relay.owner.live.peers {
				if p != nil && p.response_built {
					prepared = true
					break
				}
			}
		}

		// A large short-header packet after response preparation contains adopted
		// application STREAM payload, rather than the earlier TLS CRYPTO flights.
		if prepared && !relay.application_dropped && len(packet) > 150 && packet[0] & 0x80 == 0 {
			relay.application_dropped = true
			fmt.printf("saba-relay dropped adopted response packet bytes=%d\n", len(packet))
			return
		}

		if relay.have_client {
			_, _ = net.send_udp(relay.socket, packet, relay.client)
		}

		return
	}

	relay.client = from
	relay.have_client = true
	relay.client_packets += 1

	if !relay.dropped && relay.client_packets == 2 {
		relay.dropped = true
		return
	}

	if relay.held_n == 0 && !relay.reordered && relay.client_packets == 4 {
		n := copy(relay.held[:], packet)
		relay.held_n = n
		return
	}

	if !relay.slowed && relay.client_packets >= 5 {
		time.sleep(200 * time.Millisecond)
		relay.slowed = true
	}

	_, _ = net.send_udp(relay.socket, packet, relay.server)

	if relay.held_n > 0 {
		_, _ = net.send_udp(relay.socket, relay.held[:relay.held_n], relay.server)
		relay.held_n = 0
		relay.reordered = true
	}
}

@(test)
saba_http3_loss :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 20 * time.Second)
	hit: Saba_Hit
	saba_hit_init(&hit)
	for &b in hit.body[:512] {
		b = 'x'
	}
	hit.body_len = 512
	session := new(Http3)
	defer free(session)
	defer saba_http3_fixture_destroy(session)
	session.config = {
		enabled      = true,
		handler      = saba_hit_handler,
		handler_data = &hit,
	}

	saba_http3_fixture(t, session)
	_, ok := http3_listen(session)
	testing.expect(t, ok, "HTTP3 listener")
	if !ok {
		return
	}
	server_ep, berr := net.bound_endpoint(session.live.socket)
	testing.expect(t, berr == .None)
	if berr != .None {
		return
	}
	relay_socket, rerr := net.make_unbound_udp_socket(.IP4)
	testing.expect(t, rerr == nil)
	if rerr != nil {
		return
	}
	defer net.close(relay_socket)
	testing.expect(t, net.bind(relay_socket, {net.IP4_Loopback, 0}) == .None)
	testing.expect(t, net.set_option(relay_socket, .Receive_Timeout, 15 * time.Millisecond) == nil)
	relay_ep, rbound := net.bound_endpoint(relay_socket)
	testing.expect(t, rbound == .None)
	if rbound != .None {
		return
	}
	relay := Saba_Relay {
		socket = relay_socket,
		server = server_ep,
		owner  = session,
	}

	client := H3_Test_Client {endpoint = relay_ep, request = {target = "/loss"}, timeout = 8 * time.Second}
	h3_test_client_start(&client)
	defer h3_test_client_cancel(&client)

	for !thread.is_done(client.worker) {
		buf: [2048]u8
		for _ in 0 ..< 8 {
			n, from, error := net.recv_udp(relay.socket, buf[:])
			if error != nil || n <= 0 {
				break
			}
			saba_relay_packet(&relay, buf[:n], from)
		}
		if relay.held_n > 0 {
			relay.hold_waits += 1
			if relay.hold_waits >= 6 {
				_, _ = net.send_udp(relay.socket, relay.held[:relay.held_n], relay.server)
				relay.held_n = 0
			}
		}
		if !http3.listener_step(&session.live) {
			h3_test_client_cancel(&client)
			break
		}
		time.sleep(time.Millisecond)
	}

	h3_test_client_join(&client)
	testing.expect(t, client.result.error == .None, h3_test_error(&client.result))
	testing.expect_value(t, client.result.status, 200)
	testing.expect_value(t, h3_test_body(&client.result), string(hit.body[:hit.body_len]))
	testing.expect(t, relay.application_dropped)
	testing.expect(t, relay.dropped)
	testing.expect(t, relay.reordered)
	testing.expect(t, relay.slowed)
	testing.expect_value(t, hit.calls, 1)
}

@(test)
saba_http3_tcp :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 20 * time.Second)
	hit: Saba_Hit
	saba_hit_init(&hit)
	session := new(Http3)
	defer free(session)
	defer saba_http3_fixture_destroy(session)
	session.config = {
		enabled      = true,
		handler      = saba_hit_handler,
		handler_data = &hit,
	}

	saba_http3_fixture(t, session)
	h3_port, ok := http3_listen(session)
	testing.expect(t, ok, "HTTP3 listener")
	if !ok {
		return
	}
	listener, lerr := net.listen_tcp({net.IP4_Loopback, 0})
	testing.expect(t, lerr == nil)
	if lerr != nil {
		return
	}
	defer net.close(listener)
	tcp_ep, terr := net.bound_endpoint(listener)
	testing.expect(t, terr == .None)
	if terr != .None {
		return
	}
	testing.expect(t, tcp_ep.port != h3_port)
	result := h3_test_exchange(h3_port, {target = "/both"}, 5 * time.Second, session)
	client, derr := net.dial_tcp(tcp_ep)
	testing.expect(t, derr == nil)
	if derr != nil {
		return
	}
	defer net.close(client)
	peer, _, aerr := net.accept_tcp(listener)
	testing.expect(t, aerr == nil)
	if aerr != nil {
		return
	}
	defer net.close(peer)
	_ = net.set_option(peer, .Receive_Timeout, 1 * time.Second)
	_ = net.set_option(client, .Receive_Timeout, 1 * time.Second)
	req_buf: [128]u8
	req := fmt.bprintf(req_buf[:], "GET /saba HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
	_, serr := net.send_tcp(client, transmute([]u8)req)
	testing.expect(t, serr == nil)
	in_buf: [512]u8
	got := 0

	for got < len(in_buf) {
		n, rerr := net.recv_tcp(peer, in_buf[got:])
		if n > 0 {
			got += n
		}
		if rerr != nil || n == 0 || strings.contains(string(in_buf[:got]), "\r\n") {
			break
		}
	}

	request := Request {
		method  = "GET",
		path    = "/saba",
		version = "HTTP/1.1",
	}

	response := saba_hit_handler(&hit, nil, &request)
	head_buf: [128]u8
	head := fmt.bprintf(
		head_buf[:],
		"HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n",
		len(response.body),
	)
	_, _ = net.send_tcp(peer, transmute([]u8)head)
	_, _ = net.send_tcp(peer, response.body)
	out_buf: [256]u8
	on := 0

	for on < len(out_buf) {
		n, rerr := net.recv_tcp(client, out_buf[on:])
		if n > 0 {
			on += n
		}
		if rerr != nil || n == 0 {
			break
		}
	}

	tcp_body := string(out_buf[:on])
	testing.expect(t, result.error == .None, h3_test_error(&result))
	testing.expect_value(t, result.status, 200)
	testing.expect_value(t, h3_test_body(&result), "saba-h3")
	testing.expect(t, strings.contains(tcp_body, "saba-h3"))
	testing.expect(t, hit.calls == 2)
}

// Compatibility harness owns all explicit test-only identity/runtime state.
saba_http3_fixture :: proc(t: ^testing.T, state: ^Http3) {
	runtime := new(Server_Runtime)
	runtime.config.handler = state.config.handler
	runtime.config.handler_data = state.config.handler_data
	runtime.timeouts = resolve_timeouts({})
	assert(initialize_resources(runtime))
	assert(async.init(&runtime.executor, {workers = 1, task_capacity = 4, io_capacity = 0}).kind == .None)
	state.runtime = runtime
	state.config.credentials = https80_make_store(t)
	state.config.endpoint = {net.IP4_Loopback, 0}
}
saba_http3_fixture_destroy :: proc(state: ^Http3) {
	http3.listener_close(&state.live)

	if state.runtime != nil {
		_ = async.destroy(&state.runtime.executor)
		budget.release_scope(&state.runtime.resources)
		free(state.runtime)
		state.runtime = nil
	}

	credential_store.destroy(&state.config.credentials)
}
