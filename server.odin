package server

import rt "base:runtime"
import "core:log"
import "core:mem"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"

import async "shared:async"

@(private)
CONNECTION_STEP_LIMIT :: 32
@(private)
RESPONSE_WRITE_CHUNK_BYTES :: 64 * mem.Kilobyte

Handler :: #type proc(conn: ^Connection, request: ^Request) -> Response

@(private)
Connection_Phase :: enum {
	Adopt,
	Headers,
	Idle,
	Body,
	Dispatch,
	Write,
	WebSocket_Header,
	WebSocket_Frame,
}

// One task allocation per admitted connection. State remains stable across
// suspension. Initial header storage is 512 bytes; larger buffers grow on demand.
Connection_Task :: struct {
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
	output:                             [2][]u8,
	output_index, output_offset:        int,
	websocket_established:              bool,
	websocket_prefetched:               []u8,
	websocket_version:                  u64,
	websocket_input:                    [131]u8,
	websocket_used, websocket_expected: int,
	websocket_output:                   [256]u8,
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
				if allocation_error != nil {observe_failure(task, .Allocation_Error); return .Done}
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
		case .Dispatch:
			if conn.reload != nil && match_route(&task.request, "GET", "/__reload") {
				accept := make([]u8, 28, context.temp_allocator)
				value, status := websocket_accept(&task.request, accept)
				if status != .None {
					if !queue_response(task, {status = status}) do return .Done
					continue
				}
				response := make_response(
					&task.request,
					.Switching_Protocols,
					[]Header{{"Upgrade", "websocket"}, {"Sec-WebSocket-Accept", value}},
				)
				if !queue_response(task, response) do return .Done
				task.finish_after_write = false
				task.after_write = .WebSocket_Header
				task.websocket_version = sync.atomic_load(&conn.reload.version)
				continue
			}
			response := dispatch_request(task)
			if !queue_response(task, response) do return .Done
		case .Write:
			if task.output_index == len(task.output) {
				if !task.websocket_established {
					task.response_finished = true
					task.requests_completed += 1
					if task.reuse_after_write {
						if !keep_alive_next_request(task) do return .Done
						continue
					}
				}
				if task.finish_after_write do return .Done
				task.phase = task.after_write
				if task.phase == .WebSocket_Header {
					if !task.websocket_established && !release_upgrade_request(task) do return .Done
					reset_websocket_read(task)
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
		case .WebSocket_Header, .WebSocket_Frame:
			result := resume_reload_websocket(task)
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
	if header_error != nil {observe_failure(task, .Allocation_Error); return false}
	request, status := parse_request(raw, headers)
	task.request = request
	task.request.allocator = allocator
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
	body, body_error := make([]u8, request.content_length, allocator)
	if body_error != nil {observe_failure(task, .Allocation_Error); return false}
	task.request.body = body
	duration := body_timeout(task.runtime.timeouts, request.content_length)
	task.deadline = async.deadline_after(&task.runtime.executor, duration)
	task.connection.read_deadline = time.tick_add(time.tick_now(), duration)
	task.phase = .Body
	return true
}

@(private)
task_read :: proc(task: ^Connection_Task, destination: []u8) -> (int, async.Error) {
	if deadline_expired(task.connection.read_deadline) do return 0, {kind = .Timeout}
	buffered := task.connection.read_buffer
	if len(buffered) > 0 {
		n := copy(destination, buffered)
		if task.observed && !task.websocket_established do task.event.bytes_received += u64(n)
		task.connection.read_buffer = buffered[n:]
		if len(task.connection.read_buffer) == 0 && task.websocket_prefetched != nil {
			delete(task.websocket_prefetched, rt.heap_allocator())
			task.websocket_prefetched = nil
		}
		return n, {}
	}
	n, err := async.read(task.socket, destination, task.deadline)
	if task.observed && n > 0 && !task.websocket_established do task.event.bytes_received += u64(n)
	return n, err
}

@(private)
init_connection_arena :: proc(task: ^Connection_Task) {
	mem.dynamic_arena_init(
		&task.arena,
		block_allocator = rt.heap_allocator(),
		array_allocator = rt.heap_allocator(),
		block_size = 16 * mem.Kilobyte,
		out_band_size = 8 * mem.Kilobyte,
	)
}

@(private)
release_upgrade_request :: proc(task: ^Connection_Task) -> bool {
	observe_finish(task)
	buffered := task.connection.read_buffer
	if len(buffered) > 0 {
		saved, err := make([]u8, len(buffered), rt.heap_allocator())
		if err != nil do return false
		copy(saved, buffered)
		task.websocket_prefetched = saved
		task.connection.read_buffer = saved
	} else {
		task.connection.read_buffer = nil
	}
	// Reload frames no longer use HTTP headers, response bytes or request
	// allocations. Preserve only prefetched frame bytes across arena release.
	task.request = {}
	task.header = nil
	task.output = {}
	mem.dynamic_arena_destroy(&task.arena)
	init_connection_arena(task)
	task.websocket_established = true
	return true
}

@(private)
queue_response :: proc(task: ^Connection_Task, response: Response) -> bool {
	prepared := response
	if task.connection.reload != nil && reload_html_response(response) {
		injected, ok := inject_reload_client(
			response.body,
			mem.dynamic_arena_allocator(&task.arena),
		)
		if !ok {
			prepared = {
				status = .Internal_Server_Error,
				close_connection = response.close_connection,
			}
		} else if injected != nil {
			prepared.body = injected
		}
	}
	buffer, allocation_error := make(
		[]u8,
		RESPONSE_HEADER_LIMIT,
		mem.dynamic_arena_allocator(&task.arena),
	)
	if allocation_error != nil {observe_failure(task, .Allocation_Error); return false}
	task.reuse_after_write = !prepared.close_connection && response_can_reuse(task,prepared.status)
	headers, ok := response_headers(prepared, buffer,task.reuse_after_write)
	if !ok {observe_failure(task, .Protocol_Error); return false}
	task.output = {headers, prepared.body}
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
	task.finish_after_write = true
	task.phase = .Write
	return true
}

@(private)
dispatch_request :: proc(task: ^Connection_Task) -> Response {
	runtime := task.runtime
	request := &task.request
	if task.connection.reload != nil &&
	   match_route(request, "GET", "/__reload/client.js") {
		return reload_client_response(request)
	}
	if match_route(request, "GET", JSX_RUNTIME_URL) do return jsx_runtime_response(request)
	if match_route(request, "GET", PAGE_ENTRY_URL) do return page_entry_response(request)
	if response, matched := serve_assets(
		request,
		runtime.assets,
		runtime.config.development,
	); matched {
		return response
	}
	if response, matched := serve_prepared_modules(
		request,
		runtime.modules,
		runtime.config.development,
	); matched {
		return response
	}
	if response, matched := serve_prepared_pages(
		request,
		runtime.pages,
		runtime.config.development,
	); matched {
		return response
	}
	return runtime.config.handler(&task.connection, request)
}

@(private)
finish_connection :: proc(data: rawptr) {
	task := cast(^Connection_Task)data
	keep_alive_leave_idle(task)
	observe_finish(task)
	if task.native_pending do net.close(task.connection.socket)
	// The runtime has already closed adopted sockets and removed readiness.
	delete(task.websocket_prefetched, rt.heap_allocator())
	mem.dynamic_arena_destroy(&task.arena)
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
