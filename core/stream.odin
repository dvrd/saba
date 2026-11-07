package saba_core

import http "../../http"
import exchange "../../http/exchange"
import http1 "../../http/v1"
import rt "base:runtime"
import "core:mem"
import owned "core:mem/owned"
import "core:strconv"
import "core:time"
import async "shared:async"

Stream_Step :: enum {
	Chunk,
	Waiting,
	Yield,
	Done,
	Failed,
}

// Returning a stream transfers producer ownership even if head validation/send
// fails. next/drop run serially outside locks and may migrate workers. Producers
// should do bounded, nonblocking work; the opt-in file adapter documents its
// synchronous filesystem latency. Producer data must survive through drop. An accepted
// chunk is released before the next producer call, and before producer drop.
Response_Stream :: struct {
	data:            rawptr,
	next:            proc(data: rawptr, io: ^Stream_IO) -> Stream_Step,
	drop:            proc(data: rawptr),
	// -1 selects chunked transfer; zero is a known empty representation.
	content_length:  i64,
	// Zero selects 64 KiB retained backing and 8 MiB total produced bytes.
	max_chunk_bytes: int,
	max_body_bytes:  i64,
	// Total stream lifetime; zero inherits the ordinary response timeout.
	timeout:         time.Duration,
}

// All fields/views are borrowed only until next returns. Use stream_wait for
// timer suspension; raw runtime/task pointers must not escape into host jobs.
Stream_IO :: struct {
	runtime:              ^async.Runtime,
	cancellation:         Request_Context,
	max_chunk_bytes:      int,
	_exchange:            ^exchange.Exchange,
	_deadline:            async.Deadline,
	_submitted, _waiting: bool,
}

stream_submit :: proc(io: ^Stream_IO, chunk: ^owned.Chunk) -> exchange.Submit_Result {
	if io == nil || io._exchange == nil || chunk == nil || len(chunk.data) == 0 do return .Invalid
	if io._submitted || io._waiting do return .Backpressure
	result := exchange.submit(io._exchange, chunk)
	if result == .Accepted do io._submitted = true
	return result
}

stream_wait :: proc(io: ^Stream_IO, deadline: async.Deadline) -> async.Error {
	if io == nil || io.runtime == nil || io._submitted || io._waiting || deadline.epoch != io._deadline.epoch do return {kind = .Invalid_Config}
	bounded := deadline
	bounded.at = min(bounded.at, io._deadline.at)
	error := async.sleep_until(io.runtime, bounded)
	if error.kind == .Pending do io._waiting = true
	return error
}

streaming_response :: proc(response: Response) -> bool {return stream_present(response.stream)}
@(private)
stream_present :: proc(producer: Response_Stream) -> bool {
	return(
		producer.next != nil ||
		producer.drop != nil ||
		producer.data != nil ||
		producer.content_length != 0 ||
		producer.max_chunk_bytes != 0 ||
		producer.max_body_bytes != 0 ||
		producer.timeout != 0 \
	)
}

@(private)
Response_Stream_State :: struct {
	producer:                   Response_Stream,
	exchange:                   exchange.Exchange,
	expires:                    time.Tick,
	deadline:                   async.Deadline,
	prefix:                     [32]u8,
	chunked, pending, terminal: bool,
	max_chunk_bytes:            int,
}

@(private)
drop_response_stream :: proc(task: ^Connection_Task) {
	old := task.streaming; task.streaming = nil
	if old == nil do return
	exchange.destroy(&old.exchange)
	producer := old.producer; old.producer = {}
	if producer.drop != nil do producer.drop(producer.data)
	free(old, rt.heap_allocator())
}

@(private)
stream_write_budget :: proc(task: ^Connection_Task) -> bool {
	state := task.streaming
	remaining := time.tick_diff(time.tick_now(), state.expires)
	if remaining <= 0 {
		observe_failure(task, .Timeout)
		cancel_request_context(task.request.cancellation, .Deadline); return false
	}
	duration := min(remaining, task.runtime.timeouts.response)
	task.deadline = async.deadline_after(&task.runtime.executor, duration)
	task.connection.write_deadline = time.tick_add(time.tick_now(), duration)
	task.output_index, task.output_offset = 0, 0
	task.phase = .Write
	return true
}

