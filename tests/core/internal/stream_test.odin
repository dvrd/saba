package saba_core

import exchange "shared:async/http/exchange"
import "core:mem"
import owned "shared:async/owned"
import "core:strings"
import "core:testing"
import "core:time"
import async "shared:async"

@(test)
stream_submission_moves_only_on_acceptance :: proc(t: ^testing.T) {
	transfer: exchange.Exchange
	assert(
		exchange.init(&transfer, .GET, {chunk_capacity = 1, max_retained_bytes = 8}, context.allocator).kind == .None,
	)
	defer exchange.destroy(&transfer)
	assert(exchange.respond(&transfer, {status = 200, content_length = -1}).kind == .None)
	io := Stream_IO {
		_exchange = &transfer,
	}

	first, _ := owned.copy_bounded([]u8{1, 2, 3}, 8, context.allocator)
	second, _ := owned.copy_bounded([]u8{4}, 8, context.allocator)
	defer owned.destroy(&first); defer owned.destroy(&second)
	testing.expect_value(t, stream_submit(&io, &first), .Accepted)
	testing.expect(t, first.storage == nil && first.allocator.procedure == nil)
	testing.expect_value(t, stream_submit(&io, &second), .Backpressure)
	testing.expect_value(t, len(second.storage), 1)
	testing.expect(t, exchange.release_body(&transfer))
	io._submitted = false
	large, _ := owned.allocate(9, context.allocator)
	defer owned.destroy(&large)
	large.data = large.data[:1]
	// Storage larger than the queue ever retains is refused outright: draining
	// would never make room for it, so backpressure would never end.
	testing.expect_value(t, stream_submit(&io, &large), .Limit_Exceeded)
	testing.expect_value(t, len(large.storage), 9)
	testing.expect_value(t, stream_submit(nil, &second), .Invalid)
}

Stream_Test_Source :: struct {
	calls, releases, drops: int,
	chunk:                  owned.Chunk,
}
stream_test_next :: proc(data: rawptr, io: ^Stream_IO) -> Stream_Step {
	source := cast(^Stream_Test_Source)data
	source.calls += 1

	if source.calls > 1 {
		assert(source.releases == 1)
		return .Done
	}

	bytes, _ := make([]u8, 8, context.allocator)
	copy(bytes, "abc")
	source.chunk, _ = owned.take_custom(&bytes, 3, proc(storage: []u8, data: rawptr) {
			source := cast(^Stream_Test_Source)data
			assert(len(storage) == 8)
			source.releases += 1
			delete(storage)
		}, source)
	assert(stream_submit(io, &source.chunk) == .Accepted)
	assert(source.chunk.release == nil)

	return .Chunk
}
stream_test_drop :: proc(data: rawptr) {
	source := cast(^Stream_Test_Source)data
	source.drops += 1
	owned.destroy(&source.chunk)
}

@(test)
stream_driver_releases_chunk_before_next_and_drops_once :: proc(t: ^testing.T) {
	runtime := Server_Runtime {
		timeouts = resolve_timeouts({}),
		config = {keep_alive = {enabled = true}},
	}

	assert(async.init(&runtime.executor, {workers = 1, task_capacity = 1, io_capacity = 1}).kind == .None)
	defer async.destroy(&runtime.executor)
	source: Stream_Test_Source
	task := Connection_Task {
		runtime = &runtime,
		phase = .Dispatch,
		request = {method = "GET"},
	}

	init_connection_arena(&task)
	defer mem.dynamic_arena_destroy(&task.arena)
	response := Response {
		stream = {
			data = &source,
			next = stream_test_next,
			drop = stream_test_drop,
			content_length = -1,
			max_chunk_bytes = 8,
		},
	}

	assert(queue_response(&task, response))
	testing.expect(t, strings.contains(string(task.output[0]), "Transfer-Encoding: chunked\r\n"))
	producing, ok := stream_write_complete(&task)
	assert(ok && producing)
	task.phase = .Produce
	testing.expect_value(t, produce_stream(&task), .Yield)
	testing.expect_value(t, string(task.output[0]), "3\r\n")
	testing.expect_value(t, string(task.output[1]), "abc")
	testing.expect_value(t, source.releases, 0)
	producing, ok = stream_write_complete(&task)
	assert(ok && producing)
	testing.expect_value(t, source.releases, 1)
	task.phase = .Produce
	testing.expect_value(t, produce_stream(&task), .Yield)
	testing.expect_value(t, string(task.output[0]), "0\r\n\r\n")
	producing, ok = stream_write_complete(&task)
	assert(ok && !producing)
	drop_response_stream(&task)
	drop_response_stream(&task)
	testing.expect_value(t, source.drops, 1)
	testing.expect_value(t, source.releases, 1)
	testing.expect(t, task.streaming == nil)
}

