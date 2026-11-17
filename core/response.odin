package saba_core

import http "../../http"
import http1 "../../http/v1"
import "core:log"
import "core:time"
import exchange "../../http/exchange"
import rt "base:runtime"
import "core:mem"
import budget "core:sync/budget"
import owned "core:mem/owned"
import "core:strconv"
import async "shared:async"

RESPONSE_HEADER_LIMIT :: 8192

// Header values and body must survive until the server finishes sending.
// Use request.allocator for dynamic response data.
Response :: struct {
	trailers:         []Header,
	status:           HTTP_Status,
	headers:          []Header,
	body:             []u8,
	// Force close even when bounded keep-alive is enabled.
	close_connection: bool,
	// Owned optional HTTP/1 upgrade continuation, transferred on handler return.
	upgrade:          Upgrade,
	stream:           Response_Stream,
	deferred:         Deferred_Response,
}

// Copies the header list out of the caller's stack into the request arena.
// Header strings and body remain borrowed: use literals or request allocations.
make_response :: proc(
	request: ^Request,
	status: HTTP_Status = .OK,
	headers: []Header = nil,
	body: []u8 = nil,
) -> Response {
	if len(headers) == 0 {
		return Response{status = status, body = body}
	}

	stored_headers, err := make([]Header, len(headers), request.allocator)
	if err != nil {
		log.error("Could not allocate response headers:", err)

		return Response{status = .Internal_Server_Error}
	}

	copy(stored_headers, headers)

	return Response{status = status, headers = stored_headers, body = body}
}

response_headers :: proc(response: Response, buffer: []u8, keep_alive: bool = false) -> (data: []u8, ok: bool) {
	if len(response.trailers) > 0 {
		return nil, false
	}

	if stream_present(response.stream) || deferred_present(response.deferred) {
		return nil, false
	}
	status := response.status
	if status == .None {
		status = .OK
	}

	text := status_text(status)

	if text == "" {
		log.error("Invalid HTTP response status:", i32(status))

		return
	}

	body_forbidden := !http.response_body_allowed(int(status))

	if body_forbidden && len(response.body) != 0 {
		log.error("HTTP response status does not allow a body:", status)

		return
	}

	profile: http1.Response_Profile = .Close

	if status == .Switching_Protocols {
		profile = .Upgrade
	} else if keep_alive {
		profile = .Keep_Alive
	}

	written, error := http1.response_head_encode_profile(
		buffer,
		{status = int(status), headers = response.headers, content_length = i64(len(response.body))},
		profile,
		max_bytes = RESPONSE_HEADER_LIMIT,
	)

	if error.kind != .None {
		log.error("Invalid HTTP response headers:", error.kind)
		return
	}

	return buffer[:written], true
}

send_response :: proc(conn: ^Connection, response: Response, request_method: string = "") -> bool {
	prepared := response

	if stream_present(prepared.stream) || deferred_present(prepared.deferred) {
		discard_response(&prepared)
		return false
	}

	buffer: [RESPONSE_HEADER_LIMIT]u8
	headers, ok := response_headers(prepared, buffer[:])
	if !ok {
		return false
	}

	duration := conn._timeouts.response
	if duration == 0 {
		duration = RESPONSE_SEND_TIMEOUT
	}
	conn.write_deadline = time.tick_add(time.tick_now(), duration)

	if !send_bytes(conn, headers, "HTTP response headers") {
		return false
	}

	if request_method == "HEAD" {
		return true
	}

	return send_bytes(conn, prepared.body, "HTTP response body")
}

send_empty_response :: proc(conn: ^Connection, status: HTTP_Status) -> bool {
	return send_response(conn, Response{status = status})
}

// Disposes transferred continuations when a late response cannot be queued.
// Body/header borrows remain owned by their request arena.
discard_response :: proc(response: ^Response) {
	if response == nil {
		return
	}
	old := response^
	response^ = {}
	if old.deferred.drop != nil {
		old.deferred.drop(old.deferred.data)
	}
	if old.upgrade.drop != nil {
		old.upgrade.drop(old.upgrade.data)
	}
	if old.stream.drop != nil {
		old.stream.drop(old.stream.data)
	}
}

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
	resources:            budget.Scope,
	backing_allocator:    mem.Allocator,
	runtime:              ^async.Runtime,
	cancellation:         Request_Context,
	max_chunk_bytes:      int,
	_exchange:            ^exchange.Exchange,
	_deadline:            async.Deadline,
	_submitted, _waiting: bool,
}

