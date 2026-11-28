package saba_core

import "core:log"
import "core:net"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:time"

@(test)
listen_backlog_defaults_and_rejects_values_core_net_cannot_take :: proc(t: ^testing.T) {
	for item in ([]struct {
			requested, resolved: int,
			valid:               bool,
		} {
			{0, DEFAULT_LISTEN_BACKLOG, true},
			{1, 1, true},
			{4096, 4096, true},
			{int(max(i32)) - 1, int(max(i32)) - 1, true},
			{-1, 0, false},
			{int(max(i32)), 0, false},
		}) {
		resolved, valid := listen_backlog(item.requested)
		testing.expectf(t, valid == item.valid && resolved == item.resolved, "%d -> %d %v", item.requested, resolved, valid)
	}
}

@(test)
serve_rejects_an_invalid_backlog_before_binding :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()

	for backlog in ([]int{-1, int(max(i32))}) {
		// The remembered stop makes a server that did bind return success.
		control: Server_Control
		stop_server(&control)
		config := Server {
			control = &control,
			backlog = backlog,
			handler = proc(_: rawptr, _: ^Connection, _: ^Request) -> Response {return {}},
		}

		testing.expectf(t, !serve(config), "backlog %d", backlog)
	}
}

@(test)
server_with_a_small_backlog_serves_requests :: proc(t: ^testing.T) {
	fixture: H1_Fixture
	endpoint, ready := h1_start(t, &fixture, {backlog = 1})
	defer h1_stop(&fixture)
	testing.expect(t, ready)
	if !ready {
		return
	}

	for _ in 0 ..< 3 {
		wire := h1_exchange(endpoint, "GET / HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n")
		defer delete(wire)
		testing.expect(t, strings.has_prefix(string(wire[:]), "HTTP/1.1 200"))
	}
	// A later Unsupported_Socket is a pending connection's error, not the listener's.
	sync.lock(&fixture.control._mutex)
	accepted := fixture.control._server != nil && fixture.control._server.accepted
	sync.unlock(&fixture.control._mutex)
	testing.expect(t, accepted)
}

server_runtime_polls_on_a_dedicated_thread :: proc(control: ^Server_Control) -> (dedicated, published: bool) {
	sync.lock(&control._mutex)
	defer sync.unlock(&control._mutex)
	if control._server == nil {
		return false, false
	}

	return control._server.executor.scheduler.dedicated, true
}

@(test)
dedicated_poller_is_opt_in_and_reaches_the_runtime :: proc(t: ^testing.T) {
	for enabled in ([]bool{false, true}) {
		fixture: H1_Fixture
		endpoint, ready := h1_start(t, &fixture, {dedicated_poller = enabled})
		testing.expect(t, ready)
		if ready {
			dedicated, published := server_runtime_polls_on_a_dedicated_thread(&fixture.control)
			testing.expectf(t, published && dedicated == enabled, "dedicated_poller=%v: runtime dedicated=%v", enabled, dedicated)
			wire := h1_exchange(endpoint, "GET / HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n")
			testing.expect(t, strings.has_prefix(string(wire[:]), "HTTP/1.1 200"))
			delete(wire)
		}
		h1_stop(&fixture)
	}
}

// A program the application starts must not inherit accepted connections: it
// would keep the peer's connection open after Saba closed it.
@(test)
accepted_connections_are_close_on_exec :: proc(t: ^testing.T) {
	fixture: H1_Fixture
	endpoint, ready := h1_start(t, &fixture, {})
	defer h1_stop(&fixture)
	if !testing.expect(t, ready) {
		return
	}
	client, dialed := net.dial_tcp(endpoint)
	if !testing.expect(t, dialed == nil) {
		return
	}
	defer net.close(client)
	local, bound := net.bound_endpoint(client)
	if !testing.expect(t, bound == nil) {
		return
	}

	// The accepted end is the descriptor in this process whose peer is the
	// client's local port.
	deadline := time.tick_add(time.tick_now(), 30 * time.Second)
	for time.tick_since(deadline) < 0 {
		for fd in 3 ..< 1024 {
			if fd == int(client) {
				continue
			}
			peer, known := net.peer_endpoint(net.TCP_Socket(fd))
			if known != nil || peer.port != local.port {
				continue
			}
			if posix.fcntl(posix.FD(fd), .GETFD) & i32(posix.FD_CLOEXEC) != 0 {
				return
			}
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, false, "the accepted connection is inherited by programs the process starts")
}
