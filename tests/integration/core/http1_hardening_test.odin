package saba_core

import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:os"
import "core:strings"
import budget "shared:async/budget"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import async "shared:async"

H1_BODY_LIMIT :: 8 * mem.Megabyte

H1_Fixture :: struct {
	config:  Server,
	control: Server_Control,
	ok:      bool,
	worker:  ^thread.Thread,
	// Served by /big; borrowed from the test.
	big:     []u8,
}

h1_handler :: proc(data: rawptr, _: ^Connection, request: ^Request) -> Response {
	fixture := cast(^H1_Fixture)data

	switch request.path {
	case "/sum":
		sum := 0
		for value in request.body {
			sum += int(value)
		}
		text := fmt.aprintf("%d %d", len(request.body), sum, allocator = request.allocator)
		return make_response(request, .OK, {{"Content-Type", "application/octet-stream"}}, transmute([]u8)text)
	case "/big":
		return make_response(request, .OK, {{"Content-Type", "application/octet-stream"}}, fixture.big)
	case "/bad-value":
		return make_response(request, .OK, {{"X-Split", "one\r\nX-Injected: two"}}, transmute([]u8)string("x"))
	case "/reserved":
		return make_response(request, .OK, {{"Connection", "keep-alive"}}, transmute([]u8)string("x"))
	case "/length-ok":
		return make_response(request, .OK, {{"content-length", "5"}}, transmute([]u8)string("hello"))
	case "/length-bad":
		return make_response(request, .OK, {{"Content-Length", "9"}}, transmute([]u8)string("hello"))
	}

	return make_response(request, .OK, nil, transmute([]u8)string("ok"))
}

h1_start :: proc(t: ^testing.T, fixture: ^H1_Fixture, config: Server) -> (net.Endpoint, bool) {
	fixture.config = config
	if fixture.config.address == "" {
		fixture.config.address = "127.0.0.1"
	}
	fixture.config.handler = h1_handler
	fixture.config.handler_data = fixture
	fixture.config.control = &fixture.control
	fixture.config.workers = 2
	fixture.config.request_body_limit = proc(_: ^Request) -> int {return H1_BODY_LIMIT}
	fixture.worker = thread.create_and_start_with_poly_data(fixture, proc(f: ^H1_Fixture) {f.ok = serve(f.config)})
	assert(fixture.worker != nil)
	// A startup bound only: generous, since a loaded machine can take seconds
	// to start serve, and nothing here measures it.
	until := time.tick_add(time.tick_now(), 60 * time.Second)

	for !server_ready(&fixture.control) &&
	    !thread.is_done(fixture.worker) &&
	    time.tick_diff(time.tick_now(), until) > 0 {
		time.sleep(time.Millisecond)
	}

	endpoint, ready := server_endpoint(&fixture.control)

	return endpoint, ready && endpoint.port > 0
}

h1_stop :: proc(fixture: ^H1_Fixture) {
	stop_server(&fixture.control)
	thread.join(fixture.worker)
	thread.destroy(fixture.worker)
	fixture.worker = nil
}

h1_dial :: proc(endpoint: net.Endpoint) -> net.TCP_Socket {
	client, dial_error := net.dial_tcp(endpoint)
	assert(dial_error == nil)
	_ = net.set_option(client, .Receive_Timeout, 10 * time.Second)

	return client
}

h1_send :: proc(client: net.TCP_Socket, text: string) {
	_, send_error := net.send_tcp(client, transmute([]u8)text)
	assert(send_error == nil)
}

// Reads until the peer closes. The caller deletes the result.
h1_read_all :: proc(client: net.TCP_Socket) -> [dynamic]u8 {
	received: [dynamic]u8
	chunk: [16384]u8

	for {
		count, receive_error := net.recv_tcp(client, chunk[:])

		if count > 0 {
			append(&received, ..chunk[:count])
		}

		if count == 0 || receive_error != nil {
			break
		}
	}

	return received
}

h1_exchange :: proc(endpoint: net.Endpoint, request: string) -> [dynamic]u8 {
	client := h1_dial(endpoint)
	defer net.close(client)
	h1_send(client, request)

	return h1_read_all(client)
}

h1_payload :: proc(count: int) -> (data: []u8, sum: int) {
	data = make([]u8, count)
	for &value, index in data {
		value = u8(index * 7 + 3)
		sum += int(value)
	}

	return
}

