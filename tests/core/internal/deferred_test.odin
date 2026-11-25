package saba_core

import rt "base:runtime"
import "core:mem"
import "core:strings"
import "core:testing"
import "core:time"
import http3 "shared:async/http/v3"
import async "shared:async"
import signal "shared:async/signal"

Deferred_Source :: struct {
	calls, drops: ^int,
	expire:       ^time.Tick,
	bytes:        [3]u8,
	retained:     ^signal.Signal,
}
deferred_poll :: proc(p: rawptr, io: ^Deferred_IO) -> (Response, Deferred_Step) {
	source := cast(^Deferred_Source)p
	source.calls^ += 1

	if source.retained != nil {
		retained, ok := signal.retain(io.wake)
		assert(ok)
		source.retained^ = retained
	}

	if source.expire != nil {
		source.expire^ = time.tick_add(time.tick_now(), -time.Second)
	}
	body, error := make([]u8, 3, io.allocator)
	assert(error == nil)
	copy(body, source.bytes[:])

	return {status = .Created, body = body}, .Ready
}
deferred_drop :: proc(p: rawptr) {
	source := cast(^Deferred_Source)p
	source.drops^ += 1
	free(source, rt.heap_allocator())
}

@(test)
deferred_head_waits_for_ready_and_copies_survive_source_disposal :: proc(t: ^testing.T) {
	runtime := Server_Runtime {
		timeouts = resolve_timeouts({}),
	}

	assert(async.init(&runtime.executor, {workers = 1, task_capacity = 1, io_capacity = 1}).kind == .None)
	defer async.destroy(&runtime.executor)
	task := Connection_Task {
		runtime = &runtime,
		request = {method = "GET"},
	}

	init_connection_arena(&task)
	defer mem.dynamic_arena_destroy(&task.arena)
	assert(begin_request_context(&task))
	defer finish_request_context(&task)
	calls, drops: int
	retained: signal.Signal
	source := new(Deferred_Source, rt.heap_allocator())
	source^ = {
		calls    = &calls,
		drops    = &drops,
		bytes    = {'a', 'b', 'c'},
		retained = &retained,
	}

	response := Response {
		deferred = {data = source, poll = deferred_poll, drop = deferred_drop},
	}

	pipeline := transmute([]u8)string("GET /next HTTP/1.1\r\n")
	task.connection.read_buffer = pipeline
	assert(queue_response(&task, response))
	testing.expect_value(t, task.phase, .Await_Response)
	testing.expect_value(t, len(task.output[0]), 0)
	testing.expect_value(t, await_response(&task), .Yield)
	testing.expect_value(t, task.phase, .Write)
	testing.expect(t, strings.contains(string(task.output[0]), "201 Created"))
	testing.expect_value(t, string(task.output[1]), "abc")
	testing.expect(t, raw_data(task.connection.read_buffer) == raw_data(pipeline))
	testing.expect_value(t, calls, 1)
	testing.expect_value(t, drops, 1)
	testing.expect(t, !signal.wake(retained))
	signal.release(&retained)
	drop_deferred(&task)
	testing.expect_value(t, drops, 1)
}

@(test)
late_deferred_result_does_not_commit_its_status_and_drops_once :: proc(t: ^testing.T) {
	runtime := Server_Runtime {
		timeouts = resolve_timeouts({}),
	}

	assert(async.init(&runtime.executor, {workers = 1, task_capacity = 1, io_capacity = 1}).kind == .None)
	defer async.destroy(&runtime.executor)
	task := Connection_Task {
		runtime = &runtime,
		request = {method = "GET"},
	}

	init_connection_arena(&task)
	defer mem.dynamic_arena_destroy(&task.arena)
	assert(begin_request_context(&task))
	defer finish_request_context(&task)
	calls, drops: int
	source := new(Deferred_Source, rt.heap_allocator())
	source^ = {
		calls  = &calls,
		drops  = &drops,
		expire = &task.deferred_expires,
	}

	response := Response {
		deferred = {data = source, poll = deferred_poll, drop = deferred_drop},
	}

	assert(queue_response(&task, response))
	testing.expect_value(t, await_response(&task), .Yield)
	testing.expect(t, strings.contains(string(task.output[0]), "408 Request Timeout"))
	testing.expect_value(t, calls, 1)
	testing.expect_value(t, drops, 1)
	drop_deferred(&task)
	testing.expect_value(t, drops, 1)
}

