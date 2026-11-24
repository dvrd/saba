package saba_core

import http3 "shared:http/v3"
import async "shared:async"
import signal "shared:async/signal"
import owned "core:mem/owned"
import budget "core:sync/budget"
import credential_store "core:crypto/tls/credentials/store"
import "core:net"
import "core:testing"
import "core:sync"
import "core:thread"
import "core:time"

H3_Probe :: struct {
	calls, drops, nexts, polls, idles: int,
	wait_next, pending:                bool,
	valid:                             bool,
}
h3_probe_handler :: proc(data: rawptr, conn: ^Connection, request: ^Request) -> Response {
	probe := cast(^H3_Probe)data
	sync.atomic_add(&probe.calls, 1)
	sync.atomic_store(
		&probe.valid,
		conn != nil &&
		conn._task != nil &&
		conn._secure &&
		request.allocator.procedure != nil &&
		request.backing_allocator.procedure != nil,
	)

	switch request.path {
	case "/auth":
		sync.atomic_store(
			&probe.valid,
			sync.atomic_load(&probe.valid) &&
			request.method == "POST" &&
			request.query == "one=two" &&
			header_value(request, "authorization") == "Bearer test" &&
			string(request.body) == "payload",
		)
		return make_response(
			request,
			.Unauthorized,
			[]Header{{"www-authenticate", "Bearer"}},
			transmute([]u8)string("denied"),
		)
	case "/redirect":
		return make_response(
			request,
			.Found,
			[]Header{{"location", "/next"}, {"Set-Cookie", "a=1; Secure"}, {"Set-Cookie", "b=2; Secure"}},
		)
	case "/idle":
		return {status = .OK, stream = {data = probe, next = h3_idle_next, drop = h3_probe_drop, content_length = -1}}
	case "/stream":
		return {status = .OK, stream = {data = probe, next = h3_probe_next, drop = h3_probe_drop, content_length = 6}}
	case "/deferred", "/pending":
		probe.pending = request.path == "/pending"
		return {deferred = {data = probe, poll = h3_probe_poll, drop = h3_probe_drop}}
	case "/upgrade":
		return {upgrade = {data = probe, drop = h3_probe_drop}}
	}

	return {status = .Not_Found, body = transmute([]u8)string("missing")}
}
h3_probe_next :: proc(data: rawptr, io: ^Stream_IO) -> Stream_Step {
	probe := cast(^H3_Probe)data
	probe.nexts += 1

	if probe.wait_next && probe.nexts == 1 {
		if stream_wait(io, async.deadline_after(io.runtime, time.Millisecond)).kind == .Pending {
			return .Waiting
		}
		return .Failed
	}

	if probe.nexts > (3 if probe.wait_next else 2) {
		return .Done
	}
	chunk, error := owned.copy_bounded(transmute([]u8)string("abc"), 3, io.backing_allocator)
	if error.kind != .None {
		return .Failed
	}

	if stream_submit(io, &chunk) != .Accepted {
		owned.destroy(&chunk)
		return .Failed
	}

	return .Chunk
}
h3_idle_next :: proc(data: rawptr, io: ^Stream_IO) -> Stream_Step {
	probe := cast(^H3_Probe)data
	sync.atomic_add(&probe.idles, 1)
	if stream_wait(io, async.deadline_after(io.runtime, 5 * time.Second)).kind == .Pending {
		return .Waiting
	}

	return .Failed
}
h3_probe_poll :: proc(data: rawptr, io: ^Deferred_IO) -> (Response, Deferred_Step) {
	probe := cast(^H3_Probe)data
	count := sync.atomic_add(&probe.polls, 1)

	if probe.pending || count == 0 {
		if !probe.pending {
			_ = signal.wake(io.wake)
		}
		return {}, .Waiting
	}

	return {status = .Accepted, body = transmute([]u8)string("deferred-ready")}, .Ready
}
h3_probe_drop :: proc(data: rawptr) {
	probe := cast(^H3_Probe)data
	probe.drops += 1
}