@(test)
declared_body_length_reserves_no_storage_until_bytes_arrive :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()
	fixture: Resource_Test
	resource_test_init(&fixture)
	defer resource_test_finish(&fixture)
	defer release_request_body(&fixture.task)
	fixture.runtime.config.request_body_limit = proc(_: ^Request) -> int {return H1_BODY_LIMIT}
	// prepare_request replaces the request; keep the fixture's context for its teardown.
	saved := fixture.task.request.cancellation
	defer fixture.task.request.cancellation = saved

	for head in ([]string {
			"POST /sum HTTP/1.1\r\nHost: a\r\nContent-Length: 8388608\r\n\r\n",
			"POST /sum HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n",
		}) {
		release_request_body(&fixture.task)
		fixture.task.header = transmute([]u8)head
		fixture.task.header_used = len(head)
		fixture.task.body_used = 0

		if !testing.expect(t, prepare_request(&fixture.task)) {
			return
		}

		testing.expect_value(t, fixture.task.body_target, H1_BODY_LIMIT)
		testing.expect(t, len(fixture.task.request.body) <= REQUEST_BODY_INITIAL)
		view, error := budget.snapshot(fixture.runtime.resources)
		assert(error == .None)
		testing.expect(t, view.used.bytes < 256 * mem.Kilobyte, "an announced body must not be charged before it is sent")
	}

	// Storage doubles with the bytes received and stops exactly at the ceiling.
	fixture.task.body_used = len(fixture.task.request.body)
	previous := len(fixture.task.request.body)
	testing.expect(t, request_body_grow(&fixture.task))
	testing.expect_value(t, len(fixture.task.request.body), 2 * REQUEST_BODY_INITIAL)
	testing.expect(t, len(fixture.task.request.body) > previous)

	for len(fixture.task.request.body) < fixture.task.body_target {
		fixture.task.body_used = len(fixture.task.request.body)
		if !testing.expect(t, request_body_grow(&fixture.task)) {
			return
		}
	}

	testing.expect_value(t, len(fixture.task.request.body), H1_BODY_LIMIT)
	testing.expect(t, !request_body_grow(&fixture.task))
	grown, _ := budget.snapshot(fixture.runtime.resources)
	testing.expect(t, grown.used.bytes >= u64(H1_BODY_LIMIT))
	release_request_body(&fixture.task)
	released, _ := budget.snapshot(fixture.runtime.resources)
	testing.expect(t, released.used.bytes < 256 * mem.Kilobyte, "outgrown body storage is returned with the request")
}

@(test)
loopback_bodies_larger_than_the_first_block_arrive_intact :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	fixture: H1_Fixture
	endpoint, ready := h1_start(t, &fixture, {})
	defer h1_stop(&fixture)

	if !testing.expect(t, ready) {
		return
	}

	payload, sum := h1_payload(300 * mem.Kilobyte)
	defer delete(payload)
	expected := fmt.tprintf("%d %d", len(payload), sum)

	{
		client := h1_dial(endpoint)
		defer net.close(client)
		h1_send(client, fmt.tprintf("POST /sum HTTP/1.1\r\nHost: a\r\nContent-Length: %d\r\n\r\n", len(payload)))
		_, send_error := net.send_tcp(client, payload)
		assert(send_error == nil)
		wire := h1_read_all(client)
		defer delete(wire)
		testing.expect(t, strings.has_prefix(string(wire[:]), "HTTP/1.1 200"))
		testing.expect(t, strings.has_suffix(string(wire[:]), expected))
	}

	{
		client := h1_dial(endpoint)
		defer net.close(client)
		h1_send(client, "POST /sum HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n")

		for offset := 0; offset < len(payload); offset += 50000 {
			piece := payload[offset:min(offset + 50000, len(payload))]
			h1_send(client, fmt.tprintf("%x\r\n", len(piece)))
			_, send_error := net.send_tcp(client, piece)
			assert(send_error == nil)
			h1_send(client, "\r\n")
		}

		h1_send(client, "0\r\n\r\n")
		wire := h1_read_all(client)
		defer delete(wire)
		testing.expect(t, strings.has_prefix(string(wire[:]), "HTTP/1.1 200"))
		testing.expect(t, strings.has_suffix(string(wire[:]), expected))
	}

	// A chunked request used to reserve its whole 8 MiB limit up front.
	view, available := server_resources(&fixture.control)
	testing.expect(t, available)
	testing.expect(t, view.peak.bytes < 3 * mem.Megabyte, "storage tracks the bytes sent, not the permitted maximum")
}

