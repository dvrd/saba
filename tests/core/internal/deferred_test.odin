package saba_core

import rt "base:runtime"
import "core:mem"
import "core:strings"
import "core:testing"
import "core:time"
import async "shared:async"
import signal "shared:async/signal"

Deferred_Source :: struct {
	calls, drops: ^int,
	late:         bool,
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

	if source.late {
		time.sleep(2 * time.Millisecond)
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

	assert(queue_response(&task, response))
	testing.expect_value(t, task.phase, .Await_Response)
	testing.expect_value(t, len(task.output[0]), 0)
	testing.expect_value(t, await_response(&task), .Yield)
	testing.expect_value(t, task.phase, .Write)
	testing.expect(t, strings.contains(string(task.output[0]), "201 Created"))
	testing.expect_value(t, string(task.output[1]), "abc")
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
		calls = &calls,
		drops = &drops,
		late  = true,
	}

	response := Response {
		deferred = {data = source, poll = deferred_poll, drop = deferred_drop, timeout = time.Millisecond},
	}

	assert(queue_response(&task, response))
	testing.expect_value(t, await_response(&task), .Yield)
	testing.expect_value(t, len(task.output[0]), 0)
	testing.expect_value(t, await_response(&task), .Yield)
	testing.expect(t, strings.contains(string(task.output[0]), "408 Request Timeout"))
	testing.expect_value(t, calls, 1)
	testing.expect_value(t, drops, 1)
	drop_deferred(&task)
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

	for mode in 0 ..< 8 {
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
		}

		task: Connection_Task
		testing.expect(t, !queue_response(&task, response))
		drop_deferred(&task)
	}

	testing.expect_value(t, calls, 0)
	testing.expect_value(t, drops, 8)
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
