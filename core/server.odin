package saba_core

import rt "base:runtime"
import http "../../http"
import http1 "../../http/v1"
import "core:log"
import "core:mem"
import charged "core:mem/budget"
import budget "core:sync/budget"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"

import async "shared:async"
import signal "shared:async/signal"

@(private)
CONNECTION_STEP_LIMIT :: 32
@(private)
RESPONSE_WRITE_CHUNK_BYTES :: 64 * mem.Kilobyte

Handler :: #type proc(data:rawptr, conn: ^Connection, request: ^Request) -> Response

@(private)
Connection_Phase :: enum {
	Adopt,
	Headers,
	Idle,
	Body,
	Chunked_Body,
	Dispatch,
	Await_Response,
	Write,
	Produce,
	Upgrade,
}

// One task allocation per admitted connection. State remains stable across
// suspension. Initial header storage is 512 bytes; larger buffers grow on demand.
Connection_Task :: struct {
	resource_connection, resource_operation: budget.Scope,
	resource_binding, resource_transport: charged.Binding,
	resource_emergency: [128]u8,
	task:                               async.Task,
	runtime:                            ^Server_Runtime,
	connection:                         Connection,
	socket:                             async.Socket,
	native_pending:                     bool,
	arena:                              mem.Dynamic_Arena,
	phase, after_write:                 Connection_Phase,
	finish_after_write:                 bool,
	reuse_after_write, idle_registered: bool,
	requests_completed:                int,
	idle_previous, idle_next:          ^Connection_Task,
	deadline:                           async.Deadline,
	header_deadline:                    async.Deadline,
	header_read_deadline:               time.Tick,
	observed, observation_finished, response_finished: bool,
	observed_at:                        time.Tick,
	event:                              Request_Event,
	initial_header:                     [512]u8,
	header:                             []u8,
	header_used, body_used:             int,
	request:                            Request,
	chunked: ^Chunk_Request,
	output:                             [3][]u8,
	streaming: ^Response_Stream_State,
	deferred: Deferred_Response,
	deferred_signal: signal.Signal,
	deferred_expires: time.Tick,
	deferred_deadline: async.Deadline,
	deferred_buffer: []u8,
	deferred_used: int,
	output_index, output_offset:        int,
	upgrade_established:              bool,
	upgrade:                          Upgrade,
	upgrade_prefetched:               []u8,

}