@(test)
loopback_announced_but_unsent_body_pins_no_budget :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	fixture: H1_Fixture
	endpoint, ready := h1_start(t, &fixture, {})
	defer h1_stop(&fixture)

	if !testing.expect(t, ready) {
		return
	}

	client := h1_dial(endpoint)
	defer net.close(client)
	h1_send(client, fmt.tprintf("POST /sum HTTP/1.1\r\nHost: a\r\nContent-Length: %d\r\n\r\n", H1_BODY_LIMIT))
	until := time.tick_add(time.tick_now(), 5 * time.Second)

	// The request head is parsed once the operation has charged its first block.
	for time.tick_diff(time.tick_now(), until) > 0 {
		view, _ := server_resources(&fixture.control)
		if view.used.bytes > 0 {
			break
		}
		time.sleep(time.Millisecond)
	}

	time.sleep(100 * time.Millisecond)
	view, available := server_resources(&fixture.control)
	testing.expect(t, available && view.used.bytes > 0)
	testing.expect(t, view.peak.bytes < mem.Megabyte, "a silent peer must not hold the declared length")
}

@(test)
transfer_budget_follows_bytes_moved_and_stays_bounded :: proc(t: ^testing.T) {
	base := 5 * time.Second
	testing.expect_value(t, transfer_budget(base, 0), base)
	testing.expect_value(t, transfer_budget(base, MIN_TRANSFER_RATE), base + time.Second)
	testing.expect_value(t, transfer_budget(base, 600 * MIN_TRANSFER_RATE), base + 10 * time.Minute)
	testing.expect_value(t, transfer_budget(base, max(i64)), MAX_SERVER_TIMEOUT)
	testing.expect_value(t, transfer_budget(base, -1), base)
	testing.expect_value(t, transfer_budget(0, 1 << 20), time.Duration(0))

	fixture: Resource_Test
	resource_test_init(&fixture)
	defer resource_test_finish(&fixture)
	task := &fixture.task
	testing.expect_value(t, transfer_begin(task, 40 * time.Millisecond), 40 * time.Millisecond)
	testing.expect(t, transfer_window(task) <= 40 * time.Millisecond && transfer_window(task) > 0)
	time.sleep(60 * time.Millisecond)
	// Nothing moved: the transfer ends with its first budget, whatever was announced.
	testing.expect(t, transfer_window(task) <= 0)
	// A trickle earns only what its bytes are worth: one byte does not buy a window.
	transfer_progress(task, false, 1)
	testing.expect(t, deadline_expired(task.connection.read_deadline), "a trickling peer falls behind the minimum rate")
	// A usable rate earns a full fresh window, for reads and writes alike.
	transfer_progress(task, false, MIN_TRANSFER_RATE)
	testing.expect(t, !deadline_expired(task.connection.read_deadline))
	testing.expect_value(t, transfer_window(task), 40 * time.Millisecond)
	transfer_progress(task, true, 1)
	testing.expect(t, !deadline_expired(task.connection.write_deadline))
	// Without a started transfer the armed deadline is left alone.
	task.transfer_started = {}
	task.connection.read_deadline = {}
	transfer_progress(task, false, 10)
	testing.expect_value(t, task.connection.read_deadline, time.Tick{})
}

h1_slow_upload :: proc(t: ^testing.T, endpoint: net.Endpoint, chunked: bool) {
	payload, sum := h1_payload(64 * mem.Kilobyte)
	defer delete(payload)
	client := h1_dial(endpoint)
	defer net.close(client)

	if chunked {
		h1_send(client, "POST /sum HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n")
	} else {
		h1_send(client, fmt.tprintf("POST /sum HTTP/1.1\r\nHost: a\r\nContent-Length: %d\r\n\r\n", len(payload)))
	}

	// Eight pieces over roughly 640 ms: far past one 250 ms budget, never stalled.
	for offset := 0; offset < len(payload); offset += 8192 {
		time.sleep(80 * time.Millisecond)
		piece := payload[offset:offset + 8192]

		if chunked {
			h1_send(client, fmt.tprintf("%x\r\n", len(piece)))
		}
		_, send_error := net.send_tcp(client, piece)
		assert(send_error == nil)
		if chunked {
			h1_send(client, "\r\n")
		}
	}

	if chunked {
		h1_send(client, "0\r\n\r\n")
	}

	wire := h1_read_all(client)
	defer delete(wire)
	testing.expectf(t, strings.has_prefix(string(wire[:]), "HTTP/1.1 200"), "chunked=%v got %q", chunked, string(wire[:min(len(wire), 40)]))
	testing.expect(t, strings.has_suffix(string(wire[:]), fmt.tprintf("%d %d", len(payload), sum)))
}

@(test)
loopback_slow_but_live_upload_outlasts_one_body_budget :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	fixture: H1_Fixture
	endpoint, ready := h1_start(t, &fixture, {timeouts = {body = 250 * time.Millisecond}})
	defer h1_stop(&fixture)

	if !testing.expect(t, ready) {
		return
	}

	h1_slow_upload(t, endpoint, false)
	h1_slow_upload(t, endpoint, true)
}

