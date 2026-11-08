package saba_core

import "core:mem"
import budget "core:sync/budget"
import "core:time"
import async "shared:async"
import signal "shared:async/signal"

Deferred_Step :: enum {
	Waiting,
	Ready,
	Failed,
}

// Owned pre-header continuation. poll/drop run serially on the connection owner,
// outside locks. poll must be bounded and nonblocking; it may submit independent
// work on its first invocation. Returning transfers ownership even on rejection.
// No response fields may accompany it. A zero timeout uses the response timeout;
// the request deadline always caps it. Pending pipeline input is bounded by the
// ordinary header limit; exceeding it closes the connection without dispatch.
Deferred_Response :: struct {
	data:    rawptr,
	poll:    proc(data: rawptr, io: ^Deferred_IO) -> (Response, Deferred_Step),
	drop:    proc(data: rawptr),
	timeout: time.Duration,
}

// Call-only borrows. Retain wake separately for jobs; the server detaches it
// before retiring the continuation or connection. Copy final bytes into allocator
// before releasing job ownership. Never let work borrow allocator or request data.
Deferred_IO :: struct {
	resources: budget.Scope,
	backing_allocator: mem.Allocator,
	allocator:    mem.Allocator,
	cancellation: Request_Context,
	wake:         signal.Signal,
}

@(private)
deferred_present :: proc(value: Deferred_Response) -> bool {
	return value.data != nil || value.poll != nil || value.drop != nil || value.timeout != 0
}

@(private)
drop_deferred :: proc(task: ^Connection_Task) {
	old := task.deferred; task.deferred = {}
	signal.detach(task.deferred_signal)
	signal.release(&task.deferred_signal)
	if old.drop != nil do old.drop(old.data)
}

@(private)
queue_deferred :: proc(task: ^Connection_Task, response: Response) -> bool {
	prepared := response
	value := response.deferred
	if value.poll == nil ||
	   response.status != .None ||
	   response.close_connection ||
	   len(response.headers) != 0 ||
	   len(response.body) != 0 ||
	   stream_present(response.stream) ||
	   response.upgrade.data != nil ||
	   response.upgrade.resume != nil ||
	   response.upgrade.drop != nil {
		discard_response(&prepared); observe_failure(task, .Protocol_Error); return false
	}
	duration := value.timeout
	if duration == 0 do duration = task.runtime.timeouts.response
	if duration <= 0 || duration > MAX_SERVER_TIMEOUT {
		discard_response(&prepared); observe_failure(task, .Protocol_Error); return false
	}
	task.deferred = value
	task.deferred_expires = time.tick_add(time.tick_now(), duration)
	inherited := request_deadline(task.request.cancellation)
	if inherited != (time.Tick{}) && time.tick_diff(inherited, task.deferred_expires) > 0 {
		task.deferred_expires = inherited
	}
	remaining := time.tick_diff(time.tick_now(), task.deferred_expires)
	if remaining <= 0 do return false
	task.deferred_deadline = async.deadline_after(&task.runtime.executor, remaining)
	s, ok := signal.create(&task.runtime.executor, &task.task)
	if !ok {
		observe_failure(task, .Allocation_Error); return false
	}
	task.deferred_signal = s
	task.deferred_used = len(task.connection.read_buffer)
	if task.deferred_used > REQUEST_HEADER_LIMIT do return false
	capacity := max(512, task.deferred_used)
	buffer, error := make([]u8, capacity, mem.dynamic_arena_allocator(&task.arena))
	if error != nil {
		observe_failure(task, .Allocation_Error); return false
	}
	copy(buffer, task.connection.read_buffer)
	task.deferred_buffer = buffer
	task.phase = .Await_Response
	return true
}

@(private)
await_response :: proc(task: ^Connection_Task) -> async.Resume_Result {
	if deadline_expired(task.deferred_expires) {
		cancel_request_context(task.request.cancellation, .Deadline)
	}
	status := request_context_status(task.request.cancellation)
	if status != .Active {
		drop_deferred(task)
		observe_failure(task, .Timeout if status == .Deadline else .Cancelled)
		response := Response {
			status           = .Request_Timeout,
			close_connection = true,
		}
		if status != .Deadline do response.status = .Service_Unavailable
		if !queue_response(task, response) do return .Done
		return .Yield
	}
	io := Deferred_IO {
		resources = task.resource_operation,
		backing_allocator = task.request.backing_allocator,
		allocator    = mem.dynamic_arena_allocator(&task.arena),
		cancellation = task.request.cancellation,
		wake         = task.deferred_signal,
	}
	response, step := task.deferred.poll(task.deferred.data, &io)
	// A nonblocking callback can still lose its budget before returning a result.
	if deadline_expired(task.deferred_expires) || request_cancelled(io.cancellation) {
		discard_response(&response)
		if deadline_expired(task.deferred_expires) {
			cancel_request_context(io.cancellation, .Deadline)
		}
		return .Yield
	}
	if step != .Ready {
		discard_response(&response)
		if step == .Failed {
			if resource_pressure(task) {
				drop_deferred(task); resource_reject(task); return .Yield
			}
			observe_failure(task, .IO_Error); return .Done
		}
		return await_peer_or_result(task)
	}
	drop_deferred(task)
	if deferred_present(response.deferred) {
		discard_response(&response); observe_failure(task, .Protocol_Error); return .Done
	}
	task.connection.read_buffer = task.deferred_buffer[:task.deferred_used]
	task.deferred_buffer = nil; task.deferred_used = 0
	task.phase = .Dispatch
	if !queue_response(task, response) do return .Done
	return .Yield
}

// Read readiness detects EOF while work is blocked. Preserve bounded pipelined
// input for the next request, and never spin on an unread readable socket.
@(private)
await_peer_or_result :: proc(task: ^Connection_Task) -> async.Resume_Result {
	if task.deferred_used == len(task.deferred_buffer) {
		if task.deferred_used == REQUEST_HEADER_LIMIT {
			observe_failure(task, .Protocol_Error); return .Done
		}
		capacity := min(2 * len(task.deferred_buffer), REQUEST_HEADER_LIMIT)
		buffer, error := make([]u8, capacity, mem.dynamic_arena_allocator(&task.arena))
		if error != nil {
			if resource_pressure(task) {drop_deferred(task); resource_reject(task); return .Yield}
			observe_failure(task, .Allocation_Error); return .Done
		}
		copy(buffer, task.deferred_buffer); task.deferred_buffer = buffer
	}
	n, error := async.read(
		task.socket,
		task.deferred_buffer[task.deferred_used:],
		task.deferred_deadline,
	)
	if error.kind == .Pending do return .Waiting
	if error.kind == .Timeout {
		cancel_request_context(task.request.cancellation, .Deadline); return .Yield
	}
	if error.kind != .None || n == 0 {
		cancel_request_context(task.request.cancellation, .Peer_Closed)
		observe_failure(task, .Cancelled); return .Done
	}
	task.deferred_used += n
	return .Yield
}