h3_unit_init :: proc(runtime: ^Server_Runtime, owner: ^Http3, probe: ^H3_Probe) {
	runtime.config.handler = h3_probe_handler
	runtime.config.handler_data = probe
	runtime.timeouts = resolve_timeouts({})
	assert(initialize_resources(runtime))
	assert(async.init(&runtime.executor, {workers = 1, task_capacity = 4, io_capacity = 0}).kind == .None)
	owner.runtime = runtime
	owner.config = {
		enabled      = true,
		handler      = h3_probe_handler,
		handler_data = probe,
	}
}
h3_unit_destroy :: proc(runtime: ^Server_Runtime) {
	_ = async.destroy(&runtime.executor)
	budget.release_scope(&runtime.resources)
}
@(test)
http3_handler_preserves_request_response_and_disposes_upgrade :: proc(t: ^testing.T) {
	runtime: Server_Runtime
	owner: Http3
	probe: H3_Probe
	h3_unit_init(&runtime, &owner, &probe)
	defer h3_unit_destroy(&runtime)
	fields := []http3.Field{{name = "authorization", value = "Bearer test"}}
	request := http3.Server_Request {
		method    = "POST",
		target    = "/auth?one=two",
		authority = "fixture.invalid",
		headers   = fields,
		body      = transmute([]u8)string("payload"),
	}

	response: http3.Server_Response
	testing.expect_value(t, http3_poll(&owner, &request, &response), .Ready)
	testing.expect(t, sync.atomic_load(&probe.valid))
	testing.expect_value(t, response.status, 401)
	testing.expect_value(t, string(response.body), "denied")
	testing.expect_value(t, response.headers[0].name, "www-authenticate")
	http3_release(&owner, &request)
	targets := []string{"/missing", "/redirect", "/upgrade"}
	statuses := []int{404, 302, 501}

	for target, i in targets {
		status := statuses[i]
		request = {
			method = "GET",
			target = target,
		}

		response = {}
		testing.expect_value(t, http3_poll(&owner, &request, &response), .Ready)
		testing.expect_value(t, response.status, status)

		if target == "/redirect" {
			testing.expect_value(t, len(response.headers), 3)
			testing.expect_value(t, response.headers[1].name, "set-cookie")
			testing.expect_value(t, response.headers[2].name, "set-cookie")
		}

		http3_release(&owner, &request)
	}

	testing.expect_value(t, probe.calls, 4)
	testing.expect_value(t, probe.drops, 1)
	testing.expect_value(t, runtime.active_connections, 0)
}
@(test)
http3_stream_copies_bounded_chunks_and_drops_once :: proc(t: ^testing.T) {
	runtime: Server_Runtime
	owner: Http3
	probe: H3_Probe
	h3_unit_init(&runtime, &owner, &probe)
	defer h3_unit_destroy(&runtime)
	request := http3.Server_Request {
		method = "GET",
		target = "/stream",
	}

	response: http3.Server_Response
	testing.expect_value(t, http3_poll(&owner, &request, &response), .Ready)
	destination: [2]u8
	received: [6]u8
	count := 0

	for _ in 0 ..< 10 {
		n, status := response.stream.next(response.stream.data, destination[:])
		if status == .Done {
			break
		}
		testing.expect_value(t, status, .Chunk)
		count += copy(received[count:], destination[:n])
	}

	testing.expect_value(t, string(received[:count]), "abcabc")
	testing.expect_value(t, probe.nexts, 3)
	response.stream.drop(response.stream.data)
	http3_release(&owner, &request)
	testing.expect_value(t, probe.drops, 1)
	testing.expect_value(t, runtime.active_connections, 0)
	// Cancel while a chunk remains partly copied: release remaining owned bytes
	// before dropping the producer and destroying its request arena.
	probe.nexts = 0
	request = {
		method = "GET",
		target = "/stream",
	}

	response = {}
	testing.expect_value(t, http3_poll(&owner, &request, &response), .Ready)
	_, status := response.stream.next(response.stream.data, destination[:])
	testing.expect_value(t, status, .Chunk)
	response.stream.drop(response.stream.data)
	http3_release(&owner, &request)
	testing.expect_value(t, probe.drops, 2)
}