@(test)
loopback_stalled_upload_is_cut_after_one_body_budget :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	fixture: H1_Fixture
	endpoint, ready := h1_start(t, &fixture, {timeouts = {body = 250 * time.Millisecond}})
	defer h1_stop(&fixture)

	if !testing.expect(t, ready) {
		return
	}

	for chunked in ([]bool{false, true}) {
		client := h1_dial(endpoint)
		defer net.close(client)

		if chunked {
			h1_send(client, "POST /sum HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n10000\r\nabc")
		} else {
			h1_send(client, "POST /sum HTTP/1.1\r\nHost: a\r\nContent-Length: 65536\r\n\r\nabc")
		}

		started := time.tick_now()
		wire := h1_read_all(client)
		defer delete(wire)
		elapsed := time.tick_since(started)
		testing.expectf(t, strings.has_prefix(string(wire[:]), "HTTP/1.1 408"), "chunked=%v got %q", chunked, string(wire[:min(len(wire), 40)]))
		testing.expect(t, elapsed >= 200 * time.Millisecond && elapsed < 3 * time.Second)
	}
}

@(test)
loopback_slow_reader_receives_the_whole_response :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 60 * time.Second)
	fixture: H1_Fixture
	fixture.big = make([]u8, 16 * mem.Megabyte)
	defer delete(fixture.big)
	endpoint, ready := h1_start(t, &fixture, {timeouts = {response = 250 * time.Millisecond}})
	defer h1_stop(&fixture)

	if !testing.expect(t, ready) {
		return
	}

	chunk := make([]u8, 256 * mem.Kilobyte)
	defer delete(chunk)

	{
		// About a megabyte every 50 ms: the transfer takes several budgets.
		client := h1_dial(endpoint)
		defer net.close(client)
		_ = net.set_option(client, .Receive_Buffer_Size, 64 * mem.Kilobyte)
		h1_send(client, "GET /big HTTP/1.1\r\nHost: a\r\n\r\n")
		total, window := 0, 0
		started := time.tick_now()

		for {
			count, receive_error := net.recv_tcp(client, chunk)
			total += count
			window += count
			if count == 0 || receive_error != nil {
				break
			}
			if window >= mem.Megabyte {
				window = 0
				time.sleep(50 * time.Millisecond)
			}
		}

		testing.expect(t, total > len(fixture.big), "a reader that keeps reading is not cut at the response budget")
		testing.expect(t, time.tick_since(started) > 400 * time.Millisecond, "the transfer outlasted one budget")
	}

	{
		// A reader that stops entirely still loses the connection after one budget.
		client := h1_dial(endpoint)
		defer net.close(client)
		_ = net.set_option(client, .Receive_Buffer_Size, 64 * mem.Kilobyte)
		h1_send(client, "GET /big HTTP/1.1\r\nHost: a\r\n\r\n")
		time.sleep(1200 * time.Millisecond)
		total := 0

		for {
			count, receive_error := net.recv_tcp(client, chunk)
			total += count
			if count == 0 || receive_error != nil {
				break
			}
		}

		testing.expect(t, total < len(fixture.big), "a stalled reader is not served indefinitely")
	}
}

@(test)
inherited_stream_timeout_is_a_stall_budget_bounded_by_the_minimum_rate :: proc(t: ^testing.T) {
	fixture: Resource_Test
	resource_test_init(&fixture)
	defer resource_test_finish(&fixture)
	now := time.tick_now()
	stall := 80 * time.Millisecond
	state := Response_Stream_State {
		stall   = stall,
		started = now,
		expires = time.tick_add(now, stall),
	}
	fixture.task.streaming = &state
	defer fixture.task.streaming = nil
	time.sleep(40 * time.Millisecond)
	first := state.expires
	// A peer that accepts bytes at a usable rate earns a fresh window.
	stream_progress(&fixture.task, MIN_TRANSFER_RATE)
	testing.expect(t, time.tick_diff(first, state.expires) >= 30 * time.Millisecond, "progress earns a fresh window")
	testing.expect(t, time.tick_diff(time.tick_now(), state.expires) <= stall)

	// A trickle cannot move the deadline past what its bytes are worth.
	slow := Response_Stream_State {
		stall   = stall,
		started = now,
		expires = time.tick_add(now, stall),
	}
	fixture.task.streaming = &slow
	stream_progress(&fixture.task, 1)
	testing.expect_value(t, slow.expires, time.tick_add(now, transfer_budget(stall, 1)))
	testing.expect(t, time.tick_diff(time.tick_add(now, stall), slow.expires) < time.Millisecond)

	// The request deadline still ends the stream.
	limited := Response_Stream_State {
		stall   = stall,
		started = now,
		expires = time.tick_add(now, stall),
		limit   = time.tick_add(now, 90 * time.Millisecond),
	}
	fixture.task.streaming = &limited
	stream_progress(&fixture.task, 100 * MIN_TRANSFER_RATE)
	testing.expect_value(t, limited.expires, limited.limit)

	// A stream with its own timeout keeps that fixed lifetime.
	fixed := Response_Stream_State {
		expires = time.tick_add(now, time.Second),
	}
	fixture.task.streaming = &fixed
	stream_progress(&fixture.task, MIN_TRANSFER_RATE)
	testing.expect_value(t, fixed.expires, time.tick_add(now, time.Second))
}