@(test)
deferred_deadline_that_expires_during_setup_returns_408_without_polling :: proc(t: ^testing.T) {
	fixture: Resource_Test
	resource_test_init(&fixture)
	defer resource_test_finish(&fixture)
	calls, drops: int
	source := new(Deferred_Source, rt.heap_allocator())
	source^ = {calls = &calls, drops = &drops}
	fixture.task.request.cancellation._state.deadline = time.tick_add(time.tick_now(), -time.Second)
	assert(queue_response(&fixture.task, {deferred = {data = source, poll = deferred_poll, drop = deferred_drop}}))
	testing.expect_value(t, await_response(&fixture.task), .Yield)
	testing.expect(t, strings.contains(string(fixture.task.output[0]), "408 Request Timeout"))
	testing.expect_value(t, calls, 0)
	testing.expect_value(t, drops, 1)
}

@(test)
invalid_and_blocking_deferred_responses_dispose_without_polling :: proc(t: ^testing.T) {
	calls, drops: int

	for mode in 0 ..< 3 {
		source := new(Deferred_Source, rt.heap_allocator())
		source^ = {
			calls = &calls,
			drops = &drops,
		}

		response := Response {
			deferred = {data = source, poll = deferred_poll, drop = deferred_drop},
		}

		if mode == 0 {
			response.body = []u8{42}
			task: Connection_Task
			testing.expect(t, !queue_response(&task, response))
		} else if mode == 1 {
			testing.expect(t, !send_response(nil, response))
		} else {
			discard_response(&response)
			discard_response(&response)
		}
	}

	testing.expect_value(t, calls, 0)
	testing.expect_value(t, drops, 3)
}

deferred_count_drop :: proc(p: rawptr) {
	(cast(^int)p)^ += 1
}

@(test)
malformed_deferred_modes_release_every_transferred_owner_without_polling :: proc(t: ^testing.T) {
	calls, drops, other_drops: int

	for mode in 0 ..< 10 {
		source := new(Deferred_Source, rt.heap_allocator())
		source^ = {
			calls = &calls,
			drops = &drops,
		}

		response := Response {
			deferred = {data = source, poll = deferred_poll, drop = deferred_drop},
		}

		switch mode {
		case 0:
			response.body = []u8{42}
		case 1:
			response.status = .OK
		case 2:
			response.headers = []Header{{"X-Fixture", "value"}}
		case 3:
			response.close_connection = true
		case 4:
			response.upgrade = {
				data = &other_drops,
				drop = deferred_count_drop,
			}
		case 5:
			response.stream = {
				data = &other_drops,
				drop = deferred_count_drop,
			}
		case 6:
			response.deferred.timeout = -time.Nanosecond
		case 7:
			response.deferred.poll = nil
		case 8:
			response.trailers = []Header{{"X-Trailer", "value"}}
		case 9:
			response.uncoded = true
		}

		task: Connection_Task
		testing.expect(t, !queue_response(&task, response))
		drop_deferred(&task)
	}

	testing.expect_value(t, calls, 0)
	testing.expect_value(t, drops, 10)
	testing.expect_value(t, other_drops, 2)
}

@(test)
deferred_setup_failure_after_transfer_keeps_drop_owned_by_connection :: proc(t: ^testing.T) {
	runtime := Server_Runtime {
		timeouts = resolve_timeouts({}),
	}

	assert(async.init(&runtime.executor, {workers = 1, task_capacity = 1, io_capacity = 1}).kind == .None)
	defer async.destroy(&runtime.executor)
	task := Connection_Task {
		runtime = &runtime,
	}

	init_connection_arena(&task)
	defer mem.dynamic_arena_destroy(&task.arena)
	buffer, error := make([]u8, REQUEST_HEADER_LIMIT + 1, rt.heap_allocator())
	assert(error == nil)
	defer delete(buffer, rt.heap_allocator())
	task.connection.read_buffer = buffer
	calls, drops: int
	source := new(Deferred_Source, rt.heap_allocator())
	source^ = {
		calls = &calls,
		drops = &drops,
	}

	response := Response {
		deferred = {data = source, poll = deferred_poll, drop = deferred_drop},
	}

	testing.expect(t, !queue_response(&task, response))
	testing.expect_value(t, drops, 0)
	drop_deferred(&task)
	drop_deferred(&task)
	testing.expect_value(t, calls, 0)
	testing.expect_value(t, drops, 1)
}

