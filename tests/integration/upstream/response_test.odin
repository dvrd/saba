package saba_upstream_test

import rt "base:runtime"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:sync"
import budget "shared:async/budget"
import "core:testing"
import "core:thread"
import "core:time"
import async "shared:async"
import server "shared:saba/core"
import upstream "shared:saba/upstream"
import surf "shared:surf"

Fixture :: struct {
	runtime:    async.Runtime,
	client:     surf.Client,
	dispatcher: upstream.Dispatcher,
	control:    server.Server_Control,
	served:     bool,
	worker:     ^thread.Thread,
	holding:    i32,
}

// The fixture's upstream is the server itself on 127.0.0.1, which the default
// policy refuses. Tests that proxy to it accept loopback explicitly.
allow_loopback :: proc(_: string, addresses: []net.Endpoint, _: rawptr) -> bool {
	for address in addresses {
		ip, ok := address.address.(net.IP4_Address)
		if !ok || ip != net.IP4_Loopback {
			return false
		}
	}
	return len(addresses) > 0
}

attach :: proc(
	f: ^Fixture,
	timeout: time.Duration = 500 * time.Millisecond,
	tasks := 4,
	policy: upstream.Address_Policy = allow_loopback,
) {
	allocator := rt.heap_allocator()
	assert(
		async.init(&f.runtime, {workers = 1, task_capacity = tasks, io_capacity = 4, allocator = allocator}).kind ==
		.None,
	)
	config := surf.Client_Config {
		http = {
			allow_http = true,
			timeout = timeout,
			max_body_size = 8192,
			address_policy = policy,
		},
	}
	capacities := surf.DEFAULT_CAPACITIES
	capacities.requests, capacities.origins, capacities.connections_per_origin = 2, 2, 2
	config.capacities = capacities
	assert(upstream.attach(&f.dispatcher, &f.client, &f.runtime, config, allocator))
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

start :: proc(
	f: ^Fixture,
	timeout: time.Duration,
	policy: upstream.Address_Policy = allow_loopback,
) -> net.Endpoint {
	attach(f, timeout, policy = policy)
	assert(async.start(&f.runtime).kind == .None)
	f.worker = thread.create_and_start_with_poly_data(f, proc(f: ^Fixture) {
		f.served = server.serve(
			{port = 0, workers = 1, control = &f.control, handler = route, handler_data = f},
		)
	})
	assert(f.worker != nil)
	// A startup bound only: generous, since a loaded machine can take seconds
	// to start serve, and nothing here measures it.
	until := time.tick_add(time.tick_now(), 60 * time.Second)
	for !server.server_ready(&f.control) && time.tick_diff(time.tick_now(), until) > 0 {
		time.sleep(time.Millisecond)
	}
	endpoint, ready := server.server_endpoint(&f.control)
	assert(ready)
	return endpoint
}

// Closes the client and lets its task end. Only the client's task acts on a
// close or a cancel, so a runtime that never started is started here.
retire :: proc(f: ^Fixture, started := false) {
	if !started {
		assert(async.start(&f.runtime).kind == .None)
	}
	_ = surf.client_close(&f.client)
	until := time.tick_add(time.tick_now(), 4 * time.Second)
	for !surf.client_quiescent(&f.client) && time.tick_diff(time.tick_now(), until) > 0 {
		time.sleep(time.Millisecond)
	}
	async.shutdown(&f.runtime)
	assert(async.join(&f.runtime).kind == .None)
}

stop :: proc(f: ^Fixture) {
	server.stop_server(&f.control)
	thread.join(f.worker)
	thread.destroy(f.worker)
	assert(f.served)
	_ = surf.client_close(&f.client)
	async.shutdown(&f.runtime)
	assert(async.join(&f.runtime).kind == .None)
	assert(upstream.detach(&f.dispatcher))
	assert(surf.client_destroy(&f.client).kind == .None)
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

// An application that names no policy gets the public-only one, so a proxied
// request to a loopback upstream is refused before any dial.
@(test)
default_policy_refuses_a_loopback_upstream :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 12 * time.Second)
	f: Fixture
	endpoint := start(&f, 2 * time.Second, nil)
	defer stop(&f)
	buffer: [80]u8
	url := fmt.bprintf(buffer[:], "http://127.0.0.1:%d/proxy", endpoint.port)
	result, error := surf.execute(
		{method = .POST, url = url, body = transmute([]u8)string("private")},
		{allow_http = true, timeout = 3 * time.Second},
	)
	testing.expect_value(t, error.kind, .None)
	testing.expect_value(t, result.status, 502)
	testing.expect(t, string(result.body) != "private")
	surf.response_destroy(&result)
}

// An explicit policy is the opt-out for an internal upstream.
@(test)
explicit_policy_admits_a_loopback_upstream :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 12 * time.Second)
	f: Fixture
	endpoint := start(&f, 2 * time.Second, allow_loopback)
	defer stop(&f)
	buffer: [80]u8
	url := fmt.bprintf(buffer[:], "http://127.0.0.1:%d/proxy", endpoint.port)
	result, error := surf.execute(
		{method = .POST, url = url, body = transmute([]u8)string("internal")},
		{allow_http = true, timeout = 3 * time.Second},
	)
	testing.expect_value(t, error.kind, .None)
	testing.expect_value(t, result.status, 201)
	testing.expect_value(t, string(result.body), "internal")
	surf.response_destroy(&result)
}

public_only_allows :: proc(address: net.Address) -> bool {
	addresses := [1]net.Endpoint{{address = address, port = 80}}
	return upstream.address_policy_public_only("upstream.example", addresses[:], nil)
}