@(test)
signal_watch_drains_every_registered_server_and_stops_cleanly :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 20 * time.Second)
	context.logger = log.nil_logger()
	watch: Signal_Watch
	runtimes: [2]Server_Runtime

	for &runtime in runtimes {
		assert(async.init(&runtime.executor, {workers = 1, task_capacity = 2, io_capacity = 0}).kind == .None)
		runtime.logger = log.nil_logger()
	}

	defer for &runtime in runtimes {
		async.destroy(&runtime.executor)
	}

	// Unlisted runtimes are ignored; listing twice is idempotent.
	signal_watch_unregister(&runtimes[0])
	testing.expect(t, !watch.running)

	for &runtime in runtimes {
		testing.expect(t, signal_watch_register(&watch, &runtime, false))
	}

	testing.expect(t, signal_watch_register(&watch, &runtimes[0], false))
	testing.expect_value(t, watch.count, 2)
	testing.expect(t, watch.running)
	testing.expect(t, !server_is_draining(&runtimes[0]) && !server_is_draining(&runtimes[1]))
	testing.expect(t, signal_watch_notify(&watch, .SIGTERM))
	until := time.tick_add(time.tick_now(), 5 * time.Second)

	for !(server_is_draining(&runtimes[0]) && server_is_draining(&runtimes[1])) &&
	    time.tick_diff(time.tick_now(), until) > 0 {
		time.sleep(time.Millisecond)
	}

	for &runtime in runtimes {
		testing.expect(t, server_is_draining(&runtime))
		testing.expect(t, sync.atomic_load(&runtime.signal_drained))
	}

	signal_watch_unregister(&runtimes[0])
	testing.expect(t, watch.running)
	signal_watch_unregister(&runtimes[1])
	testing.expect(t, !watch.running)
	testing.expect_value(t, watch.count, 0)
	testing.expect(t, watch.servers == nil)
}

@(test)
loopback_signal_request_drains_a_live_server_and_serve_succeeds :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	fixture: H1_Fixture
	endpoint, ready := h1_start(t, &fixture, {signals = {disabled = true}, drain_timeout = 2 * time.Second})

	if !testing.expect(t, ready) {
		h1_stop(&fixture)
		return
	}

	// Drive the same dispatch the watcher thread runs, on a private watch so
	// servers of other tests in this process are left alone.
	watch: Signal_Watch
	runtime := fixture.control._server
	testing.expect(t, runtime.signal_watch == nil, "disabled keeps the server off the process watch")
	testing.expect(t, signal_watch_register(&watch, runtime, false))
	wire := h1_exchange(endpoint, "GET / HTTP/1.1\r\nHost: a\r\n\r\n")
	testing.expect(t, strings.has_prefix(string(wire[:]), "HTTP/1.1 200"))
	delete(wire)
	testing.expect(t, signal_watch_notify(&watch, .SIGTERM))
	until := time.tick_add(time.tick_now(), 10 * time.Second)

	for !thread.is_done(fixture.worker) && time.tick_diff(time.tick_now(), until) > 0 {
		time.sleep(time.Millisecond)
	}

	testing.expect(t, thread.is_done(fixture.worker), "serve returns once the drain completes")
	thread.join(fixture.worker)
	thread.destroy(fixture.worker)
	fixture.worker = nil
	testing.expect(t, fixture.ok, "a signal-driven drain is a clean exit")
	// serve unlisted itself before its runtime was freed.
	testing.expect_value(t, watch.count, 0)
	testing.expect(t, !watch.running)
}