@(test)
head_and_rejected_streams_release_producer_without_polling :: proc(t: ^testing.T) {
	runtime := Server_Runtime {
		timeouts = resolve_timeouts({}),
		config = {keep_alive = {enabled = true}},
	}

	assert(async.init(&runtime.executor, {workers = 1, task_capacity = 1, io_capacity = 1}).kind == .None)
	defer async.destroy(&runtime.executor)

	for method in ([]string{"HEAD", "GET"}) {
		source: Stream_Test_Source
		task := Connection_Task {
			runtime = &runtime,
			phase = .Dispatch,
			request = {method = method},
		}

		init_connection_arena(&task)
		response := Response {
			stream = {data = &source, next = stream_test_next, drop = stream_test_drop, content_length = 3},
		}

		if method == "HEAD" {
			assert(queue_response(&task, response))
			testing.expect(t, strings.contains(string(task.output[0]), "Content-Length: 3\r\n"))
			producing, ok := stream_write_complete(&task)
			assert(ok && !producing)
		} else {
			response.body = []u8{1}
			testing.expect(t, !queue_response(&task, response))
		}

		drop_response_stream(&task)
		testing.expect_value(t, source.calls, 0)
		testing.expect_value(t, source.drops, 1)
		mem.dynamic_arena_destroy(&task.arena)
	}

	source: Stream_Test_Source
	response := Response {
		stream = {data = &source, drop = stream_test_drop},
	}

	discard_response(&response)
	discard_response(&response)
	testing.expect_value(t, source.drops, 1)
	unsupported := Response {
		stream = {data = &source, drop = stream_test_drop},
	}

	testing.expect(t, !send_response(nil, unsupported))
	testing.expect_value(t, source.drops, 2)
}

@(test)
producer_wait_without_registered_timer_is_rejected :: proc(t: ^testing.T) {
	runtime := Server_Runtime {
		timeouts = resolve_timeouts({}),
	}

	assert(async.init(&runtime.executor, {workers = 1, task_capacity = 1, io_capacity = 1}).kind == .None)
	defer async.destroy(&runtime.executor)
	task := Connection_Task {
		runtime = &runtime,
		phase = .Dispatch,
		request = {method = "GET"},
	}

	init_connection_arena(&task)
	defer mem.dynamic_arena_destroy(&task.arena)
	response := Response {
		stream = {
			next = proc(_: rawptr, _: ^Stream_IO) -> Stream_Step {return .Waiting},
			content_length = -1,
			timeout = time.Second,
		},
	}

	assert(queue_response(&task, response))
	task.phase = .Produce
	testing.expect_value(t, produce_stream(&task), .Done)
	drop_response_stream(&task)
}

@(test)
stream_wait_and_write_budget_inherit_request_deadline :: proc(t: ^testing.T) {
	runtime := Server_Runtime {
		timeouts = resolve_timeouts({}),
	}

	assert(async.init(&runtime.executor, {workers = 1, task_capacity = 1, io_capacity = 1}).kind == .None)
	defer async.destroy(&runtime.executor)
	deadline := time.tick_add(time.tick_now(), time.Second)
	ctx, ok := new_request_context(nil, deadline, context.allocator)
	assert(ok)
	defer release_request_context(&ctx)
	task := Connection_Task {
		runtime = &runtime,
		phase = .Dispatch,
		request = {method = "GET", cancellation = ctx},
	}

	init_connection_arena(&task)
	defer mem.dynamic_arena_destroy(&task.arena)
	response := Response {
		stream = {
			next = proc(_: rawptr, _: ^Stream_IO) -> Stream_Step {return .Done},
			content_length = 0,
			timeout = time.Hour,
		},
	}

	assert(queue_response(&task, response))
	testing.expect(t, time.tick_diff(deadline, task.streaming.expires) <= 0)
	testing.expect(t, time.tick_diff(time.tick_now(), task.streaming.expires) <= time.Second)
	drop_response_stream(&task)
}
