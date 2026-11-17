package saba_offload

import server "../core"
import rt "base:runtime"
import "core:mem"
import "core:time"
import pool "shared:async/offload"
import signal "shared:async/signal"

// Build runs only on the connection owner after successful work. It must copy
// every response byte into allocator before the job is released. It must not
// return another deferred response, block, or return job-owned continuations.
Build :: #type proc(data: rawptr, allocator: mem.Allocator) -> (server.Response, bool)
State :: struct {
	lane:            ^pool.Pool,
	work:            pool.Work,
	handle:          pool.Handle,
	build:           Build,
	started:         bool,
	unmanaged_bytes: u64,
}
Notice :: struct {
	signal: signal.Signal,
}

// Preserve the original procedure signature for existing callback tables.
response :: proc(
	lane: ^pool.Pool,
	work: ^pool.Work,
	build: Build,
	timeout: time.Duration = 0,
) -> (
	server.Response,
	bool,
) {
	return response_with_unmanaged_bytes(lane, work, build, timeout)
}

// Success transfers work immediately, even before submission on the first
// owner poll. Failure preserves work. The pool and host dependencies outlive
// every job, including non-interruptible work after connection shutdown.
response_with_unmanaged_bytes :: proc(
	lane: ^pool.Pool,
	work: ^pool.Work,
	build: Build,
	timeout: time.Duration = 0,
	unmanaged_bytes: u64 = 0,
) -> (
	server.Response,
	bool,
) {
	if lane == nil || work == nil || work.run == nil || (work.data != nil && work.drop == nil) || build == nil {
		return {}, false
	}
	state, error := new(State, rt.heap_allocator())
	if error != nil || state == nil {
		return {}, false
	}
	state.lane, state.work, state.build = lane, work^, build
	state.unmanaged_bytes = unmanaged_bytes
	work^ = {}
	return {deferred = {data = state, poll = poll_result, drop = drop, timeout = timeout}}, true
}

wake :: proc(data: rawptr) {
	_ = signal.wake((cast(^Notice)data).signal)
}
drop_notice :: proc(data: rawptr) {
	notice := cast(^Notice)data
	signal.release(&notice.signal)
	free(notice, rt.heap_allocator())
}

start :: proc(state: ^State, io: ^server.Deferred_IO) -> pool.Error {
	notice, error := new(Notice, rt.heap_allocator())
	if error != nil || notice == nil {
		return .Allocation_Failed
	}
	retained, ok := signal.retain(io.wake)

	if !ok {
		free(notice, rt.heap_allocator())
		return .Invalid_Config
	}

	notice.signal = retained
	notification := pool.Notification{notice, wake, drop_notice}
	handle, admission := pool.submit_scoped(
		state.lane,
		&state.work,
		&notification,
		server.request_deadline(io.cancellation),
		io.resources,
		state.unmanaged_bytes,
	)

	if admission != .None {
		drop_notice(notice)
		return admission
	}

	state.handle, state.started = handle, true

	return .None
}

poll_result :: proc(data: rawptr, io: ^server.Deferred_IO) -> (server.Response, server.Deferred_Step) {
	state := cast(^State)data

	if !state.started {
		error := start(state, io)

		if error != .None {
			status: server.HTTP_Status = .Service_Unavailable
			if error == .Expired {
				status = .Request_Timeout
			}
			return {status = status}, .Ready
		}
	}

	view, error := pool.poll(state.handle)
	if error != .None {
		return {}, .Failed
	}

	switch view.outcome {
	case .Pending:
		return {}, .Waiting
	case .Succeeded:
		response, ok := state.build(view.data, io.allocator)

		if !ok {
			server.discard_response(&response)
			return {}, .Failed
		}

		return response, .Ready
	case .Expired:
		return {status = .Request_Timeout, close_connection = true}, .Ready
	case .Cancelled:
		return {status = .Service_Unavailable, close_connection = true}, .Ready
	case .Failed:
		return {status = .Internal_Server_Error}, .Ready
	}

	return {}, .Failed
}

drop :: proc(data: rawptr) {
	state := cast(^State)data

	if state.started {
		_ = pool.cancel(state.handle)
		_ = pool.release(&state.handle)
	} else if state.work.drop != nil {
		state.work.drop(state.work.data)
	}

	free(state, rt.heap_allocator())
}
