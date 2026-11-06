package server

import rt "base:runtime"
import "core:log"
import "core:mem"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"

import async "shared:async"

REQUEST_HEADER_TIMEOUT :: 5 * time.Second
RESPONSE_SEND_TIMEOUT :: 5 * time.Second

@(private)
CONNECTION_STEP_LIMIT :: 32
@(private)
RESPONSE_WRITE_CHUNK_BYTES :: 64 * mem.Kilobyte

Handler :: #type proc(conn: ^Connection, request: ^Request) -> Response

@(private)
Connection_Phase :: enum {
	Adopt,
	Headers,
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
	deadline:                           async.Deadline,
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
		switch task.phase {
		case .Adopt:
			// adopt consumes the descriptor even on failure. Queued tasks
			// cancelled before this invocation close it in finish_connection.
			task.native_pending = false
			socket, err := async.adopt(&task.runtime.executor, &task.task, conn.socket)
			if err.kind != .None do return .Done
			task.socket = socket
			task.header = task.initial_header[:]
			task.deadline = async.deadline_after(&task.runtime.executor, REQUEST_HEADER_TIMEOUT)
			conn.read_deadline = time.tick_add(time.tick_now(), REQUEST_HEADER_TIMEOUT)
			task.phase = .Headers
		case .Headers:
			if deadline_expired(conn.read_deadline) {
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
				if allocation_error != nil do return .Done
				copy(grown, task.header)
				task.header = grown
			}
			n, err := async.read(task.socket, task.header[task.header_used:], task.deadline)
			if err.kind == .Pending do return .Waiting
			if err.kind == .Timeout {
				if !queue_response(task, {status = .Request_Timeout}) do return .Done
				continue
			}
			if err.kind != .None do return .Done
			task.header_used += n
		case .Body:
			if task.body_used == len(task.request.body) {
				if deadline_expired(conn.read_deadline) {
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
				if !queue_response(task, {status = .Request_Timeout}) do return .Done
				continue
			}
			if err.kind == .Peer_Closed {
				if !queue_response(task, {status = .Bad_Request}) do return .Done
				continue
			}
			if err.kind != .None do return .Done
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
			if err.kind != .None do return .Done
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
	// Allocate header entries only after a request arrives, rather than
	// retaining the maximum table for every idle connection.
	count := min(strings.count(raw[:end], CRLF), REQUEST_HEADER_COUNT_LIMIT)
	headers, header_error := make([]Header, count, allocator)
	if header_error != nil do return false
	request, status := parse_request(raw, headers)
	task.request = request
	task.request.allocator = allocator
	if status != .None do return queue_response(task, {status = status})
	task.connection.read_buffer = task.header[end + len(HTTP_HEADERS_END):task.header_used]
	limit := REQUEST_BODY_LIMIT
	if task.runtime.config.request_body_limit != nil {
		limit = task.runtime.config.request_body_limit(&task.request)
	}
	if limit < 0 || request.content_length > limit {
		return queue_response(task, {status = .Content_Too_Large})
	}
	body, body_error := make([]u8, request.content_length, allocator)
	if body_error != nil do return false
	task.request.body = body
	duration := REQUEST_BODY_TIMEOUT
	if request.content_length > REQUEST_BODY_LIMIT do duration = 30 * time.Second
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
		task.connection.read_buffer = buffered[n:]
		if len(task.connection.read_buffer) == 0 && task.websocket_prefetched != nil {
			delete(task.websocket_prefetched, rt.heap_allocator())
			task.websocket_prefetched = nil
		}
		return n, {}
	}
	return async.read(task.socket, destination, task.deadline)
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
	if allocation_error != nil do return false
	headers, ok := response_headers(prepared, buffer)
	if !ok do return false
	task.output = {headers, prepared.body}
	if task.request.method == "HEAD" do task.output[1] = nil
	task.output_index, task.output_offset = 0, 0
	task.deadline = async.deadline_after(&task.runtime.executor, RESPONSE_SEND_TIMEOUT)
	task.connection.write_deadline = time.tick_add(time.tick_now(), RESPONSE_SEND_TIMEOUT)
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
	if task.native_pending do net.close(task.connection.socket)
	// The runtime has already closed adopted sockets and removed readiness.
	delete(task.websocket_prefetched, rt.heap_allocator())
	mem.dynamic_arena_destroy(&task.arena)
	sync.atomic_sub(&task.runtime.active_connections, 1)
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