h1_socket_pair :: proc() -> (server, client: net.TCP_Socket) {
	listener, listen_error := net.listen_tcp({net.IP4_Loopback, 0})
	assert(listen_error == nil)
	defer net.close(listener)
	bound, bound_error := net.bound_endpoint(listener)
	assert(bound_error == nil)
	dialed, dial_error := net.dial_tcp(bound)
	assert(dial_error == nil)
	accepted, _, accept_error := net.accept_tcp(listener)
	assert(accept_error == nil)
	assert(net.set_blocking(accepted, false) == nil)

	return accepted, dialed
}

@(test)
blocking_helpers_always_wait_against_a_deadline :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 20 * time.Second)
	server, client := h1_socket_pair()
	defer net.close(server)
	defer net.close(client)
	conn := Connection {
		socket    = server,
		_timeouts = {body = 80 * time.Millisecond, response = 80 * time.Millisecond},
	}

	// No read_deadline was armed and the peer is silent: this used to poll forever.
	buffer: [16]u8
	started := time.tick_now()
	count, read_error := read_connection(&conn, buffer[:])
	testing.expect_value(t, count, 0)
	testing.expect_value(t, read_error, net.TCP_Recv_Error.Timeout)
	testing.expect(t, time.tick_since(started) < 5 * time.Second)

	// The peer never reads: once the socket buffers fill, the write must give up.
	block := make([]u8, mem.Megabyte)
	defer delete(block)
	write_error: net.TCP_Send_Error
	started = time.tick_now()

	for _ in 0 ..< 256 {
		_, write_error = write_connection(&conn, block)
		if write_error != nil {
			break
		}
	}

	testing.expect_value(t, write_error, net.TCP_Send_Error.Timeout)
	testing.expect(t, time.tick_since(started) < 10 * time.Second)
	testing.expect_value(t, blocking_deadline({}, 0, time.Second) != time.Tick{}, true)
	armed := time.tick_add(time.tick_now(), time.Hour)
	testing.expect_value(t, blocking_deadline(armed, time.Second, time.Second), armed)
}

@(test)
blocking_helpers_name_the_tls_restriction :: proc(t: ^testing.T) {
	conn := Connection {
		_secure = true,
	}

	buffer: [4]u8
	_, read_error := read_connection(&conn, buffer[:])
	testing.expect_value(t, read_error, net.TCP_Recv_Error.Invalid_Argument)
	_, write_error := write_connection(&conn, buffer[:])
	testing.expect_value(t, write_error, net.TCP_Send_Error.Invalid_Argument)
}

@(test)
default_workers_follow_the_core_count_with_a_floor :: proc(t: ^testing.T) {
	cores := os.get_processor_core_count()
	testing.expect_value(t, default_workers(), clamp(cores, DEFAULT_WORKERS, MAX_DEFAULT_WORKERS))
	testing.expect(t, default_workers() >= DEFAULT_WORKERS)
	_, _, workers, valid := server_limits({handler = proc(_: rawptr, _: ^Connection, _: ^Request) -> Response {return {}}})
	testing.expect(t, valid)
	testing.expect_value(t, workers, default_workers())
	_, _, workers, valid = server_limits({workers = 3, handler = proc(_: rawptr, _: ^Connection, _: ^Request) -> Response {return {}}})
	testing.expect(t, valid)
	testing.expect_value(t, workers, 3)
}

