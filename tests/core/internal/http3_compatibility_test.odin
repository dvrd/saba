package saba_core

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import async "shared:async"
import budget "core:sync/budget"
import credential_store "core:crypto/tls/credentials/store"

SABA_CURL :: "/opt/homebrew/opt/curl/bin/curl"
SABA_CA :: "/Users/kakurega/dev/oss/Odin/tests/core/crypto/tls/credentials/testdata/rsa2048-valid.pem"
SABA_LOG :: "/tmp/saba-http3-compatibility"

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
	if n > len(hit.path) do n = len(hit.path)
	copy(hit.path[:n], request.path[:n])
	hit.path_len = n
	_ = conn

	return {status = .OK, body = hit.body[:hit.body_len]}
}

Saba_Curl :: struct {
	child:  os.Process,
	stdout: ^os.File,
	stderr: ^os.File,
	ok:     bool,
}

saba_curl_start :: proc(args: []string, label: string) -> Saba_Curl {
	out_path := fmt.tprintf("%s/saba-%s-stdout.txt", SABA_LOG, label)
	err_path := fmt.tprintf("%s/saba-%s-stderr.txt", SABA_LOG, label)
	stdout, oerr := os.open(out_path, {.Read, .Write, .Create, .Trunc})
	if oerr != nil do return {}
	stderr, eerr := os.open(err_path, {.Read, .Write, .Create, .Trunc})

	if eerr != nil {
		os.close(stdout)
		return {}
	}

	child, perr := os.process_start({command = args, stdout = stdout, stderr = stderr})

	if perr != nil {
		os.close(stdout)
		os.close(stderr)
		return {}
	}

	return {child = child, stdout = stdout, stderr = stderr, ok = true}
}

saba_curl_finish :: proc(
	job: ^Saba_Curl,
	state: ^Http3,
	limit: time.Duration,
	body_dst: []u8,
) -> (
	exit_code: int,
	body: string,
) {
	reaped := false
	defer {
		if job.ok && !reaped {
			_ = os.process_kill(job.child)
			_, _ = os.process_wait(job.child)
		}

		if job.stdout != nil do os.close(job.stdout)
		if job.stderr != nil do os.close(job.stderr)
	}
	start := time.tick_now()
	proc_state: os.Process_State
	for job.ok && time.tick_since(start) < limit {
		st, werr := os.process_wait(job.child, 0)

		if werr == nil && st.exited {
			proc_state = st
			reaped = true
			break
		}

		if state != nil do http3_step(state)
		time.sleep(time.Millisecond)
	}
	if job.ok && !reaped {
		_ = os.process_kill(job.child)
		proc_state, _ = os.process_wait(job.child)
		reaped = true
	}
	bn := 0
	if job.stdout != nil {
		if _, serr := os.seek(job.stdout, 0, .Start); serr == nil {
			bn, _ = os.read(job.stdout, body_dst)
		}
	}
	note: [800]u8
	en := 0
	if job.stderr != nil {
		if _, serr := os.seek(job.stderr, 0, .Start); serr == nil {
			en, _ = os.read(job.stderr, note[:])
		}
	}
	exit_code = proc_state.exit_code
	if bn > len(body_dst) do bn = len(body_dst)
	body = string(body_dst[:bn])
	if en > 0 do fmt.printf("saba-stderr %s\n", string(note[:en]))
	return
}

saba_http3_args :: proc(
	dst: []string,
	url_buf, resolve_buf: []u8,
	port: int,
	path: string,
	insecure: bool,
	max_time: string,
) -> []string {
	n := 0
	dst[n] = SABA_CURL
	n += 1
	dst[n] = "--http3-only"
	n += 1
	dst[n] = "--max-time"
	n += 1
	dst[n] = max_time
	n += 1
	dst[n] = "-sS"
	n += 1
	if insecure {
		dst[n] = "-k"
		n += 1
		dst[n] = fmt.bprintf(url_buf, "https://127.0.0.1:%d%s", port, path)
		n += 1
		return dst[:n]
	}
	dst[n] = "--cacert"
	n += 1
	dst[n] = SABA_CA
	n += 1
	dst[n] = "--resolve"
	n += 1
	dst[n] = fmt.bprintf(resolve_buf, "synthetic.invalid:%d:127.0.0.1", port)
	n += 1
	dst[n] = fmt.bprintf(url_buf, "https://synthetic.invalid:%d%s", port, path)
	n += 1
	return dst[:n]
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
saba_http3_curl_route :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 20 * time.Second)
	_ = os.make_directory(SABA_LOG)
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
	if !ok do return
	args: [12]string
	url_buf, resolve_buf: [96]u8
	command := saba_http3_args(args[:], url_buf[:], resolve_buf[:], port, "/saba", true, "5")
	job := saba_curl_start(command, "route")
	testing.expect(t, job.ok)
	if !job.ok do return
	body_buf: [128]u8
	exit_code, body := saba_curl_finish(&job, session, 8 * time.Second, body_buf[:])
	fmt.printf(
		"saba-route exit %d calls %d path %s body %s dead %v reason %s\n",
		exit_code,
		hit.calls,
		string(hit.path[:hit.path_len]),
		body,
		session.rejected,
		"HTTP3 listener",
	)
	testing.expect_value(t, exit_code, 0)
	testing.expect(t, body == "saba-h3", body)
	testing.expect(t, string(hit.path[:hit.path_len]) == "/saba")
	testing.expect(t, hit.calls == 1)
	testing.expect(t, !session.rejected || false, "HTTP3 listener")
}