@(private)
handle_connection :: proc(data: rawptr) -> async.Resume_Result {
	task := cast(^Connection_Task)data
	conn := &task.connection
	context.logger = task.runtime.logger
	context.temp_allocator = mem.dynamic_arena_allocator(&task.arena)
	for _ in 0 ..< CONNECTION_STEP_LIMIT {
		if task.runtime.config.keep_alive.enabled && task.phase != .Write && async.cancelled(&task.task) do return .Done
		switch task.phase {
		case .Adopt:
			// adopt consumes the descriptor even on failure. Queued tasks
			// cancelled before this invocation close it in finish_connection.
			task.native_pending = false
			socket, err := async.adopt(&task.runtime.executor, &task.task, conn.socket)
			if err.kind != .None do return .Done
			task.socket = socket
			observe_start(task)
			task.header = task.initial_header[:]
			task.header_deadline = async.deadline_after(&task.runtime.executor, task.runtime.timeouts.header)
			task.header_read_deadline = time.tick_add(time.tick_now(), task.runtime.timeouts.header)
			task.deadline = async.deadline_after(&task.runtime.executor, task.runtime.timeouts.idle)
			conn.read_deadline = time.tick_add(time.tick_now(), task.runtime.timeouts.idle)
			task.phase = .Headers
		case .Idle:
			if server_is_draining(task.runtime) do return .Done
			n, err := async.read(task.socket, task.header, task.deadline)
			if err.kind == .Pending do return .Waiting
			// Idle timeout/EOF has no admitted request and emits no extra event.
			if err.kind != .None || n == 0 do return .Done
			if !keep_alive_begin_request(task,n) do return .Done
			continue
		case .Headers:
			if deadline_expired(conn.read_deadline) {
				if task.observed do task.event.outcome = .Timeout
				if !queue_response(task, {status = .Request_Timeout}) do return .Done
				continue
			}
			if strings.contains(string(task.header[:task.header_used]), HTTP_HEADERS_END) {
				if !prepare_request(task) do return .Done
				continue
			}
			if task.header_used == len(task.header) {
				if len(task.header) == REQUEST_HEADER_LIMIT {
					if !queue_response(task, {status = .Request_Header_Fields_Too_Large}) {
						return .Done
					}
					continue
				}
				grown, allocation_error := make(
					[]u8,
					min(len(task.header) * 2, REQUEST_HEADER_LIMIT),
					context.temp_allocator,
				)
				if allocation_error != nil {
					if resource_pressure(task) {resource_reject(task); continue}
					observe_failure(task, .Allocation_Error); return .Done
				}
				copy(grown, task.header)
				task.header = grown
			}
			n, err := async.read(task.socket, task.header[task.header_used:], task.deadline)
			if err.kind == .Pending do return .Waiting
			if err.kind == .Timeout {
				observe_io_error(task, err)
				if !queue_response(task, {status = .Request_Timeout}) do return .Done
				continue
			}
			if err.kind != .None {
				observe_io_error(task, err)
				return .Done
			}
			if n > 0 {
				if task.observed do task.event.bytes_received += u64(n)
				if task.header_used == 0 {
					task.deadline = task.header_deadline
					conn.read_deadline = task.header_read_deadline
				}
			}
			task.header_used += n
		case .Body:
			if task.body_used == len(task.request.body) {
				if deadline_expired(conn.read_deadline) {
					if task.observed do task.event.outcome = .Timeout
					if !queue_response(task, {status = .Request_Timeout}) do return .Done
				} else {
					conn.read_deadline = {}
					task.phase = .Dispatch
				}
				continue
			}
			n, err := task_read(task, task.request.body[task.body_used:])
			if err.kind == .Pending do return .Waiting
			if err.kind == .Timeout {
				observe_io_error(task, err)
				if !queue_response(task, {status = .Request_Timeout}) do return .Done
				continue
			}
			if err.kind == .Peer_Closed {
				observe_io_error(task, err)
				if !queue_response(task, {status = .Bad_Request}) do return .Done
				continue
			}
			if err.kind != .None {
				observe_io_error(task, err)
				return .Done
			}
			task.body_used += n

		case .Chunked_Body:
			if deadline_expired(conn.read_deadline) {
				if !queue_response(task, {status = .Request_Timeout, close_connection = true}) do return .Done
				continue
			}
			if len(conn.read_buffer) == 0 {
				n, error := async.read(task.socket, task.chunked.input[:], task.deadline)
				if error.kind == .Pending do return .Waiting
				if error.kind != .None {
					observe_io_error(task, error)
					if error.kind == .Timeout || error.kind == .Peer_Closed {
						status: HTTP_Status = .Bad_Request
						if error.kind == .Timeout do status = .Request_Timeout
						if !queue_response(task, {status = status, close_connection = true}) do return .Done
						continue
					}
					return .Done
				}
				if n == 0 {
					if !queue_response(task, {status = .Bad_Request, close_connection = true}) do return .Done
					continue
				}
				conn.read_buffer = task.chunked.input[:n]
			}
			consumed, written, done, error := http1.chunk_decoder_feed(
				&task.chunked.decoder,
				conn.read_buffer,
				task.request.body[task.body_used:],
			)
			conn.read_buffer = conn.read_buffer[consumed:]
			task.body_used += written
			if task.observed do task.event.bytes_received += u64(consumed)
			if error.kind != .None {
				observe_failure(task, .Protocol_Error)
				if !queue_response(task, {status = chunk_error_status(error), close_connection = true}) do return .Done
				continue
			}
			if done {
				if deadline_expired(conn.read_deadline) {
					if !queue_response(task, {status = .Request_Timeout, close_connection = true}) do return .Done
					continue
				}
				task.request.body = task.request.body[:task.body_used]
				task.request.content_length = task.body_used
				conn.read_deadline = {}
				task.phase = .Dispatch
			}
		case .Dispatch:
			response := dispatch_request(task)
			if !queue_response(task, response) do return .Done
		case .Await_Response:
			result := await_response(task)
			if result != .Yield do return result
			continue
		case .Produce:
			result := produce_stream(task)
			if result != .Yield || task.phase == .Produce do return result
			continue
		case .Write:
			if task.output_index == len(task.output) {
				if task.streaming != nil {
					produce, ok := stream_write_complete(task)
					if !ok do return .Done
					if produce {
						task.phase = .Produce
						continue
					}
				}
				if !task.upgrade_established {
					task.response_finished = true
					task.requests_completed += 1
					if task.reuse_after_write {
						if !keep_alive_next_request(task) do return .Done
						continue
					}
				}
				if task.finish_after_write do return .Done
				task.phase = task.after_write
				if task.phase == .Upgrade {
					if !task.upgrade_established && !release_upgrade_request(task) do return .Done
				}
				continue
			}
			data := task.output[task.output_index]
			if task.output_offset == len(data) {
				task.output_index += 1
				task.output_offset = 0
				continue
			}
			chunk := data[task.output_offset:min(
				task.output_offset + RESPONSE_WRITE_CHUNK_BYTES,
				len(data),
			)]
			n, err := async.write(task.socket, chunk, task.deadline)
			if err.kind == .Pending do return .Waiting
			if task.observed && n > 0 do task.event.bytes_sent += u64(n)
			if err.kind != .None {
				observe_io_error(task, err)
				return .Done
			}
			task.output_offset += n
		case .Upgrade:
			if async.cancelled(&task.task) do return .Done
			io := Upgrade_IO{socket=task.socket,runtime=&task.runtime.executor,connection=&task.connection}
			result := task.upgrade.resume(task.upgrade.data,&io)
			upgrade_resume_finished(task)
			if result != .Yield do return result
		}
	}
	return .Yield
}