@(test)
rejected_handler_response_becomes_a_500_and_names_the_field :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()
	name, reason := response_header_fault({{"X-Fine", "yes"}, {"X-Split", "a\r\nb"}}, .Close, 0)
	testing.expect_value(t, name, "X-Split")
	testing.expect(t, strings.contains(reason, "control character"))
	name, _ = response_header_fault({{"Bad Name", "x"}}, .Close, 0)
	testing.expect_value(t, name, "Bad Name")
	name, reason = response_header_fault({{"connection", "close"}}, .Close, 0)
	testing.expect_value(t, name, "connection")
	testing.expect(t, strings.contains(reason, "server sets"))
	name, _ = response_header_fault({{"Upgrade", "websocket"}}, .Close, 0)
	testing.expect_value(t, name, "Upgrade")
	name, _ = response_header_fault({{"Upgrade", "websocket"}, {"X-Fine", "yes"}}, .Upgrade, 0)
	testing.expect_value(t, name, "")
	name, reason = response_header_fault({{"X-Fine", "yes"}, {"Content-Length", "9"}}, .Keep_Alive, 5)
	testing.expect_value(t, name, "Content-Length")
	testing.expect(t, strings.contains(reason, "equal the body length"))
	name, _ = response_header_fault({{"Content-Length", "5"}}, .Keep_Alive, 5)
	testing.expect_value(t, name, "")

	// A Content-Length that states the real body length is dropped, not fatal.
	buffer: [RESPONSE_HEADER_LIMIT]u8
	head, valid := response_headers(
		{status = .OK, headers = {{"content-length", "5"}, {"X-Kept", "1"}}, body = transmute([]u8)string("hello")},
		buffer[:],
	)
	testing.expect(t, valid)
	testing.expect_value(t, strings.count(strings.to_lower(string(head), context.temp_allocator), "content-length"), 1)
	testing.expect(t, strings.contains(string(head), "Content-Length: 5\r\n") && strings.contains(string(head), "X-Kept: 1\r\n"))
	_, valid = response_headers(
		{status = .OK, headers = {{"Content-Length", "9"}}, body = transmute([]u8)string("hello")},
		buffer[:],
	)
	testing.expect(t, !valid)
	_, valid = response_headers(
		{status = .OK, headers = {{"Content-Length", "5"}, {"Content-Length", "6"}}, body = transmute([]u8)string("hello")},
		buffer[:],
	)
	testing.expect(t, !valid)

	fixture: Resource_Test
	resource_test_init(&fixture)
	defer resource_test_finish(&fixture)
	rejected := Response {
		status  = .OK,
		headers = {{"X-Split", "a\r\nb"}},
	}

	testing.expect(t, queue_response(&fixture.task, rejected), "the client still gets an answer")
	testing.expect_value(t, fixture.task.phase, Connection_Phase.Write)
	testing.expect(t, strings.has_prefix(string(fixture.task.output[0]), "HTTP/1.1 500 Internal Server Error\r\n"))
	testing.expect(t, strings.contains(string(fixture.task.output[0]), "Connection: close\r\n"))
	testing.expect(t, fixture.task.finish_after_write && !fixture.task.reuse_after_write)
}

@(test)
loopback_rejected_handler_responses_answer_500 :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	fixture: H1_Fixture
	endpoint, ready := h1_start(t, &fixture, {})
	defer h1_stop(&fixture)

	if !testing.expect(t, ready) {
		return
	}

	for item in ([]struct {
			path, status: string,
		} {
			{"/bad-value", "HTTP/1.1 500"},
			{"/reserved", "HTTP/1.1 500"},
			{"/length-bad", "HTTP/1.1 500"},
			{"/length-ok", "HTTP/1.1 200"},
		}) {
		wire := h1_exchange(endpoint, fmt.tprintf("GET %s HTTP/1.1\r\nHost: a\r\n\r\n", item.path))
		defer delete(wire)
		testing.expectf(t, strings.has_prefix(string(wire[:]), item.status), "%s got %q", item.path, string(wire[:min(len(wire), 40)]))
		testing.expect(t, !strings.contains(string(wire[:]), "X-Injected"))

		if item.path == "/length-ok" {
			testing.expect(t, strings.has_suffix(string(wire[:]), "\r\n\r\nhello"))
		}
	}
}

@(test)
accept_errors_are_classified_and_logged_at_a_bounded_rate :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()

	for item in ([]struct {
			error:            async.Error,
			before, accepted: Accept_Action,
		} {
			{{kind = .Network_Error, network_cause = net.Accept_Error.Aborted}, .Retry, .Retry},
			// Linux: a pending connection's ENETDOWN, ENETUNREACH, EHOSTDOWN,
			// EHOSTUNREACH or ENONET. The listener is fine.
			{{kind = .Network_Error, network_cause = net.Accept_Error.Network_Unreachable}, .Retry, .Retry},
			// Linux: a pending connection's EOPNOTSUPP once the listener has
			// proven it is a stream socket; before that, a listener of the wrong type.
			{{kind = .Network_Error, network_cause = net.Accept_Error.Unsupported_Socket}, .Fatal, .Retry},
			{{kind = .Network_Error, network_cause = net.Accept_Error.Insufficient_Resources}, .Backoff, .Backoff},
			{{kind = .Network_Error, network_cause = net.Accept_Error.Timeout}, .Backoff, .Backoff},
			{{kind = .Network_Error, network_cause = net.Accept_Error.Unknown}, .Backoff, .Backoff},
			{{kind = .Network_Error, network_cause = net.Accept_Error.Not_Listening}, .Fatal, .Fatal},
			{{kind = .Network_Error, network_cause = net.Accept_Error.Invalid_Argument}, .Fatal, .Fatal},
			{{kind = .System_Error}, .Fatal, .Fatal},
		}) {
		testing.expectf(t, accept_error_action(item.error, false) == item.before, "%v before an accept", item.error)
		testing.expectf(t, accept_error_action(item.error, true) == item.accepted, "%v after an accept", item.error)
	}

	runtime: Server_Runtime
	error := async.Error {
		kind          = .Network_Error,
		network_cause = net.Accept_Error.Insufficient_Resources,
	}
	now := time.tick_now()
	testing.expect(t, accept_error_log(&runtime, error, now))

	for _ in 0 ..< 50 {
		testing.expect(t, !accept_error_log(&runtime, error, time.tick_add(now, time.Second)))
	}

	testing.expect_value(t, runtime.accept_errors_suppressed, 50)
	testing.expect(t, accept_error_log(&runtime, error, time.tick_add(now, ACCEPT_LOG_INTERVAL + time.Second)))
	testing.expect_value(t, runtime.accept_errors_suppressed, 0)
}

