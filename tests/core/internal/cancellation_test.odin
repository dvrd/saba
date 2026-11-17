package saba_core

import rt "base:runtime"
import "core:mem"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import async "shared:async"

@(test)
retained_context_survives_arena_runtime_and_owner_release :: proc(t: ^testing.T) {
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	allocator := mem.tracking_allocator(&tracker)
	server, _ := new(Server_Cancellation, rt.heap_allocator())
	server.references = 1
	owner, ok := new_request_context(server, {}, allocator)
	assert(ok)
	retained, valid := retain_request_context(owner)
	assert(valid)
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	_ = make([]u8, 32768, mem.dynamic_arena_allocator(&arena))
	mem.dynamic_arena_destroy(&arena)
	sync.atomic_store(&server.stopping, true)
	release_server_cancellation(server)
	release_request_context(&owner)
	release_request_context(&owner)
	testing.expect_value(t, request_context_status(retained), .Shutdown)
	testing.expect(t, request_cancelled(retained))
	testing.expect(t, tracker.current_memory_allocated > 0)
	release_request_context(&retained)
	release_request_context(&retained)
	testing.expect_value(t, tracker.current_memory_allocated, i64(0))
}

@(test)
deadline_and_first_terminal_status_are_stable :: proc(t: ^testing.T) {
	past := time.tick_add(time.tick_now(), -time.Second)
	owner, ok := new_request_context(nil, past, context.allocator)
	assert(ok)
	defer release_request_context(&owner)
	testing.expect_value(t, request_deadline(owner), past)
	testing.expect_value(t, request_context_status(owner), .Deadline)
	cancel_request_context(owner, .Completed)
	testing.expect_value(t, request_context_status(owner), .Deadline)
	testing.expect_value(t, request_context_status({}), .Unavailable)
	_, valid := retain_request_context({})
	testing.expect(t, !valid)
}

@(test)
late_response_disposes_owned_continuation_once :: proc(t: ^testing.T) {
	runtime := Server_Runtime {
		config = {handler_timeout = time.Nanosecond},
	}

	drops := 0
	runtime.config.handler_data = &drops
	runtime.config.handler = proc(data: rawptr, _: ^Connection, request: ^Request) -> Response {
		assert(request.cancellation._state != nil)
		for !request_cancelled(request.cancellation) {}
		return {status = .OK, upgrade = {data = data, drop = proc(data: rawptr) {(cast(^int)data)^ += 1}}}
	}

	task := Connection_Task {
		runtime = &runtime,
	}

	response := dispatch_request(&task)
	testing.expect_value(t, response.status, .Request_Timeout)
	testing.expect_value(t, drops, 1)
	discard_response(&response)
	testing.expect_value(t, drops, 1)
	task.response_finished = true
	finish_request_context(&task)
	finish_request_context(&task)
	testing.expect(t, task.request.cancellation._state == nil)
}

@(test)
observable_failures_cancel_without_observability :: proc(t: ^testing.T) {
	for sample in ([]struct {
			error:  async.Error_Kind,
			status: Request_Status,
		}{{.Peer_Closed, .Peer_Closed}, {.Timeout, .Deadline}, {.Cancelled, .Shutdown}, {.Network_Error, .Failed}}) {
		task: Connection_Task
		task.request.cancellation, _ = new_request_context(nil, {}, context.allocator)
		retained, _ := retain_request_context(task.request.cancellation)
		observe_io_error(&task, {kind = sample.error})
		testing.expect_value(t, request_context_status(retained), sample.status)
		release_request_context(&task.request.cancellation)
		testing.expect_value(t, request_context_status(retained), sample.status)
		release_request_context(&retained)
	}
}

@(test)
context_retains_and_shutdown_are_thread_safe :: proc(t: ^testing.T) {
	server, _ := new(Server_Cancellation, rt.heap_allocator())
	server.references = 1
	owner, ok := new_request_context(server, {}, context.allocator)
	assert(ok)
	workers: [8]^thread.Thread

	for &worker in workers {
		worker = thread.create_and_start_with_poly_data(owner, proc(source: Request_Context) {
			for _ in 0 ..< 2000 {
				retained, ok := retain_request_context(source)
				assert(ok)
				status := request_context_status(retained)
				assert(status == .Active || status == .Shutdown)
				release_request_context(&retained)
			}
		})
		assert(worker != nil)
	}

	sync.atomic_store(&server.stopping, true)
	release_server_cancellation(server)

	for worker in workers {
		thread.join(worker)
		thread.destroy(worker)
	}

	testing.expect_value(t, request_context_status(owner), .Shutdown)
	release_request_context(&owner)
}

@(test)
failed_context_allocation_retains_no_parent_reference :: proc(t: ^testing.T) {
	parent, _ := new(Server_Cancellation, rt.heap_allocator())
	parent.references = 1
	owner, ok := new_request_context(parent, {}, mem.nil_allocator())
	testing.expect(t, !ok && owner._state == nil)
	testing.expect_value(t, parent.references, i64(1))
	release_request_context(&owner)
	release_server_cancellation(parent)
}