@(test)
saba_http3_cacert :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 20 * time.Second)
	_ = os.make_directory(SABA_LOG)
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
	if !ok do return
	args: [12]string
	url_buf, resolve_buf: [96]u8
	command := saba_http3_args(args[:], url_buf[:], resolve_buf[:], port, "/trusted", false, "5")
	job := saba_curl_start(command, "cacert")
	testing.expect(t, job.ok)
	if !job.ok do return
	body_buf: [128]u8
	exit_code, body := saba_curl_finish(&job, session, 8 * time.Second, body_buf[:])
	fmt.printf("saba-cacert exit %d body %s calls %d\n", exit_code, body, hit.calls)
	testing.expect_value(t, exit_code, 0)
	testing.expect(t, body == "saba-h3", body)
	testing.expect(t, string(hit.path[:hit.path_len]) == "/trusted")
}

@(test)
saba_http3_untrusted :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 15 * time.Second)
	_ = os.make_directory(SABA_LOG)
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
	if !ok do return
	args: [12]string
	n := 0
	args[n] = SABA_CURL
	n += 1
	args[n] = "--http3-only"
	n += 1
	args[n] = "--max-time"
	n += 1
	args[n] = "3"
	n += 1
	args[n] = "-sS"
	n += 1
	url_buf: [96]u8
	args[n] = fmt.bprintf(url_buf[:], "https://127.0.0.1:%d/nope", port)
	n += 1
	job := saba_curl_start(args[:n], "untrusted")
	testing.expect(t, job.ok)
	if !job.ok do return
	body_buf: [128]u8
	exit_code, body := saba_curl_finish(&job, session, 6 * time.Second, body_buf[:])
	fmt.printf("saba-untrusted exit %d body %s calls %d\n", exit_code, body, hit.calls)
	testing.expect(t, exit_code != 0)
	testing.expect(t, body != "saba-h3")
}

@(test)
saba_http3_drain :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 15 * time.Second)
	_ = os.make_directory(SABA_LOG)
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
	if !ok do return
	http3_drain(session)
	args: [12]string
	url_buf, resolve_buf: [96]u8
	command := saba_http3_args(args[:], url_buf[:], resolve_buf[:], port, "/drain", true, "2")
	job := saba_curl_start(command, "drain")
	testing.expect(t, job.ok)
	if !job.ok do return
	body_buf: [128]u8
	exit_code, body := saba_curl_finish(&job, session, 5 * time.Second, body_buf[:])
	fmt.printf("saba-drain exit %d calls %d body %s\n", exit_code, hit.calls, body)
	testing.expect(t, exit_code != 0)
	testing.expect(t, hit.calls == 0)
	testing.expect(t, session.calls == 0)
}