@(private)
prepare_request :: proc(task: ^Connection_Task) -> bool {
	allocator := mem.dynamic_arena_allocator(&task.arena)
	raw := string(task.header[:task.header_used])
	end := strings.index(raw, HTTP_HEADERS_END)
	if task.observed do task.event.bytes_received = u64(end + len(HTTP_HEADERS_END))
	// Allocate header entries only after a request arrives, rather than
	// retaining the maximum table for every idle connection.
	count := min(strings.count(raw[:end], CRLF), REQUEST_HEADER_COUNT_LIMIT)
	headers, header_error := make([]Header, count, allocator)
	if header_error != nil {
		if resource_pressure(task) do return resource_reject(task)
		observe_failure(task, .Allocation_Error); return false
	}
	request, status := parse_request(raw, headers)
	task.request = request
	task.request.allocator = allocator
	task.request.resources = task.resource_operation
	task.request.backing_allocator = charged.allocator(task.resource_binding)
	task.request.request_id = task.event.request_id
	task.request._observe = task.observed
	if status != .None {
		observe_failure(task, .Protocol_Error)
		return queue_response(task, {status = status})
	}
	task.connection.read_buffer = task.header[end + len(HTTP_HEADERS_END):task.header_used]
	limit := REQUEST_BODY_LIMIT
	if task.runtime.config.request_body_limit != nil {
		limit = task.runtime.config.request_body_limit(&task.request)
	}
	if limit < 0 || request.content_length > limit {
		return queue_response(task, {status = .Content_Too_Large})
	}
	body_capacity := request.content_length
	if request.chunked do body_capacity = min(limit, http.MAX_BODY_SIZE)
	body, body_error := make([]u8, body_capacity, allocator)
	if body_error != nil {
		if resource_pressure(task) do return resource_reject(task)
		observe_failure(task, .Allocation_Error); return false
	}
	task.request.body = body
	duration := body_timeout(task.runtime.timeouts, request.content_length)
	task.deadline = async.deadline_after(&task.runtime.executor, duration)
	task.connection.read_deadline = time.tick_add(time.tick_now(), duration)
	task.phase = .Body
	if request.chunked {
		state, allocation_error := new(Chunk_Request, allocator)
		if allocation_error != nil {
			if resource_pressure(task) do return resource_reject(task)
			observe_failure(task, .Allocation_Error); return false
		}
		if http1.chunk_decoder_init(&state.decoder, u64(body_capacity)).kind != .None do return false
		task.chunked = state; task.phase = .Chunked_Body
	}
	return true
}