H3_Server_Fixture :: struct {
	config:  Server,
	control: Server_Control,
	ok:      bool,
}
@(test)
http3_serve_status_cookies_and_concurrent_clients :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 60 * time.Second)
	store := https80_make_store(t)
	defer credential_store.destroy(&store)
	probe: H3_Probe
	probe.wait_next = true
	fixture: H3_Server_Fixture
	fixture.config = {
		handler = h3_probe_handler,
		handler_data = &probe,
		control = &fixture.control,
		workers = 2,
		http3 = {enabled = true, endpoint = {net.IP4_Loopback, 0}, credentials = store},
	}

	worker := thread.create_and_start_with_poly_data(&fixture, proc(f: ^H3_Server_Fixture) {f.ok = serve(f.config)})
	defer thread.destroy(worker)
	joined := false
	defer {
		if !joined {
			stop_server(&fixture.control)
			thread.join(worker)
		}
	}

	deadline := time.tick_add(time.tick_now(), 5 * time.Second)
	for !server_ready(&fixture.control) && time.tick_diff(time.tick_now(), deadline) > 0 {
		thread.yield()
	}
	endpoint, ready := server_http3_endpoint(&fixture.control)
	if !testing.expect(t, ready && endpoint.port > 0) {
		return
	}
	// Each client opens its own QUIC connection.
	clients := [2]H3_Test_Client {
		{endpoint = endpoint, request = {target = "/redirect"}, timeout = 5 * time.Second},
		{endpoint = endpoint, request = {target = "/missing"}, timeout = 5 * time.Second},
	}
	for &client in clients {
		h3_test_client_start(&client)
	}
	for &client in clients {
		h3_test_client_join(&client)
		testing.expect(t, client.result.error == .None, h3_test_error(&client.result))
	}
	redirect := &clients[0].result
	testing.expect_value(t, redirect.status, 302)
	location := ""
	cookies: [2]string
	cookie_count := 0
	for index in 0 ..< redirect.header_count {
		field, valid := http3.client_result_header(redirect, index)
		if !valid {
			continue
		}
		switch field.name {
		case "location":
			location = field.value
		case "set-cookie":
			if cookie_count < len(cookies) {
				cookies[cookie_count] = field.value
			}
			cookie_count += 1
		}
	}
	testing.expect_value(t, location, "/next")
	testing.expect_value(t, cookie_count, 2)
	testing.expect_value(t, cookies[0], "a=1; Secure")
	testing.expect_value(t, cookies[1], "b=2; Secure")
	testing.expect_value(t, clients[1].result.status, 404)
	testing.expect_value(t, h3_test_body(&clients[1].result), "missing")

	// These requests exercise the callback context, body delivery, stream
	// waiting, and detachable deferred wakes on the live serving runtime.
	cases := []struct {request: http3.Client_Request, status: int, body: string} {
		{{method = "POST", target = "/auth?one=two", headers = {{name = "authorization", value = "Bearer test"}},
		  body = transmute([]u8)string("payload")}, 401, "denied"},
		{{target = "/stream"}, 200, "abcabc"},
		{{target = "/deferred"}, 202, "deferred-ready"},
	}
	for test_case in cases {
		result := h3_test_exchange(endpoint.port, test_case.request, 5 * time.Second)
		testing.expect(t, result.error == .None, h3_test_error(&result))
		testing.expect_value(t, result.status, test_case.status)
		testing.expect_value(t, h3_test_body(&result), test_case.body)
		testing.expect(t, sync.atomic_load(&probe.valid))
	}

	// An idle stream must leave the listener free to dispatch another peer.
	idle := H3_Test_Client {endpoint = endpoint, request = {target = "/idle"}, timeout = 5 * time.Second}
	h3_test_client_start(&idle)
	defer h3_test_client_cancel(&idle)
	idle_deadline := time.tick_add(time.tick_now(), time.Second)
	for sync.atomic_load(&probe.idles) == 0 && time.tick_diff(time.tick_now(), idle_deadline) > 0 {
		thread.yield()
	}
	testing.expect(t, sync.atomic_load(&probe.idles) > 0)
	other := h3_test_exchange(endpoint.port, {target = "/missing"}, 2 * time.Second)
	testing.expect(t, other.error == .None, h3_test_error(&other))
	testing.expect_value(t, other.status, 404)
	testing.expect(t, !thread.is_done(idle.worker), "idle peer remains active")
	h3_test_client_cancel(&idle)

	// Closing the server with a pending continuation must detach its wake
	// before serve releases its executor and request resources.
	prior := sync.atomic_load(&probe.polls)
	pending := H3_Test_Client {endpoint = endpoint, request = {target = "/pending"}, timeout = 5 * time.Second}
	h3_test_client_start(&pending)
	defer h3_test_client_cancel(&pending)
	until := time.tick_add(time.tick_now(), time.Second)
	for sync.atomic_load(&probe.polls) == prior && time.tick_diff(time.tick_now(), until) > 0 {
		thread.yield()
	}
	testing.expect(t, sync.atomic_load(&probe.polls) > prior)
	stop_server(&fixture.control)
	thread.join(worker)
	joined = true
	h3_test_client_cancel(&pending)
	testing.expect_value(t, probe.drops, 4)
	testing.expect(t, fixture.ok)
	testing.expect_value(t, probe.calls, 8)
	testing.expect(t, sync.atomic_load(&probe.valid))
}

