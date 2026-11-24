package saba_upstream_test

import rt "base:runtime"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:sync"
import budget "core:sync/budget"
import "core:testing"
import "core:thread"
import "core:time"
import async "shared:async"
import server "shared:saba/core"
import upstream "shared:saba/upstream"
import surf "shared:surf"
import client "shared:surf/async"

Fixture :: struct {
	runtime:    async.Runtime,
	client:     client.Client,
	dispatcher: upstream.Dispatcher,
	control:    server.Server_Control,
	served:     bool,
	worker:     ^thread.Thread,
	holding:    i32,
}

attach :: proc(f: ^Fixture, timeout: time.Duration = 500 * time.Millisecond, tasks := 4) {
	allocator := rt.heap_allocator()
	assert(
		async.init(&f.runtime, {workers = 1, task_capacity = tasks, io_capacity = 4, allocator = allocator}).kind ==
		.None,
	)
	config := client.Client_Config {
		http = {allow_http = true, timeout = timeout, max_body_size = 8192},
		capacities = client.Capacities {
			requests = 2,
			origins = 2,
			connections = 2,
			connections_per_origin = 2,
			waiters_per_origin = 2,
			dns_ids = 0,
			work_per_resume = 8,
		},
	}
	assert(client.client_init(&f.client, &f.runtime, config, allocator).kind == .None)
	assert(upstream.attach(&f.dispatcher, &f.client, &f.runtime, allocator))
}

copy_body :: proc(source: ^surf.Response, allocator: mem.Allocator) -> (server.Response, bool) {
	bytes, error := make([]u8, len(source.body), allocator)
	if error != nil {
		return {}, false
	}
	copy(bytes, source.body)
	return {status = server.HTTP_Status(source.status), body = bytes}, true
}

route :: proc(data: rawptr, _: ^server.Connection, request: ^server.Request) -> server.Response {
	f := cast(^Fixture)data
	if request.path == "/echo" {
		return {status = .Created, body = request.body}
	}
	if request.path == "/hold" {
		sync.atomic_add(&f.holding, 1)
		return {
			deferred = {
				poll = proc(
					_: rawptr,
					_: ^server.Deferred_IO,
				) -> (
					server.Response,
					server.Deferred_Step,
				) {return {}, .Waiting},
			},
		}
	}
	endpoint, ok := server.server_endpoint(&f.control)
	assert(ok)
	// These buffers cease to be valid when the handler returns.
	buffer: [80]u8
	target := "/hold" if request.path == "/timeout" else "/echo"
	url := fmt.bprintf(buffer[:], "http://127.0.0.1:%d%s", endpoint.port, target)
	return upstream.response(
		&f.dispatcher,
		request,
		{method = .POST, url = url, body = request.body},
		copy_body,
	)
}

start :: proc(f: ^Fixture, timeout: time.Duration) -> net.Endpoint {
	attach(f, timeout)
	assert(async.start(&f.runtime).kind == .None)
	f.worker = thread.create_and_start_with_poly_data(f, proc(f: ^Fixture) {
		f.served = server.serve(
			{port = 0, workers = 1, control = &f.control, handler = route, handler_data = f},
		)
	})
	assert(f.worker != nil)
	until := time.tick_add(time.tick_now(), 4 * time.Second)
	for !server.server_ready(&f.control) && time.tick_diff(time.tick_now(), until) > 0 {
		time.sleep(time.Millisecond)
	}
	endpoint, ready := server.server_endpoint(&f.control)
	assert(ready)
	return endpoint
}

stop :: proc(f: ^Fixture) {
	server.stop_server(&f.control)
	thread.join(f.worker)
	thread.destroy(f.worker)
	assert(f.served)
	_ = client.client_close(&f.client)
	async.shutdown(&f.runtime)
	assert(async.join(&f.runtime).kind == .None)
	assert(upstream.detach(&f.dispatcher))
	assert(client.client_destroy(&f.client).kind == .None)
	assert(async.destroy(&f.runtime).kind == .None)
}

@(test)
single_worker_serves_its_own_upstream_request :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 12 * time.Second)
	f: Fixture
	endpoint := start(&f, 500 * time.Millisecond)
	defer stop(&f)
	buffer: [80]u8
	url := fmt.bprintf(buffer[:], "http://127.0.0.1:%d/proxy", endpoint.port)
	timeout_url := fmt.aprintf("http://127.0.0.1:%d/timeout", endpoint.port)
	defer delete(timeout_url)
	timed, timeout_error := surf.execute(
		{method = .GET, url = timeout_url},
		{allow_http = true, timeout = 3 * time.Second},
	)
	testing.expect_value(t, timeout_error.kind, .None)
	testing.expect_value(t, timed.status, 504)
	surf.response_destroy(&timed)
	for body in ([2]string{"first", "second"}) {
		result, error := surf.execute(
			{method = .POST, url = url, body = transmute([]u8)body},
			{allow_http = true, timeout = 3 * time.Second},
		)
		testing.expect_value(t, error.kind, .None)
		testing.expect_value(t, result.status, 201)
		testing.expect_value(t, string(result.body), body)
		surf.response_destroy(&result)
	}
}

open_held_request :: proc(endpoint: net.Endpoint) -> net.TCP_Socket {
	peer, err := net.dial_tcp(endpoint)
	assert(err == nil)
	wire :: "GET /timeout HTTP/1.1\r\nHost: localhost\r\n\r\n"
	sent, send_error := net.send_tcp(peer, transmute([]u8)string(wire))
	assert(send_error == nil && sent == len(wire))
	return peer
}