Stream_Backing :: exchange.Backing

// Exact legacy procedure type remains usable in callback tables.
stream_submit :: proc(io: ^Stream_IO, chunk: ^owned.Chunk) -> exchange.Submit_Result {
	return stream_submit_backing(io, chunk)
}

stream_submit_backing :: proc(
	io: ^Stream_IO,
	chunk: ^owned.Chunk,
	backing: Stream_Backing = {},
) -> exchange.Submit_Result {
	if io == nil || io._exchange == nil || chunk == nil || len(chunk.data) == 0 {
		return .Invalid
	}
	if io._submitted || io._waiting {
		return .Backpressure
	}
	result := exchange.submit_backing(io._exchange, chunk, backing)
	if result == .Accepted {
		io._submitted = true
	}
	return result
}

stream_wait :: proc(io: ^Stream_IO, deadline: async.Deadline) -> async.Error {
	if io == nil || io.runtime == nil || io._submitted || io._waiting || deadline.epoch != io._deadline.epoch {
		return {kind = .Invalid_Config}
	}
	bounded := deadline
	bounded.at = min(bounded.at, io._deadline.at)
	error := async.sleep_until(io.runtime, bounded)
	if error.kind == .Pending {
		io._waiting = true
	}

	return error
}

streaming_response :: proc(response: Response) -> bool {
	return stream_present(response.stream)
}
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

Response_Stream_State :: struct {
	allocator:                  mem.Allocator,
	producer:                   Response_Stream,
	exchange:                   exchange.Exchange,
	expires:                    time.Tick,
	deadline:                   async.Deadline,
	prefix:                     [32]u8,
	chunked, pending, terminal: bool,
	max_chunk_bytes:            int,
}

drop_response_stream :: proc(task: ^Connection_Task) {
	old := task.streaming
	task.streaming = nil
	if old == nil {
		return
	}
	exchange.destroy(&old.exchange)
	producer := old.producer
	old.producer = {}
	if producer.drop != nil {
		producer.drop(producer.data)
	}
	free(old, old.allocator)
}

stream_write_budget :: proc(task: ^Connection_Task) -> bool {
	state := task.streaming
	remaining := time.tick_diff(time.tick_now(), state.expires)

	if remaining <= 0 {
		observe_failure(task, .Timeout)
		cancel_request_context(task.request.cancellation, .Deadline)
		return false
	}

	arm_write_deadline(task, min(remaining, task.runtime.timeouts.response))
	task.output_index = 0
	task.output_offset = 0
	task.phase = .Write

	return true
}