@(private)
queue_stream_response :: proc(task: ^Connection_Task, response: Response) -> bool {
	producer := response.stream
	if producer.next == nil ||
	   len(response.body) != 0 ||
	   task.upgrade.data != nil ||
	   task.upgrade.resume != nil ||
	   task.upgrade.drop != nil {
		if producer.drop != nil do producer.drop(producer.data)
		observe_failure(task, .Protocol_Error); return false
	}
	state, error := new(Response_Stream_State, rt.heap_allocator())
	if error != nil || state == nil {
		if producer.drop != nil do producer.drop(producer.data)
		observe_failure(task, .Allocation_Error); return false
	}
	state.producer = producer; task.streaming = state
	limit := producer.max_chunk_bytes
	if limit == 0 do limit = 64 * mem.Kilobyte
	duration := producer.timeout
	if duration == 0 do duration = task.runtime.timeouts.response
	if limit < 1 || limit > mem.Megabyte || duration <= 0 || duration > MAX_SERVER_TIMEOUT {
		observe_failure(task, .Protocol_Error); return false
	}
	state.max_chunk_bytes = limit
	state.expires = time.tick_add(time.tick_now(), duration)
	inherited := request_deadline(task.request.cancellation)
	if inherited != (time.Tick{}) && time.tick_diff(inherited, state.expires) > 0 do state.expires = inherited
	remaining := time.tick_diff(time.tick_now(), state.expires)
	if remaining <= 0 {
		observe_failure(task, .Timeout); return false
	}
	state.deadline = async.deadline_after(&task.runtime.executor, remaining)
	method: http.Method = .GET
	if task.request.method == "HEAD" do method = .HEAD
	if exchange.init(&state.exchange, method, {chunk_capacity = 1, max_retained_bytes = limit, max_body_bytes = producer.max_body_bytes}, rt.heap_allocator()).kind !=
	   .None {
		observe_failure(task, .Protocol_Error); return false
	}
	status := response.status
	if status == .None do status = .OK
	head := http.Response_Head {
		status         = int(status),
		headers        = response.headers,
		content_length = producer.content_length,
	}
	if exchange.respond(&state.exchange, head).kind != .None {
		observe_failure(task, .Protocol_Error); return false
	}
	stored, _ := exchange.head(&state.exchange)
	buffer, ae := make([]u8, RESPONSE_HEADER_LIMIT, mem.dynamic_arena_allocator(&task.arena))
	if ae != nil {
		observe_failure(task, .Allocation_Error); return false
	}
	task.reuse_after_write = !response.close_connection && response_can_reuse(task, status)
	profile: http1.Response_Profile = .Close
	if task.reuse_after_write do profile = .Keep_Alive
	n, e := http1.response_stream_head_encode(
		buffer,
		stored,
		profile,
		method,
		max_bytes = RESPONSE_HEADER_LIMIT,
	)
	if e.kind != .None {
		observe_failure(task, .Protocol_Error); return false
	}
	state.chunked = producer.content_length < 0
	if !http.response_body_allowed(int(status), task.request.method) {
		if exchange.finish(&state.exchange).kind != .None do return false
		state.terminal = true
	}
	task.output = {buffer[:n], nil, nil}
	task.finish_after_write = true
	if task.observed do task.event.status = status
	return stream_write_budget(task)
}

@(private)
produce_stream :: proc(task: ^Connection_Task) -> async.Resume_Result {
	state := task.streaming
	if deadline_expired(state.expires) {
		observe_failure(task, .Timeout)
		cancel_request_context(task.request.cancellation, .Deadline); return .Done
	}
	if request_cancelled(task.request.cancellation) {
		observe_failure(
			task,
			.Timeout if \
				request_context_status(task.request.cancellation) == .Deadline else \
				.Cancelled,
		)
		return .Done
	}
	io := Stream_IO {
		runtime         = &task.runtime.executor,
		cancellation    = task.request.cancellation,
		max_chunk_bytes = state.max_chunk_bytes,
		_exchange       = &state.exchange,
		_deadline       = state.deadline,
	}
	step := state.producer.next(state.producer.data, &io)
	if deadline_expired(state.expires) {
		observe_failure(task, .Timeout)
		cancel_request_context(task.request.cancellation, .Deadline); return .Done
	}
	if request_cancelled(task.request.cancellation) {
		observe_failure(
			task,
			.Timeout if \
				request_context_status(task.request.cancellation) == .Deadline else \
				.Cancelled,
		)
		return .Done
	}
	switch step {
	case .Waiting:
		if !io._waiting || io._submitted {
			observe_failure(task, .Protocol_Error); return .Done
		}
		return .Waiting
	case .Yield:
		if io._waiting || io._submitted {
			observe_failure(task, .Protocol_Error); return .Done
		}
		return .Yield
	case .Chunk:
		if !io._submitted || io._waiting {
			observe_failure(task, .Protocol_Error); return .Done
		}
		payload, ok := exchange.body(&state.exchange)
		if !ok {
			observe_failure(task, .Protocol_Error); return .Done
		}
		state.pending = true
		if state.chunked {
			size := strconv.write_uint(state.prefix[:], u64(len(payload)), 16)
			n := len(size); copy(state.prefix[n:], "\r\n")
			task.output = {state.prefix[:n + 2], payload, transmute([]u8)string("\r\n")}
		} else {
			task.output = {nil, payload, nil}
		}
		if !stream_write_budget(task) {
			observe_failure(task, .Timeout); return .Done
		}
		return .Yield
	case .Done:
		if io._submitted || io._waiting || exchange.finish(&state.exchange).kind != .None {
			observe_failure(task, .Protocol_Error); return .Done
		}
		state.terminal = true
		task.output = {}
		if state.chunked do task.output[0] = transmute([]u8)string("0\r\n\r\n")
		if !stream_write_budget(task) {
			observe_failure(task, .Timeout); return .Done
		}
		return .Yield
	case .Failed:
		observe_failure(task, .IO_Error); return .Done
	}
	return .Done
}

// Called only after every output slice has finished its final socket use.
@(private)
stream_write_complete :: proc(task: ^Connection_Task) -> (produce, ok: bool) {
	state := task.streaming
	if state.pending {
		state.pending = false
		if !exchange.release_body(&state.exchange) {
			observe_failure(task, .Protocol_Error); return false, false
		}
	}
	if !state.terminal do return true, true
	if exchange.complete(&state.exchange).kind != .None {
		observe_failure(task, .Protocol_Error); return false, false
	}
	drop_response_stream(task)
	return false, true
}