wait_for_cancellations :: proc(f: ^Fixture, cancelled, still_active: int) -> bool {
	until := time.tick_add(time.tick_now(), 3 * time.Second)
	for time.tick_diff(time.tick_now(), until) > 0 {
		stats, ok := client.client_stats(&f.client)
		if ok &&
		   stats.cancel_count == u64(cancelled) &&
		   stats.active_requests == still_active &&
		   stats.completed_requests + stats.returning_requests + stats.queued_requests == 0 {
			return true
		}
		time.sleep(time.Millisecond)
	}
	return false
}

@(test)
peer_disconnect_releases_its_slot_while_another_request_is_pending :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 15 * time.Second)
	f: Fixture
	endpoint := start(&f, 10 * time.Second)
	defer stop(&f)
	first := open_held_request(endpoint)
	first_open := true
	defer if first_open {
		net.close(first)
	}
	second := open_held_request(endpoint)
	second_open := true
	defer if second_open {
		net.close(second)
	}
	until := time.tick_add(time.tick_now(), 3 * time.Second)
	for sync.atomic_load(&f.holding) != 2 && time.tick_diff(time.tick_now(), until) > 0 {
		time.sleep(time.Millisecond)
	}
	if !testing.expect_value(t, sync.atomic_load(&f.holding), 2) {
		return
	}

	buffer: [80]u8
	url := fmt.bprintf(buffer[:], "http://127.0.0.1:%d/proxy", endpoint.port)
	outbound := transmute([]u8)string("slot reused")
	rejected, reject_error := surf.execute(
		{method = .POST, url = url, body = outbound},
		{allow_http = true, timeout = 2 * time.Second},
	)
	testing.expect_value(t, reject_error.kind, .None)
	testing.expect_value(t, rejected.status, 503)
	surf.response_destroy(&rejected)

	net.close(first)
	first_open = false
	if !testing.expect(t, wait_for_cancellations(&f, 1, 1)) {
		return
	}
	response, cause := surf.execute(
		{method = .POST, url = url, body = outbound},
		{allow_http = true, timeout = 2 * time.Second},
	)
	testing.expect_value(t, cause.kind, .None)
	testing.expect_value(t, response.status, 201)
	testing.expect_value(t, string(response.body), "slot reused")
	surf.response_destroy(&response)

	net.close(second)
	second_open = false
	testing.expect(t, wait_for_cancellations(&f, 2, 0))
}

@(test)
abandoned_request_keeps_its_budget_until_physical_retirement :: proc(t: ^testing.T) {
	f: Fixture
	attach(&f)
	root, created := budget.create_root({jobs = 1, bytes = 4096})
	assert(created == .None)
	defer budget.release_scope(&root)
	request := server.Request {
		resources = root,
	}
	outbound := upstream.response(
		&f.dispatcher,
		&request,
		{method = .GET, url = "http://127.0.0.1:1/unused"},
		copy_body,
	)
	assert(outbound.deferred.poll != nil)
	testing.expect(t, !upstream.detach(&f.dispatcher))
	excess := upstream.response(
		&f.dispatcher,
		&request,
		{method = .GET, url = "http://127.0.0.1:1/unused"},
		copy_body,
	)
	testing.expect_value(t, excess.status, .Service_Unavailable)
	server.discard_response(&outbound)
	view, error := budget.snapshot(root)
	assert(error == .None)
	testing.expect_value(t, view.used.jobs, 1)
	testing.expect_value(t, client.client_close(&f.client).kind, .None)
	testing.expect(t, upstream.detach(&f.dispatcher))
	view, error = budget.snapshot(root)
	testing.expect_value(t, error, .None)
	testing.expect_value(t, view.used.jobs, 0)
	testing.expect_value(t, view.used.bytes, 0)
	testing.expect_value(t, client.client_destroy(&f.client).kind, .None)
	testing.expect_value(t, async.destroy(&f.runtime).kind, .None)
}

Detach_Blocker :: struct {
	task:             async.Task,
	entered, release: sync.Sema,
}

// detach used to mark the dispatcher stopped before it knew the task could be
// unregistered. A refused detach then left every later request answered 503.
@(test)
refused_detach_leaves_the_dispatcher_serving :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 12 * time.Second)
	f: Fixture
	attach(&f, tasks = 8)
	blocker: Detach_Blocker
	blocker.task = {
		data = &blocker,
		resume = proc(data: rawptr) -> async.Resume_Result {
			b := cast(^Detach_Blocker)data
			sync.sema_post(&b.entered)
			sync.sema_wait(&b.release)
			return .Done
		},
	}
	registered := async.register(&f.runtime, &blocker.task)
	if !testing.expect_value(t, registered.kind, async.Error_Kind.None) {
		return
	}
	assert(async.start(&f.runtime).kind == .None)
	assert(async.wake(&f.runtime, &blocker.task))
	assert(sync.sema_wait_with_timeout(&blocker.entered, 4 * time.Second))
	// The only worker is occupied, so the woken dispatcher stays queued and
	// cannot be unregistered.
	assert(async.wake(&f.runtime, &f.dispatcher.task))
	testing.expect(t, !upstream.detach(&f.dispatcher))
	testing.expect(t, !f.dispatcher.stopped, "a refused detach stopped the dispatcher")
	testing.expect(t, f.dispatcher.registered)
	sync.sema_post(&blocker.release)

	_ = client.client_close(&f.client)
	async.shutdown(&f.runtime)
	assert(async.join(&f.runtime).kind == .None)
	testing.expect(t, upstream.detach(&f.dispatcher))
	assert(client.client_destroy(&f.client).kind == .None)
	assert(async.destroy(&f.runtime).kind == .None)
}