queue_stream_response :: proc(task: ^Connection_Task, response: Response) -> bool {
	producer := response.stream
	if producer.next == nil ||
	   len(response.body) != 0 ||
	   task.upgrade.data != nil ||
	   task.upgrade.resume != nil ||
	   task.upgrade.drop != nil {
		if producer.drop != nil {
			producer.drop(producer.data)
		}
		observe_failure(task, .Protocol_Error)
		return false
	}

	allocator := task.request.backing_allocator
	if allocator.procedure == nil {
		allocator = rt.heap_allocator()
	}
	state, error := new(Response_Stream_State, allocator)

	if error != nil || state == nil {
		if producer.drop != nil {
			producer.drop(producer.data)
		}
		if resource_pressure(task) {
			return resource_reject(task)
		}
		observe_failure(task, .Allocation_Error)
		return false
	}

	state.producer, state.allocator = producer, allocator
	task.streaming = state
	limit := producer.max_chunk_bytes
	if limit == 0 {
		limit = 64 * mem.Kilobyte
	}
	duration := producer.timeout
	if duration == 0 {
		duration = task.runtime.timeouts.response
	}

	if limit < 1 || limit > mem.Megabyte || duration <= 0 || duration > MAX_SERVER_TIMEOUT {
		observe_failure(task, .Protocol_Error)
		return false
	}

	state.max_chunk_bytes = limit
	state.expires = time.tick_add(time.tick_now(), duration)
	inherited := request_deadline(task.request.cancellation)
	if inherited != (time.Tick{}) && time.tick_diff(inherited, state.expires) > 0 {
		state.expires = inherited
	}
	remaining := time.tick_diff(time.tick_now(), state.expires)

	if remaining <= 0 {
		observe_failure(task, .Timeout)
		return false
	}

	state.deadline = async.deadline_after(&task.runtime.executor, remaining)
	method: http.Method = .GET
	if task.request.method == "HEAD" {
		method = .HEAD
	}
	if initialized := exchange.init(
		&state.exchange,
		method,
		{
			chunk_capacity = 1,
			max_retained_bytes = limit,
			max_body_bytes = producer.max_body_bytes,
			scope = task.resource_operation,
		},
		allocator,
	); initialized.kind != .None {
		if initialized.kind == .Budget_Rejected || resource_pressure(task) {
			drop_response_stream(task)
			return resource_reject(task)
		}

		observe_failure(task, .Protocol_Error)
		return false
	}

	status := response.status
	if status == .None {
		status = .OK
	}
	head := http.Response_Head {
		status         = int(status),
		headers        = response.headers,
		content_length = producer.content_length,
	}

	if exchange.respond(&state.exchange, head).kind != .None {
		if resource_pressure(task) {
			drop_response_stream(task)
			return resource_reject(task)
		}

		observe_failure(task, .Protocol_Error)
		return false
	}

	stored, _ := exchange.head(&state.exchange)
	buffer, ae := make([]u8, RESPONSE_HEADER_LIMIT, mem.dynamic_arena_allocator(&task.arena))

	if ae != nil {
		if resource_pressure(task) {
			drop_response_stream(task)
			return resource_reject(task)
		}

		observe_failure(task, .Allocation_Error)
		return false
	}

	task.reuse_after_write = !response.close_connection && response_can_reuse(task, status)
	profile: http1.Response_Profile = .Close
	if task.reuse_after_write {
		profile = .Keep_Alive
	}
	n, e := http1.response_stream_head_encode(buffer, stored, profile, method, max_bytes = RESPONSE_HEADER_LIMIT)

	if e.kind != .None {
		observe_failure(task, .Protocol_Error)
		return false
	}

	state.chunked = producer.content_length < 0

	if !http.response_body_allowed(int(status), task.request.method) {
		if exchange.finish(&state.exchange).kind != .None {
			return false
		}
		state.terminal = true
	}

	task.output = {buffer[:n], nil, nil}
	task.finish_after_write = true
	if task.observed {
		task.event.status = status
	}

	return stream_write_budget(task)
}

// Records the outcome when the stream budget or its request context has ended.
stream_interrupted :: proc(task: ^Connection_Task) -> bool {
	if deadline_expired(task.streaming.expires) {
		observe_failure(task, .Timeout)
		cancel_request_context(task.request.cancellation, .Deadline)
		return true
	}

	if request_cancelled(task.request.cancellation) {
		status := request_context_status(task.request.cancellation)
		observe_failure(task, .Timeout if status == .Deadline else .Cancelled)
		return true
	}

	return false
}

produce_stream :: proc(task: ^Connection_Task) -> async.Resume_Result {
	state := task.streaming
	if stream_interrupted(task) {
		return .Done
	}
	io := Stream_IO {
		resources         = task.resource_operation,
		backing_allocator = task.request.backing_allocator,
		runtime           = &task.runtime.executor,
		cancellation      = task.request.cancellation,
		max_chunk_bytes   = state.max_chunk_bytes,
		_exchange         = &state.exchange,
		_deadline         = state.deadline,
	}

	step := state.producer.next(state.producer.data, &io)
	if stream_interrupted(task) {
		return .Done
	}

	switch step {
	case .Waiting:
		if !io._waiting || io._submitted {
			observe_failure(task, .Protocol_Error)
			return .Done
		}

		return .Waiting
	case .Yield:
		if io._waiting || io._submitted {
			observe_failure(task, .Protocol_Error)
			return .Done
		}

		return .Yield
	case .Chunk:
		if !io._submitted || io._waiting {
			observe_failure(task, .Protocol_Error)
			return .Done
		}

		payload, ok := exchange.body(&state.exchange)

		if !ok {
			observe_failure(task, .Protocol_Error)
			return .Done
		}

		state.pending = true

		if state.chunked {
			size := strconv.write_uint(state.prefix[:], u64(len(payload)), 16)
			n := len(size)
			copy(state.prefix[n:], "\r\n")
			task.output = {state.prefix[:n + 2], payload, transmute([]u8)string("\r\n")}
		} else {
			task.output = {nil, payload, nil}
		}

		if !stream_write_budget(task) {
			return .Done
		}

		return .Yield
	case .Done:
		if io._submitted || io._waiting || exchange.finish(&state.exchange).kind != .None {
			observe_failure(task, .Protocol_Error)
			return .Done
		}

		state.terminal = true
		task.output = {}
		if state.chunked {
			task.output[0] = transmute([]u8)string("0\r\n\r\n")
		}

		if !stream_write_budget(task) {
			return .Done
		}

		return .Yield
	case .Failed:
		observe_failure(task, .IO_Error)
		return .Done
	}

	return .Done
}