@(private)
task_read :: proc(task: ^Connection_Task, destination: []u8) -> (int, async.Error) {
	if deadline_expired(task.connection.read_deadline) do return 0, {kind = .Timeout}
	buffered := task.connection.read_buffer
	if len(buffered) > 0 {
		n := copy(destination, buffered)
		if task.observed && !task.upgrade_established do task.event.bytes_received += u64(n)
		task.connection.read_buffer = buffered[n:]
		if len(task.connection.read_buffer) == 0 && task.upgrade_prefetched != nil {
			delete(task.upgrade_prefetched, connection_storage_allocator(task))
			task.upgrade_prefetched = nil
		}
		return n, {}
	}
	n, err := async.read(task.socket, destination, task.deadline)
	if task.observed && n > 0 && !task.upgrade_established do task.event.bytes_received += u64(n)
	return n, err
}

@(private)
init_connection_arena :: proc(task: ^Connection_Task) {
	allocator := charged.allocator(task.resource_binding)
	if allocator.procedure == nil do allocator = charged.allocator(task.resource_transport)
	if allocator.procedure == nil do allocator = rt.heap_allocator()
	mem.dynamic_arena_init(
		&task.arena,
		block_allocator = allocator,
		array_allocator = allocator,
		block_size = 16 * mem.Kilobyte,
		out_band_size = 8 * mem.Kilobyte,
	)
}

@(private)
release_upgrade_request :: proc(task: ^Connection_Task) -> bool {
	finish_request_context(task)
	observe_finish(task)
	buffered := task.connection.read_buffer
	if len(buffered) > 0 {
		allocator := connection_storage_allocator(task)
		if allocator.procedure == nil do return false
		saved, err := make([]u8, len(buffered), allocator)
		if err != nil do return false
		copy(saved, buffered)
		task.upgrade_prefetched = saved
		task.connection.read_buffer = saved
	} else {
		task.connection.read_buffer = nil
	}
	// Upgraded sessions no longer use HTTP headers, response bytes or request
	// allocations. Preserve only prefetched frame bytes across arena release.
	task.request = {}
	task.header = nil
	task.output = {}
	mem.dynamic_arena_destroy(&task.arena)
	finish_operation_resources(task)
	if connection_storage_allocator(task).procedure == nil do return false
	init_connection_arena(task)
	task.upgrade_established = true
	return true
}