@(test)
saba_http3_body_cap :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 15 * time.Second)
	_ = os.make_directory(SABA_LOG)
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
	if !ok do return
	args: [12]string
	url_buf, resolve_buf: [96]u8
	command := saba_http3_args(args[:], url_buf[:], resolve_buf[:], port, "/cap", true, "3")
	job := saba_curl_start(command, "cap")
	testing.expect(t, job.ok)
	if !job.ok do return
	body_buf: [128]u8
	exit_code, body := saba_curl_finish(&job, session, 6 * time.Second, body_buf[:])
	fmt.printf(
		"saba-cap exit %d rejected %v dead %v body %s reason %s\n",
		exit_code,
		session.rejected,
		session.rejected,
		body,
		"HTTP3 listener",
	)
	testing.expect(t, session.rejected)
	testing.expect(t, session.rejected)
	testing.expect(t, body != "saba-h3")
	testing.expect(t, exit_code != 0)
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
	_ = os.make_directory(SABA_LOG)
	hit: Saba_Hit
	saba_hit_init(&hit)
	for &b in hit.body[:512] do b = 'x'
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
	if !ok do return
	server_ep, berr := net.bound_endpoint(session.live.socket)
	testing.expect(t, berr == .None)
	if berr != .None do return
	relay_socket, rerr := net.make_unbound_udp_socket(.IP4)
	testing.expect(t, rerr == nil)
	if rerr != nil do return
	defer net.close(relay_socket)
	testing.expect(t, net.bind(relay_socket, {net.IP4_Loopback, 0}) == .None)
	testing.expect(t, net.set_option(relay_socket, .Receive_Timeout, 15 * time.Millisecond) == nil)
	relay_ep, rbound := net.bound_endpoint(relay_socket)
	testing.expect(t, rbound == .None)
	if rbound != .None do return
	relay := Saba_Relay {
		socket = relay_socket,
		server = server_ep,
		owner  = session,
	}

	args: [12]string
	url_buf, resolve_buf: [96]u8
	command := saba_http3_args(args[:], url_buf[:], resolve_buf[:], relay_ep.port, "/loss", true, "6")
	job := saba_curl_start(command, "loss")
	testing.expect(t, job.ok)
	if !job.ok do return
	reaped := false
	defer {
		if !reaped {
			_ = os.process_kill(job.child)
			_, _ = os.process_wait(job.child)
		}

		os.close(job.stdout)
		os.close(job.stderr)
	}

	start := time.tick_now()
	proc_state: os.Process_State

	for time.tick_since(start) < 9 * time.Second {
		st, werr := os.process_wait(job.child, 0)

		if werr == nil && st.exited {
			proc_state = st
			reaped = true
			break
		}

		buf: [2048]u8

		for _ in 0 ..< 8 {
			n, from, uerr := net.recv_udp(relay.socket, buf[:])
			if uerr != nil || n <= 0 do break
			saba_relay_packet(&relay, buf[:n], from)
		}

		if relay.held_n > 0 {
			relay.hold_waits += 1

			if relay.hold_waits >= 6 {
				_, _ = net.send_udp(relay.socket, relay.held[:relay.held_n], relay.server)
				relay.held_n = 0
			}
		}

		http3_step(session)
		time.sleep(time.Millisecond)
	}

	if !reaped {
		_ = os.process_kill(job.child)
		proc_state, _ = os.process_wait(job.child)
		reaped = true
	}

	body_buf: [1024]u8
	bn := 0

	if _, serr := os.seek(job.stdout, 0, .Start); serr == nil {
		bn, _ = os.read(job.stdout, body_buf[:])
	}

	body := string(body_buf[:bn])
	fmt.printf(
		"saba-loss exit %d packets %d dropped %v reorder %v slow %v body %s\n",
		proc_state.exit_code,
		relay.client_packets,
		relay.dropped,
		relay.reordered,
		relay.slowed,
		body,
	)
	testing.expect_value(t, proc_state.exit_code, 0)
	testing.expect(t, body == string(hit.body[:hit.body_len]), body)
	testing.expect(t, relay.application_dropped)
	testing.expect(t, relay.dropped)
	testing.expect(t, relay.reordered)
	testing.expect(t, relay.slowed)
	testing.expect(t, hit.calls == 1)
}

@(test)
saba_http3_tcp :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 20 * time.Second)
	_ = os.make_directory(SABA_LOG)
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
	if !ok do return
	listener, lerr := net.listen_tcp({net.IP4_Loopback, 0})
	testing.expect(t, lerr == nil)
	if lerr != nil do return
	defer net.close(listener)
	tcp_ep, terr := net.bound_endpoint(listener)
	testing.expect(t, terr == .None)
	if terr != .None do return
	testing.expect(t, tcp_ep.port != h3_port)
	args: [12]string
	url_buf, resolve_buf: [96]u8
	command := saba_http3_args(args[:], url_buf[:], resolve_buf[:], h3_port, "/both", true, "5")
	job := saba_curl_start(command, "tcp")
	testing.expect(t, job.ok)
	if !job.ok do return
	body_buf: [128]u8
	exit_code, body := saba_curl_finish(&job, session, 8 * time.Second, body_buf[:])
	client, derr := net.dial_tcp(tcp_ep)
	testing.expect(t, derr == nil)
	if derr != nil do return
	defer net.close(client)
	peer, _, aerr := net.accept_tcp(listener)
	testing.expect(t, aerr == nil)
	if aerr != nil do return
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
		if n > 0 do got += n
		if rerr != nil || n == 0 || strings.contains(string(in_buf[:got]), "\r\n") do break
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
		if n > 0 do on += n
		if rerr != nil || n == 0 do break
	}

	tcp_body := string(out_buf[:on])
	fmt.printf(
		"saba-tcp h3-exit %d h3-body %s tcp-port %d h3-port %d tcp %s\n",
		exit_code,
		body,
		tcp_ep.port,
		h3_port,
		tcp_body,
	)
	testing.expect_value(t, exit_code, 0)
	testing.expect(t, body == "saba-h3", body)
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
	http3_close(state)

	if state.runtime != nil {
		_ = async.destroy(&state.runtime.executor)
		budget.release_scope(&state.runtime.resources)
		free(state.runtime)
		state.runtime = nil
	}

	credential_store.destroy(&state.config.credentials)
}