// Called only after every output slice has finished its final socket use.
stream_write_complete :: proc(task: ^Connection_Task) -> (produce, ok: bool) {
	state := task.streaming

	if state.pending {
		state.pending = false

		if !exchange.release_body(&state.exchange) {
			observe_failure(task, .Protocol_Error)
			return false, false
		}
	}

	if !state.terminal {
		return true, true
	}

	if exchange.complete(&state.exchange).kind != .None {
		observe_failure(task, .Protocol_Error)
		return false, false
	}

	drop_response_stream(task)

	return false, true
}

// Returning an upgrade transfers data to the server even if the101 write fails.
// Resume runs serially on the existing connection task. It must not retain IO,
// adopt/close the native socket, block, or perform concurrent socket operations.
// Resume may migrate between worker threads. IO and prefetched slices are
// borrowed only during that call. Data must outlive the HTTP request arena.
// A provided drop runs exactly once outside internal locks after IO quiesces.
// With nil drop, the caller owns data and keeps it alive until serve returns.
Upgrade :: struct {
	data:   rawptr,
	resume: proc(data: rawptr, io: ^Upgrade_IO) -> async.Resume_Result,
	drop:   proc(data: rawptr),
}

Upgrade_IO :: struct {
	socket:       async.Socket,
	runtime:      ^async.Runtime,
	connection:   ^Connection,
	// A multiplexed stream uses these callbacks instead of a native socket.
	stream_data:  rawptr,
	stream_read:  proc(data: rawptr, dst: []u8, deadline: async.Deadline) -> (int, async.Error),
	stream_write: proc(data: rawptr, src: []u8, deadline: async.Deadline) -> (int, async.Error),
	stream_wait:  proc(data: rawptr, read, write: bool, deadline: async.Deadline) -> async.Error,
}

// Consume borrowed prefetched bytes only within this resume. The adapter sets
// connection.read_deadline along with its async deadline when changing budgets.
upgrade_read :: proc(io: ^Upgrade_IO, dst: []u8, deadline: async.Deadline) -> (int, async.Error) {
	if io.stream_read != nil {
		return io.stream_read(io.stream_data, dst, deadline)
	}

	if deadline_expired(io.connection.read_deadline) {
		return 0, {kind = .Timeout}
	}

	if len(io.connection.read_buffer) > 0 {
		n := copy(dst, io.connection.read_buffer)
		io.connection.read_buffer = io.connection.read_buffer[n:]
		return n, {}
	}

	if io.connection._task == nil {
		if io.connection._secure {
			return 0, {kind = .Unsupported}
		}
		return async.read(io.socket, dst, deadline)
	}

	return transport_read(io.connection._task, dst, deadline)
}

drop_upgrade :: proc(task: ^Connection_Task) {
	owned := task.upgrade
	task.upgrade = {}
	if owned.drop != nil {
		owned.drop(owned.data)
	}
}

// Callback borrows remain valid until resume returns, even after consumption.
upgrade_resume_finished :: proc(task: ^Connection_Task) {
	if len(task.connection.read_buffer) == 0 && task.upgrade_prefetched != nil {
		delete(task.upgrade_prefetched, connection_storage_allocator(task))
		task.upgrade_prefetched = nil
		task.connection.read_buffer = nil
	}
}

// Buffer must remain unchanged through the Pending result and terminal return.
upgrade_write :: proc(io: ^Upgrade_IO, src: []u8, deadline: async.Deadline) -> (int, async.Error) {
	if io.stream_write != nil {
		return io.stream_write(io.stream_data, src, deadline)
	}

	if io.connection._task == nil {
		if io.connection._secure {
			return 0, {kind = .Unsupported}
		}
		return async.write(io.socket, src, deadline)
	}

	return transport_write(io.connection._task, src, deadline)
}