@(test)
http3_deferred_poll_and_pending_release_drop_exactly_once :: proc(t: ^testing.T) {
	runtime: Server_Runtime
	owner: Http3
	probe: H3_Probe
	h3_unit_init(&runtime, &owner, &probe)
	defer h3_unit_destroy(&runtime)
	request := http3.Server_Request {
		method = "GET",
		target = "/deferred",
	}

	response: http3.Server_Response
	testing.expect_value(t, http3_poll(&owner, &request, &response), .Pending)
	testing.expect_value(t, http3_poll(&owner, &request, &response), .Ready)
	testing.expect_value(t, response.status, 202)
	testing.expect_value(t, string(response.body), "deferred-ready")
	testing.expect_value(t, probe.calls, 1)
	testing.expect_value(t, probe.drops, 1)
	http3_release(&owner, &request)
	testing.expect_value(t, probe.drops, 1)
	request = {
		method = "GET",
		target = "/pending",
	}

	response = {}
	testing.expect_value(t, http3_poll(&owner, &request, &response), .Pending)
	http3_release(&owner, &request)
	testing.expect_value(t, probe.drops, 2)
	testing.expect_value(t, runtime.active_connections, 0)
}

@(test)
http3_drain_keeps_runtime_alive_for_retained_transport_bytes :: proc(t: ^testing.T) {
	runtime: Server_Runtime
	runtime.config.http3.enabled = true
	runtime.draining = true
	runtime.http3._pending = true
	testing.expect_value(
		t,
		async.init(&runtime.executor, {workers = 1, task_capacity = 2, io_capacity = 1}).kind,
		.None,
	)
	defer async.destroy(&runtime.executor)
	runtime.drain_deadline = async.deadline_after(&runtime.executor, time.Second)
	runtime.accept_task = {
		resume = proc(data: rawptr) -> async.Resume_Result {return drain_connections(cast(^Server_Runtime)data)},
		data = &runtime,
	}

	assert(async.spawn(&runtime.executor, &runtime.accept_task).kind == .None)
	assert(async.start(&runtime.executor).kind == .None)
	_ = async.wait_idle(&runtime.executor)
	// Request arenas may already be released; pending reliable transport bytes
	// independently keep the runtime alive until acknowledged or the deadline.
	testing.expect(t, !async.cancelled(&runtime.accept_task))
	state, error := async.task_state(&runtime.executor, &runtime.accept_task)
	testing.expect_value(t, error.kind, .None)
	testing.expect_value(t, state, .Waiting)
	sync.atomic_store(&runtime.http3._pending, false)
	_ = async.wake(&runtime.executor, &runtime.accept_task)
	until := time.tick_add(time.tick_now(), time.Second)

	for time.tick_diff(time.tick_now(), until) > 0 {
		state, _ = async.task_state(&runtime.executor, &runtime.accept_task)
		if state == .Done {
			break
		}
		thread.yield()
	}

	_ = async.join(&runtime.executor)
	state, error = async.task_state(&runtime.executor, &runtime.accept_task)
	testing.expect_value(t, error.kind, .None)
	testing.expect_value(t, state, .Done)
}