@(private)
queue_response :: proc(task: ^Connection_Task, response: Response) -> bool {
	if resource_pressure(task) {
		discarded := response; discard_response(&discarded)
		return resource_reject(task, resource_failure_status(response.status))
	}
	if deferred_present(response.deferred) {
		if queue_deferred(task, response) do return true
		if resource_pressure(task) {drop_deferred(task); return resource_reject(task)}
		return false
	}
	prepared := response
	task.upgrade = response.upgrade
	if stream_present(response.stream) do return queue_stream_response(task, response)
	if !resource_copy_response(task, &prepared) {
		drop_upgrade(task)
		if resource_pressure(task) {
			return resource_reject(task, resource_failure_status(response.status))
		}
		observe_failure(task, .Allocation_Error); return false
	}
	if (task.upgrade.resume != nil || task.upgrade.drop != nil || task.upgrade.data != nil) &&
		(prepared.status != .Switching_Protocols || task.upgrade.resume == nil) {
		drop_upgrade(task)
		observe_failure(task,.Protocol_Error)
		return false
	}
	buffer, allocation_error := make(
		[]u8,
		RESPONSE_HEADER_LIMIT,
		mem.dynamic_arena_allocator(&task.arena),
	)
	if allocation_error != nil {
		if resource_pressure(task) {
			drop_upgrade(task); return resource_reject(task, resource_failure_status(prepared.status))
		}
		observe_failure(task, .Allocation_Error); return false
	}
	task.reuse_after_write = !prepared.close_connection && response_can_reuse(task,prepared.status)
	headers, ok := response_headers(prepared, buffer,task.reuse_after_write)
	if !ok {observe_failure(task, .Protocol_Error); return false}
	task.output = {headers, prepared.body, nil}
	if task.request.method == "HEAD" do task.output[1] = nil
	task.output_index, task.output_offset = 0, 0
	task.deadline = async.deadline_after(&task.runtime.executor, task.runtime.timeouts.response)
	task.connection.write_deadline = time.tick_add(time.tick_now(), task.runtime.timeouts.response)
	if task.observed {
		task.event.status = prepared.status
		if task.event.status == .None do task.event.status = .OK
		if task.event.status == .Request_Timeout do task.event.outcome = .Timeout
		if task.event.status == .Request_Header_Fields_Too_Large do task.event.outcome = .Protocol_Error
	}
	task.finish_after_write = task.upgrade.resume == nil
	if !task.finish_after_write do task.after_write = .Upgrade
	task.phase = .Write
	return true
}

@(private)
dispatch_request :: proc(task: ^Connection_Task) -> Response {
	if !begin_request_context(task) do return Response{status=.Internal_Server_Error,close_connection=true}
    response:=task.runtime.config.handler(task.runtime.config.handler_data,&task.connection,&task.request)
    status:=request_context_status(task.request.cancellation)
    if status==.Active do return response
    discard_response(&response)
    observe_failure(task,.Timeout if status==.Deadline else .Cancelled)
    return Response{status=.Request_Timeout if status==.Deadline else .Service_Unavailable,close_connection=true}
}

@(private)
finish_connection :: proc(data: rawptr) {
	task := cast(^Connection_Task)data
	keep_alive_leave_idle(task)
	if budget.same_scope(task.resource_connection, task.resource_connection) {
		_ = budget.close(task.resource_connection)
	}
	drop_deferred(task)
	finish_request_context(task)
	observe_finish(task)
	drop_response_stream(task)
	drop_upgrade(task)
	if task.native_pending do net.close(task.connection.socket)
	// The runtime has already closed adopted sockets and removed readiness.
	if task.upgrade_prefetched != nil {
		delete(task.upgrade_prefetched, connection_storage_allocator(task))
	}
	mem.dynamic_arena_destroy(&task.arena)
	finish_operation_resources(task)
	charged.release(&task.resource_transport)
	budget.release_scope(&task.resource_connection)
	sync.atomic_sub(&task.runtime.active_connections, 1)
	drain_connection_finished(task.runtime)
	free(task)
}

send_bytes :: proc(conn: ^Connection, data: []u8, operation: string) -> bool {
	sent, err := write_connection(conn, data)
	if err != nil {
		log.error(
			"Failed to send",
			operation,
			"| error:",
			err,
			"| socket:",
			conn.socket,
			"| bytes sent:",
			sent,
			"| expected:",
			len(data),
		)
		return false
	}
	return true
}