Late_Deferred_Probe :: struct {
	task:                                    ^Connection_Task,
	polls, continuation_drops, result_drops: int,
}

late_deferred_handler :: proc(data: rawptr, conn: ^Connection, request: ^Request) -> Response {
	probe := cast(^Late_Deferred_Probe)data
	probe.task = conn._task
	return {deferred = {data = probe, poll = late_deferred_poll, drop = late_deferred_drop}}
}

late_deferred_poll :: proc(data: rawptr, io: ^Deferred_IO) -> (Response, Deferred_Step) {
	probe := cast(^Late_Deferred_Probe)data
	probe.polls += 1
	if probe.polls == 1 {
		return {}, .Waiting
	}

	// Move the deadline within the callback to exercise the commit boundary
	// without sleeps or dependence on scheduler timing.
	probe.task.deferred_expires = time.tick_add(time.tick_now(), -time.Second)
	return {status = .Created, upgrade = {data = &probe.result_drops, drop = deferred_count_drop}}, .Ready
}

late_deferred_drop :: proc(data: rawptr) {
	(cast(^Late_Deferred_Probe)data).continuation_drops += 1
}

@(test)
http2_late_deferred_result_retires_stream_and_drops_both_owners :: proc(t: ^testing.T) {
	fixture: Resource_Test
	resource_test_init(&fixture)
	defer resource_test_finish(&fixture)
	probe: Late_Deferred_Probe
	fixture.runtime.config.handler = late_deferred_handler
	fixture.runtime.config.handler_data = &probe
	parent := &fixture.task
	assert(h2_begin(parent))
	defer h2_destroy(parent)
	assert(h2_request_open(parent, {summary = {method = "GET", path = "/"}, end_stream = true}))

	testing.expect(t, probe.task.deferred_buffer == nil)
	retained, ok := retain_request_context(probe.task.request.cancellation)
	assert(ok)
	defer release_request_context(&retained)
	testing.expect(t, !h2_requests_pump(parent))
	testing.expect_value(t, probe.continuation_drops, 0)
	testing.expect(t, h2_requests_pump(parent))
	testing.expect(t, parent.http2.requests[0] == nil)
	testing.expect_value(t, request_context_status(retained), .Deadline)
	testing.expect_value(t, probe.continuation_drops, 1)
	testing.expect_value(t, probe.result_drops, 1)
}

@(test)
http3_late_deferred_result_disposes_owned_output_before_commit :: proc(t: ^testing.T) {
	runtime: Server_Runtime
	owner: Http3
	fixture: H3_Probe
	h3_unit_init(&runtime, &owner, &fixture)
	defer h3_unit_destroy(&runtime)
	probe: Late_Deferred_Probe
	owner.config.handler = late_deferred_handler
	owner.config.handler_data = &probe
	request := http3.Server_Request{method = "GET", target = "/"}
	response: http3.Server_Response

	testing.expect_value(t, http3_poll(&owner, &request, &response), .Pending)
	testing.expect(t, probe.task.deferred_buffer == nil)
	testing.expect_value(t, http3_poll(&owner, &request, &response), .Failed)
	testing.expect_value(t, response.status, 0)
	testing.expect_value(t, request_context_status(probe.task.request.cancellation), .Deadline)
	http3_release(&owner, &request)
	testing.expect_value(t, probe.continuation_drops, 1)
	testing.expect_value(t, probe.result_drops, 1)
}

@(test)
http3_expired_inline_handler_discards_result_and_returns_request_timeout :: proc(t: ^testing.T) {
	runtime: Server_Runtime
	owner: Http3
	fixture: H3_Probe
	h3_unit_init(&runtime, &owner, &fixture)
	defer h3_unit_destroy(&runtime)
	drops: int
	owner.config.handler_data = &drops
	owner.config.handler = proc(data: rawptr, conn: ^Connection, request: ^Request) -> Response {
		cancel_request_context(request.cancellation, .Deadline)
		return {status = .Created, upgrade = {data = data, drop = deferred_count_drop}}
	}
	request := http3.Server_Request{method = "GET", target = "/"}
	response: http3.Server_Response
	testing.expect_value(t, http3_poll(&owner, &request, &response), .Ready)
	testing.expect_value(t, response.status, 504)
	http3_release(&owner, &request)
	testing.expect_value(t, drops, 1)
}