@(test)
listen_address_accepts_ipv4_and_ipv6_literals :: proc(t: ^testing.T) {
	for text in ([]string{"127.0.0.1", "0.0.0.0", "::1", "[::1]", "::"}) {
		_, valid := parse_listen_address(text)
		testing.expectf(t, valid, "%s", text)
	}

	for text in ([]string{"", "localhost", "256.0.0.1", "[::1", "::1]"}) {
		_, valid := parse_listen_address(text)
		testing.expectf(t, !valid, "%s", text)
	}

	address, _ := parse_listen_address("[::1]")
	_, is_ip6 := address.(net.IP6_Address)
	testing.expect(t, is_ip6)
}

@(test)
loopback_ipv6_listener_serves_requests :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	probe, probe_error := net.listen_tcp({net.IP6_Loopback, 0})

	if probe_error != nil {
		log.warn("IPv6 loopback is unavailable here; skipping the listener exchange")
		return
	}

	net.close(probe)
	fixture: H1_Fixture
	endpoint, ready := h1_start(t, &fixture, {address = "::1"})
	defer h1_stop(&fixture)

	if !testing.expect(t, ready, "serve binds an IPv6 literal") {
		return
	}

	_, is_ip6 := endpoint.address.(net.IP6_Address)
	testing.expect(t, is_ip6)
	wire := h1_exchange(endpoint, "GET / HTTP/1.1\r\nHost: [::1]\r\n\r\n")
	defer delete(wire)
	testing.expect(t, strings.has_prefix(string(wire[:]), "HTTP/1.1 200"))
}

@(test)
loopback_silent_connection_is_not_counted_as_a_request :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	fixture: H1_Fixture
	endpoint, ready := h1_start(
		t,
		&fixture,
		{observability = {enabled = true}, timeouts = {header = 150 * time.Millisecond, idle = 150 * time.Millisecond}},
	)
	defer h1_stop(&fixture)

	if !testing.expect(t, ready) {
		return
	}

	{
		// A preconnect or port scan: connect, send nothing, wait to be closed.
		client := h1_dial(endpoint)
		defer net.close(client)
		wire := h1_read_all(client)
		delete(wire)
	}

	metrics, available := server_metrics(&fixture.control)
	testing.expect(t, available)
	testing.expect_value(t, metrics.started, u64(0))
	testing.expect_value(t, metrics.timeouts, u64(0))
	wire := h1_exchange(endpoint, "GET / HTTP/1.1\r\nHost: a\r\n\r\n")
	defer delete(wire)
	testing.expect(t, strings.has_prefix(string(wire[:]), "HTTP/1.1 200"))
	until := time.tick_add(time.tick_now(), 5 * time.Second)

	for time.tick_diff(time.tick_now(), until) > 0 {
		metrics, _ = server_metrics(&fixture.control)
		if metrics.completed == 1 {
			break
		}
		time.sleep(time.Millisecond)
	}

	testing.expect_value(t, metrics.started, u64(1))
	testing.expect_value(t, metrics.completed, u64(1))
}

@(test)
blocking_helpers_finish_before_they_consult_an_expired_deadline :: proc(t: ^testing.T) {
	past := time.tick_add(time.tick_now(), -time.Second)
	received := []u8{'a', 'b'}
	conn := Connection {
		read_buffer    = received,
		read_deadline  = past,
		write_deadline = past,
	}

	buffer: [4]u8
	n, read_error := read_connection(&conn, buffer[:])
	testing.expect_value(t, n, 2)
	testing.expect_value(t, read_error, nil)
	_, read_error = read_connection(&conn, buffer[:])
	testing.expect_value(t, read_error, net.TCP_Recv_Error.Timeout)

	sent, write_error := write_connection(&conn, nil)
	testing.expect_value(t, sent, 0)
	testing.expect_value(t, write_error, nil)
	_, write_error = write_connection(&conn, buffer[:])
	testing.expect_value(t, write_error, net.TCP_Send_Error.Timeout)
}