mapped :: proc(ip: net.IP4_Address) -> net.IP6_Address {
	return net.IP6_Address {
		0,
		0,
		0,
		0,
		0,
		0xffff,
		u16be(ip[0]) << 8 | u16be(ip[1]),
		u16be(ip[2]) << 8 | u16be(ip[3]),
	}
}

@(test)
public_only_policy_refuses_special_purpose_ranges :: proc(t: ^testing.T) {
	refused_ip4 := [?]net.IP4_Address {
		{127, 0, 0, 1},
		{10, 1, 2, 3},
		{172, 16, 0, 1},
		{192, 168, 1, 1},
		{169, 254, 169, 254},
		// Shared address space 100.64.0.0/10, both ends.
		{100, 64, 0, 0},
		{100, 127, 255, 255},
		// 0.0.0.0/8.
		{0, 0, 0, 0},
		{0, 1, 2, 3},
		// Multicast and 240.0.0.0/4, including broadcast.
		{224, 0, 0, 1},
		{240, 0, 0, 1},
		{255, 255, 255, 255},
	}
	for ip in refused_ip4 {
		testing.expectf(t, !public_only_allows(ip), "%v was admitted", ip)
		testing.expectf(t, !public_only_allows(mapped(ip)), "::ffff:%v was admitted", ip)
	}
	refused_ip6 := [?]net.IP6_Address {
		{},
		net.IP6_Loopback,
		{0xfe80, 0, 0, 0, 0, 0, 0, 1},
		{0xfd00, 0, 0, 0, 0, 0, 0, 1},
		{0xff02, 0, 0, 0, 0, 0, 0, 1},
		// NAT64 well-known prefix 64:ff9b::/96 in front of a public address.
		{0x64, 0xff9b, 0, 0, 0, 0, 0x0808, 0x0808},
		{0x64, 0xff9b, 0, 0, 0, 0, 0x7f00, 0x0001},
	}
	for ip in refused_ip6 {
		testing.expectf(t, !public_only_allows(ip), "%v was admitted", ip)
	}
	admitted := [?]net.Address {
		net.IP4_Address{8, 8, 8, 8},
		net.IP4_Address{100, 63, 255, 255},
		net.IP4_Address{100, 128, 0, 0},
		net.IP4_Address{223, 255, 255, 255},
		mapped({8, 8, 8, 8}),
		net.IP6_Address{0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888},
	}
	for address in admitted {
		testing.expectf(t, public_only_allows(address), "%v was refused", address)
	}
	testing.expect(t, !upstream.address_policy_public_only("upstream.example", nil, nil))
}

open_held_request :: proc(endpoint: net.Endpoint) -> net.TCP_Socket {
	peer, err := net.dial_tcp(endpoint)
	assert(err == nil)
	wire :: "GET /timeout HTTP/1.1\r\nHost: localhost\r\n\r\n"
	sent, send_error := net.send_tcp(peer, transmute([]u8)string(wire))
	assert(send_error == nil && sent == len(wire))
	return peer
}

// Waits until the dispatcher holds exactly still_active requests: each
// abandoned one was cancelled, retired by the client and disposed.
wait_for_cancellations :: proc(f: ^Fixture, still_active: int) -> bool {
	until := time.tick_add(time.tick_now(), 3 * time.Second)
	for time.tick_diff(time.tick_now(), until) > 0 {
		sync.lock(&f.dispatcher.mu)
		settled := f.dispatcher.owners == still_active && f.dispatcher.pending == still_active
		sync.unlock(&f.dispatcher.mu)
		if settled {
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
	if !testing.expect(t, wait_for_cancellations(&f, 1)) {
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
	testing.expect(t, wait_for_cancellations(&f, 0))
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
	retire(&f)
	testing.expect(t, upstream.detach(&f.dispatcher))
	view, error = budget.snapshot(root)
	testing.expect_value(t, error, .None)
	testing.expect_value(t, view.used.jobs, 0)
	testing.expect_value(t, view.used.bytes, 0)
	testing.expect_value(t, surf.client_destroy(&f.client).kind, .None)
	testing.expect_value(t, async.destroy(&f.runtime).kind, .None)
}

// The request arrived whole; only the time to answer ran out. That is the
// gateway's timeout, not the client's (408 invites a replay).
@(test)
expired_request_deadline_answers_gateway_timeout :: proc(t: ^testing.T) {
	f: Fixture
	attach(&f)
	cancellation, created := server.new_request_context(
		nil,
		time.tick_add(time.tick_now(), -time.Second),
		rt.heap_allocator(),
	)
	assert(created)
	request := server.Request {
		cancellation = cancellation,
	}
	outbound := upstream.response(
		&f.dispatcher,
		&request,
		{method = .GET, url = "http://127.0.0.1:1/unused"},
		copy_body,
	)
	testing.expect_value(t, outbound.status, server.HTTP_Status.Gateway_Timeout)
	testing.expect(t, outbound.deferred.poll == nil)
	server.release_request_context(&request.cancellation)
	retire(&f)
	testing.expect(t, upstream.detach(&f.dispatcher))
	testing.expect_value(t, surf.client_destroy(&f.client).kind, .None)
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

	_ = surf.client_close(&f.client)
	async.shutdown(&f.runtime)
	assert(async.join(&f.runtime).kind == .None)
	testing.expect(t, upstream.detach(&f.dispatcher))
	assert(surf.client_destroy(&f.client).kind == .None)
	assert(async.destroy(&f.runtime).kind == .None)
}
