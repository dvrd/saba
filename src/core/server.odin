package saba_core

import rt "base:runtime"
import http "shared:http"
import http1 "shared:http/v1"
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

CONNECTION_STEP_LIMIT :: 32
RESPONSE_WRITE_CHUNK_BYTES :: 64 * mem.Kilobyte

Handler :: #type proc(data: rawptr, conn: ^Connection, request: ^Request) -> Response

Connection_Phase :: enum {
	Adopt,
	Handshake,
	Headers,
	Idle,
	Body,
	Chunked_Body,
	Dispatch,
	Await_Response,
	Write,
	Produce,
	Upgrade,
	// Negotiated ALPN is exactly "h2". HTTP/1 phases are not used.
	HTTP2,
}

// One task allocation per admitted connection. State remains stable across
// suspension. Initial header storage is 512 bytes; larger buffers grow on demand.
// The fixed HTTP/1 buffers live beside the task of a TCP connection instead of
// inside it, so the Connection_Task embedded in every HTTP/2 stream does not
// reserve them. `task` must stay the first field.
Connection_Storage :: struct {
	task:               Connection_Task,
	initial_header:     [512]u8,
	resource_emergency: [128]u8,
}

connection_storage_new :: proc() -> (^Connection_Task, mem.Allocator_Error) {
	storage, error := new(Connection_Storage)

	if error != nil {
		return nil, error
	}

	storage.task.initial_header = storage.initial_header[:]
	storage.task.resource_emergency = storage.resource_emergency[:]

	return &storage.task, nil
}

connection_storage_free :: proc(task: ^Connection_Task) {
	free(cast(^Connection_Storage)task)
}

Connection_Task :: struct {
	resource_connection, resource_operation:           budget.Scope,
	resource_binding, resource_transport:              charged.Binding,
	// HTTP/1 only; nil for HTTP/2 streams (see Connection_Storage).
	resource_emergency:                                []u8,
	task:                                              async.Task,
	runtime:                                           ^Server_Runtime,
	connection:                                        Connection,
	tls_state:                                         ^TLS_State,
	http2:                                             ^HTTP2_Session,
	http2_request:                                     ^H2_Request,
	socket:                                            async.Socket,
	native_pending:                                    bool,
	arena:                                             mem.Dynamic_Arena,
	phase, after_write:                                Connection_Phase,
	finish_after_write:                                bool,
	reuse_after_write, idle_registered:                bool,
	requests_completed:                                int,
	idle_previous, idle_next:                          ^Connection_Task,
	deadline:                                          async.Deadline,
	header_deadline:                                   async.Deadline,
	header_read_deadline:                              time.Tick,
	observed, observation_finished, response_finished: bool,
	observed_at:                                       time.Tick,
	event:                                             Request_Event,
	initial_header:                                    []u8,
	header:                                            []u8,
	header_used, body_used:                            int,
	request:                                           Request,
	chunked:                                           ^Chunk_Request,
	output:                                            [3][]u8,
	streaming:                                         ^Response_Stream_State,
	deferred:                                          Deferred_Response,
	deferred_signal:                                   signal.Signal,
	deferred_expires:                                  time.Tick,
	deferred_deadline:                                 async.Deadline,
	deferred_buffer:                                   []u8,
	deferred_used:                                     int,
	output_index, output_offset:                       int,
	upgrade_established:                               bool,
	upgrade:                                           Upgrade,
	upgrade_prefetched:                                []u8,
}

handle_http :: proc(data: rawptr) -> async.Resume_Result {
	task := cast(^Connection_Task)data
	conn := &task.connection
	context.logger = task.runtime.logger
	context.temp_allocator = mem.dynamic_arena_allocator(&task.arena)

	for _ in 0 ..< CONNECTION_STEP_LIMIT {
		if task.runtime.config.keep_alive.enabled && task.phase != .Write && async.cancelled(&task.task) {
			return .Done
		}

		switch task.phase {
		case .Adopt:
			// adopt consumes the descriptor even on failure. Queued tasks
			// cancelled before this invocation close it in finish_connection.
			task.native_pending = false
			socket, err := async.adopt(&task.runtime.executor, &task.task, conn.socket)
			if err.kind != .None {
				return .Done
			}
			task.socket = socket
			conn._task = task
			observe_start(task)

			if task.runtime.config.tls != nil {
				conn._secure = true
				task.phase = .Handshake
				if !tls_begin(task) {
					return .Done
				}
				return .Yield
			}

			begin_http_headers(task)
		case .Handshake:
			return .Waiting
		case .Idle:
			if server_is_draining(task.runtime) {
				return .Done
			}
			n, err := transport_read(task, task.header, task.deadline)
			if err.kind == .Pending {
				return .Waiting
			}
			// Idle timeout/EOF has no admitted request and emits no extra event.
			if err.kind != .None || n == 0 {
				return .Done
			}
			if !keep_alive_begin_request(task, n) {
				return .Done
			}
			continue
		case .Headers:
			if deadline_expired(conn.read_deadline) {
				if task.observed {
					task.event.outcome = .Timeout
				}
				if !queue_response(task, {status = .Request_Timeout}) {
					return .Done
				}
				continue
			}

			if strings.contains(string(task.header[:task.header_used]), HTTP_HEADERS_END) {
				if !prepare_request(task) {
					return .Done
				}
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
					if resource_pressure(task) {
						resource_reject(task)
						continue
					}

					observe_failure(task, .Allocation_Error)
					return .Done
				}

				copy(grown, task.header)
				task.header = grown
			}

			n, err := transport_read(task, task.header[task.header_used:], task.deadline)
			if err.kind == .Pending {
				return .Waiting
			}

			if err.kind == .Timeout {
				observe_io_error(task, err)
				if !queue_response(task, {status = .Request_Timeout}) {
					return .Done
				}
				continue
			}

			if err.kind != .None {
				observe_io_error(task, err)
				return .Done
			}

			if n > 0 {
				if task.observed {
					task.event.bytes_received += u64(n)
				}

				if task.header_used == 0 {
					task.deadline = task.header_deadline
					conn.read_deadline = task.header_read_deadline
				}
			}

			task.header_used += n
		case .Body:
			if task.body_used == len(task.request.body) {
				if deadline_expired(conn.read_deadline) {
					if task.observed {
						task.event.outcome = .Timeout
					}
					if !queue_response(task, {status = .Request_Timeout}) {
						return .Done
					}
				} else {
					conn.read_deadline = {}
					task.phase = .Dispatch
				}

				continue
			}

			n, err := task_read(task, task.request.body[task.body_used:])
			if err.kind == .Pending {
				return .Waiting
			}

			if err.kind == .Timeout {
				observe_io_error(task, err)
				if !queue_response(task, {status = .Request_Timeout}) {
					return .Done
				}
				continue
			}

			if err.kind == .Peer_Closed {
				observe_io_error(task, err)
				if !queue_response(task, {status = .Bad_Request}) {
					return .Done
				}
				continue
			}

			if err.kind != .None {
				observe_io_error(task, err)
				return .Done
			}

			task.body_used += n

		case .Chunked_Body:
			if deadline_expired(conn.read_deadline) {
				if !queue_response(task, {status = .Request_Timeout, close_connection = true}) {
					return .Done
				}
				continue
			}

			if len(conn.read_buffer) == 0 {
				n, error := transport_read(task, task.chunked.input[:], task.deadline)
				if error.kind == .Pending {
					return .Waiting
				}

				if error.kind != .None {
					observe_io_error(task, error)

					if error.kind == .Timeout || error.kind == .Peer_Closed {
						status: HTTP_Status = .Bad_Request
						if error.kind == .Timeout {
							status = .Request_Timeout
						}
						if !queue_response(task, {status = status, close_connection = true}) {
							return .Done
						}
						continue
					}

					return .Done
				}

				if n == 0 {
					if !queue_response(task, {status = .Bad_Request, close_connection = true}) {
						return .Done
					}
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
			if task.observed {
				task.event.bytes_received += u64(consumed)
			}

			if error.kind != .None {
				observe_failure(task, .Protocol_Error)
				if !queue_response(task, {status = chunk_error_status(error), close_connection = true}) {
					return .Done
				}
				continue
			}

			if done {
				if deadline_expired(conn.read_deadline) {
					if !queue_response(task, {status = .Request_Timeout, close_connection = true}) {
						return .Done
					}
					continue
				}

				task.request.body = task.request.body[:task.body_used]
				task.request.content_length = task.body_used
				conn.read_deadline = {}
				task.phase = .Dispatch
			}
		case .Dispatch:
			response := dispatch_request(task)
			if !queue_response(task, response) {
				return .Done
			}
		case .Await_Response:
			result := await_response(task)
			if result != .Yield {
				return result
			}
			continue
		case .Produce:
			result := produce_stream(task)
			if result != .Yield || task.phase == .Produce {
				return result
			}
			continue
		case .Write:
			if task.output_index == len(task.output) {
				if task.streaming != nil {
					produce, ok := stream_write_complete(task)
					if !ok {
						return .Done
					}

					if produce {
						task.phase = .Produce
						continue
					}
				}

				if !task.upgrade_established {
					task.response_finished = true
					task.requests_completed += 1

					if task.reuse_after_write {
						if !keep_alive_next_request(task) {
							return .Done
						}
						continue
					}
				}

				if task.finish_after_write {
					return .Done
				}
				task.phase = task.after_write

				if task.phase == .Upgrade {
					if !task.upgrade_established && !release_upgrade_request(task) {
						return .Done
					}
				}

				continue
			}

			data := task.output[task.output_index]

			if task.output_offset == len(data) {
				task.output_index += 1
				task.output_offset = 0
				continue
			}

			chunk := data[task.output_offset:min(task.output_offset + RESPONSE_WRITE_CHUNK_BYTES, len(data))]
			n, err := transport_write(task, chunk, task.deadline)
			if err.kind == .Pending {
				return .Waiting
			}
			if task.observed && n > 0 {
				task.event.bytes_sent += u64(n)
			}

			if err.kind != .None {
				observe_io_error(task, err)
				return .Done
			}

			task.output_offset += n
		case .Upgrade:
			if async.cancelled(&task.task) {
				return .Done
			}
			io := Upgrade_IO {
				runtime    = &task.runtime.executor,
				connection = &task.connection,
			}

			if task.tls_state == nil {
				io.socket = task.socket
			}
			result := task.upgrade.resume(task.upgrade.data, &io)
			upgrade_resume_finished(task)
			if result != .Yield {
				return result
			}
		case .HTTP2:
			return h2_step(task)
		}
	}

	return .Yield
}

prepare_request :: proc(task: ^Connection_Task) -> bool {
	allocator := mem.dynamic_arena_allocator(&task.arena)
	raw := string(task.header[:task.header_used])
	end := strings.index(raw, HTTP_HEADERS_END)
	if task.observed {
		task.event.bytes_received = u64(end + len(HTTP_HEADERS_END))
	}
	// Allocate header entries only after a request arrives, rather than
	// retaining the maximum table for every idle connection.
	count := min(strings.count(raw[:end], CRLF), REQUEST_HEADER_COUNT_LIMIT)
	headers, header_error := make([]Header, count, allocator)

	if header_error != nil {
		if resource_pressure(task) {
			return resource_reject(task)
		}
		observe_failure(task, .Allocation_Error)
		return false
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
	if request.chunked {
		body_capacity = min(limit, http.MAX_BODY_SIZE)
	}
	body, body_error := make([]u8, body_capacity, allocator)

	if body_error != nil {
		if resource_pressure(task) {
			return resource_reject(task)
		}
		observe_failure(task, .Allocation_Error)
		return false
	}

	task.request.body = body
	duration := body_timeout(task.runtime.timeouts, request.content_length)
	arm_read_deadline(task, duration)
	task.phase = .Body

	if request.chunked {
		state, allocation_error := new(Chunk_Request, allocator)

		if allocation_error != nil {
			if resource_pressure(task) {
				return resource_reject(task)
			}
			observe_failure(task, .Allocation_Error)
			return false
		}

		if http1.chunk_decoder_init(&state.decoder, u64(body_capacity)).kind != .None {
			return false
		}
		task.chunked = state
		task.phase = .Chunked_Body
	}

	return true
}

task_read :: proc(task: ^Connection_Task, destination: []u8) -> (int, async.Error) {
	if deadline_expired(task.connection.read_deadline) {
		return 0, {kind = .Timeout}
	}
	buffered := task.connection.read_buffer

	if len(buffered) > 0 {
		n := copy(destination, buffered)
		if task.observed && !task.upgrade_established {
			task.event.bytes_received += u64(n)
		}
		task.connection.read_buffer = buffered[n:]

		if len(task.connection.read_buffer) == 0 && task.upgrade_prefetched != nil {
			delete(task.upgrade_prefetched, connection_storage_allocator(task))
			task.upgrade_prefetched = nil
		}

		return n, {}
	}

	n, err := transport_read(task, destination, task.deadline)
	if task.observed && n > 0 && !task.upgrade_established {
		task.event.bytes_received += u64(n)
	}

	return n, err
}

init_connection_arena :: proc(task: ^Connection_Task) {
	allocator := charged.allocator(task.resource_binding)
	if allocator.procedure == nil {
		allocator = charged.allocator(task.resource_transport)
	}
	if allocator.procedure == nil {
		allocator = rt.heap_allocator()
	}
	mem.dynamic_arena_init(
		&task.arena,
		block_allocator = allocator,
		array_allocator = allocator,
		block_size = 16 * mem.Kilobyte,
		out_band_size = 8 * mem.Kilobyte,
	)
}

release_upgrade_request :: proc(task: ^Connection_Task) -> bool {
	finish_request_context(task)
	observe_finish(task)
	buffered := task.connection.read_buffer

	if len(buffered) > 0 {
		allocator := connection_storage_allocator(task)
		if allocator.procedure == nil {
			return false
		}
		saved, err := make([]u8, len(buffered), allocator)
		if err != nil {
			return false
		}
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
	if connection_storage_allocator(task).procedure == nil {
		return false
	}
	init_connection_arena(task)
	task.upgrade_established = true

	return true
}

queue_response :: proc(task: ^Connection_Task, response: Response) -> bool {
	// HTTP/2 streams use this same queue so gzip policy stays in one place.
	if task.http2 != nil {
		return h2_queue_response(task, response)
	}

	if resource_pressure(task) {
		discarded := response
		discard_response(&discarded)
		return resource_reject(task, resource_failure_status(response.status))
	}

	if deferred_present(response.deferred) {
		if queue_deferred(task, response) {
			return true
		}

		if resource_pressure(task) {
			drop_deferred(task)
			return resource_reject(task)
		}

		return false
	}

	prepared := response
	// Negotiates gzip after handlers, including deferred responses, return.
	content_coding_prepare(&task.request, &prepared)
	task.upgrade = prepared.upgrade
	if stream_present(prepared.stream) {
		return queue_stream_response(task, prepared)
	}

	if !resource_copy_response(task, &prepared) {
		drop_upgrade(task)

		if resource_pressure(task) {
			return resource_reject(task, resource_failure_status(response.status))
		}

		observe_failure(task, .Allocation_Error)
		return false
	}

	if (task.upgrade.resume != nil || task.upgrade.drop != nil || task.upgrade.data != nil) &&
	   (prepared.status != .Switching_Protocols || task.upgrade.resume == nil) {
		drop_upgrade(task)
		observe_failure(task, .Protocol_Error)
		return false
	}

	buffer, allocation_error := make([]u8, RESPONSE_HEADER_LIMIT, mem.dynamic_arena_allocator(&task.arena))

	if allocation_error != nil {
		if resource_pressure(task) {
			drop_upgrade(task)
			return resource_reject(task, resource_failure_status(prepared.status))
		}

		observe_failure(task, .Allocation_Error)
		return false
	}

	task.reuse_after_write = !prepared.close_connection && response_can_reuse(task, prepared.status)
	headers, ok := response_headers(prepared, buffer, task.reuse_after_write)

	if !ok {
		observe_failure(task, .Protocol_Error)
		return false
	}

	task.output = {headers, prepared.body, nil}
	if task.request.method == "HEAD" {
		task.output[1] = nil
	}
	task.output_index = 0
	task.output_offset = 0
	arm_write_deadline(task, task.runtime.timeouts.response)

	if task.observed {
		task.event.status = prepared.status
		if task.event.status == .None {
			task.event.status = .OK
		}
		if task.event.status == .Request_Timeout {
			task.event.outcome = .Timeout
		}
		if task.event.status == .Request_Header_Fields_Too_Large {
			task.event.outcome = .Protocol_Error
		}
	}

	task.finish_after_write = task.upgrade.resume == nil
	if !task.finish_after_write {
		task.after_write = .Upgrade
	}
	task.phase = .Write

	return true
}

dispatch_request :: proc(task: ^Connection_Task) -> Response {
	if !begin_request_context(task) {
		return Response{status = .Internal_Server_Error, close_connection = true}
	}
	response := task.runtime.config.handler(task.runtime.config.handler_data, &task.connection, &task.request)
	status := request_context_status(task.request.cancellation)
	if status == .Active {
		return response
	}
	discard_response(&response)
	observe_failure(task, .Timeout if status == .Deadline else .Cancelled)

	return Response {
		status = .Request_Timeout if status == .Deadline else .Service_Unavailable,
		close_connection = true,
	}
}

finish_connection :: proc(data: rawptr) {
	task := cast(^Connection_Task)data
	h2_destroy(task)
	keep_alive_leave_idle(task)
	_ = budget.close(task.resource_connection)
	drop_deferred(task)
	finish_request_context(task)
	observe_finish(task)
	drop_response_stream(task)
	drop_upgrade(task)
	if task.native_pending {
		net.close(task.connection.socket)
	}
	// The runtime has already closed adopted sockets and removed readiness.
	if task.upgrade_prefetched != nil {
		delete(task.upgrade_prefetched, connection_storage_allocator(task))
	}

	mem.dynamic_arena_destroy(&task.arena)

	if task.tls_state != nil {
		mem.zero(task.tls_state, size_of(TLS_State))
		free(task.tls_state, connection_storage_allocator(task))
	}

	finish_operation_resources(task)
	charged.release(&task.resource_transport)
	budget.release_scope(&task.resource_connection)
	sync.atomic_sub(&task.runtime.active_connections, 1)
	drain_connection_finished(task.runtime)
	connection_storage_free(task)
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

// Optional caller-owned control. Keep at a stable address until serve returns.
// stop_server, server_endpoint and server_capacity may be called from other
// threads. Reuse only after serve returns; one control cannot serve two instances
// at once. Snapshots copy values and do not extend the runtime's lifetime.
Server_Control :: struct {
	_mutex:                                     sync.Mutex,
	_runtime:                                   ^async.Runtime,
	_server:                                    ^Server_Runtime,
	_endpoint:                                  net.Endpoint,
	_in_use, _stop_requested:                   bool,
	_ever_published:                            bool,
	_drain_requested, _drain_default_requested: bool,
	_drain_timeout:                             time.Duration,
}

// A request made before the listener is published is remembered. Shutdown
// cancels suspended connections; callbacks already running finish cooperatively.
stop_server :: proc(control: ^Server_Control) {
	if control == nil {
		return
	}
	sync.lock(&control._mutex)
	defer sync.unlock(&control._mutex)
	control._stop_requested = true
	if control._server != nil {
		shutdown_runtime(control._server)
	}
}

// Return the bound endpoint while the server is published. False means no
// endpoint is currently available, including after shutdown unpublication.
server_endpoint :: proc(control: ^Server_Control) -> (net.Endpoint, bool) {
	if control == nil {
		return {}, false
	}
	sync.lock(&control._mutex)
	defer sync.unlock(&control._mutex)

	return control._endpoint, control._runtime != nil
}

claim_server :: proc(control: ^Server_Control) -> bool {
	if control == nil {
		return true
	}
	sync.lock(&control._mutex)
	defer sync.unlock(&control._mutex)
	if control._in_use {
		return false
	}
	control._in_use = true

	return true
}

release_server :: proc(control: ^Server_Control) {
	if control == nil {
		return
	}
	sync.lock(&control._mutex)
	defer sync.unlock(&control._mutex)
	control._runtime = nil
	control._server = nil
	control._endpoint = {}
	control._ever_published = false
	control._in_use = false
	control._stop_requested = false
	control._drain_requested = false
	control._drain_default_requested = false
	control._drain_timeout = 0
}

publish_server :: proc(control: ^Server_Control, runtime: ^Server_Runtime, endpoint: net.Endpoint) {
	if control == nil {
		return
	}
	sync.lock(&control._mutex)
	defer sync.unlock(&control._mutex)
	control._ever_published = true
	control._runtime = &runtime.executor
	control._server = runtime
	control._endpoint = endpoint

	if control._stop_requested {
		shutdown_runtime(runtime)
	} else if control._drain_requested {
		if control._drain_default_requested {
			request_runtime_drain(runtime, 0)
		}
		if control._drain_timeout > 0 {
			request_runtime_drain(runtime, control._drain_timeout)
		}
	}
}

unpublish_server :: proc(control: ^Server_Control) {
	if control == nil {
		return
	}
	sync.lock(&control._mutex)
	defer sync.unlock(&control._mutex)
	control._runtime = nil
	control._server = nil
}

server_stop_requested :: proc(control: ^Server_Control) -> bool {
	if control == nil {
		return false
	}
	sync.lock(&control._mutex)
	defer sync.unlock(&control._mutex)

	return control._stop_requested || control._drain_requested
}

// The UDP address is published only while the normal server is running.
server_http3_endpoint :: proc(control: ^Server_Control) -> (net.Endpoint, bool) {
	if control == nil {
		return {}, false
	}
	sync.lock(&control._mutex)
	defer sync.unlock(&control._mutex)
	if control._server == nil || !control._server.config.http3.enabled {
		return {}, false
	}

	return control._server.http3.config.endpoint, true
}

CAPACITY_GROWTH_RETRY_INTERVAL :: time.Second
CAPACITY_WARNING_INTERVAL :: 10 * time.Second

// Current is allocated admission capacity; maximum is the configured ceiling.
// Active includes setup, HTTP and upgraded sessions. Counters live until serve
// returns. Growth retains storage; request bodies remain allocated on demand.
Connection_Capacity :: struct {
	active, current, maximum, peak:                                  int,
	growths, growth_failures, rejected_capacity, admission_failures: u64,
}

// Copy pressure statistics without opening an HTTP connection. False means the
// server is not published; no runtime pointer escapes this call. Keep control
// at a stable address until serve returns.
server_capacity :: proc(control: ^Server_Control) -> (Connection_Capacity, bool) {
	if control == nil {
		return {}, false
	}
	sync.lock(&control._mutex)
	defer sync.unlock(&control._mutex)
	runtime := control._server
	if runtime == nil {
		return {}, false
	}
	sync.lock(&runtime.capacity_mutex)
	defer sync.unlock(&runtime.capacity_mutex)
	result := runtime.capacity_state
	result.active = sync.atomic_load(&runtime.active_connections)

	return result, true
}

server_limits :: proc(config: Server) -> (int, int, int, bool) {
	maximum := config.max_connections
	if maximum == 0 {
		maximum = DEFAULT_MAX_CONNECTIONS
	}
	initial := config.initial_connections
	if initial == 0 {
		initial = min(DEFAULT_INITIAL_CONNECTIONS, maximum)
	}
	workers := config.workers
	if workers == 0 {
		workers = DEFAULT_WORKERS
	}
	// Reserve a listener slot and one retiring task per worker. Socket tokens
	// have 32-bit indices. Bound arithmetic before deriving reserve sizes.
	invalid_setting := ""

	switch {
	case config.handler == nil:
		invalid_setting = "handler (required)"
	case maximum <= 0 || maximum > int(max(i32)) - 1:
		invalid_setting = "max_connections (must fit a positive socket capacity)"
	case initial <= 0 || initial > maximum:
		invalid_setting = "initial_connections (must be positive and <= max_connections)"
	case workers <= 0 || workers > max(int) / size_of(rawptr) - maximum - 1:
		invalid_setting = "workers (must be positive and fit runtime bookkeeping)"
	}

	if invalid_setting != "" {
		log.errorf(
			"Invalid server %s: initial_connections=%d, max_connections=%d, workers=%d",
			invalid_setting,
			initial,
			maximum,
			workers,
		)
		return 0, 0, 0, false
	}

	return initial, maximum, workers, true
}

// Only the accept task changes capacity. The mutex also protects snapshots.
// Evaluate projected occupancy so growth is complete before publishing the task
// that crosses 80%. A failed attempt is retried at most once per second.
server_capacity_admit :: proc(runtime: ^Server_Runtime) -> bool {
	sync.lock(&runtime.capacity_mutex)
	event: Capacity_Event
	defer {
		sync.unlock(&runtime.capacity_mutex)
		server_capacity_log(event)
	}

	state := &runtime.capacity_state
	active := sync.atomic_load(&runtime.active_connections)
	threshold := state.current - state.current / 5

	if active + 1 >= threshold {
		event = server_capacity_grow_locked(runtime, active)
	}

	if active >= state.current {
		state.rejected_capacity += 1
		return false
	}

	state.peak = max(state.peak, active + 1)

	return true
}

server_capacity_grow_locked :: proc(runtime: ^Server_Runtime, active: int) -> Capacity_Event {
	state := &runtime.capacity_state

	if state.current == state.maximum {
		return server_capacity_warn_locked(runtime, "configured ceiling", active)
	}

	now := time.tick_now()

	if runtime.capacity_retry_pending && time.tick_diff(now, runtime.capacity_retry_at) > 0 {
		return {}
	}

	target := state.current + min(state.current, state.maximum - state.current)
	workers := runtime.config.workers
	if workers == 0 {
		workers = DEFAULT_WORKERS
	}
	err := async.reserve(&runtime.executor, {target + workers + 1, target + 1})
	if err.kind == .Stopping {
		return {}
	}

	if err.kind != .None {
		state.growth_failures += 1
		runtime.capacity_retry_pending = true
		runtime.capacity_retry_at = time.tick_add(now, CAPACITY_GROWTH_RETRY_INTERVAL)
		return server_capacity_warn_locked(runtime, "storage expansion failed", active, err)
	}

	previous := state.current
	state.current = target
	state.growths += 1
	runtime.capacity_retry_pending = false

	return {previous = previous, state = state^, active = active}
}

server_capacity_allocation_failed :: proc(runtime: ^Server_Runtime) {
	sync.lock(&runtime.capacity_mutex)
	runtime.capacity_state.admission_failures += 1
	event := server_capacity_warn_locked(
		runtime,
		"connection admission failed",
		sync.atomic_load(&runtime.active_connections),
	)
	sync.unlock(&runtime.capacity_mutex)
	server_capacity_log(event)
}

server_capacity_warn_locked :: proc(
	runtime: ^Server_Runtime,
	reason: string,
	active: int,
	err: async.Error = {},
) -> Capacity_Event {
	now := time.tick_now()
	if runtime.capacity_warned && time.tick_diff(now, runtime.capacity_warning_at) > 0 {
		return {}
	}
	runtime.capacity_warned = true
	runtime.capacity_warning_at = time.tick_add(now, CAPACITY_WARNING_INTERVAL)
	return {state = runtime.capacity_state, active = active, reason = reason, error = err}
}

Capacity_Event :: struct {
	state:            Connection_Capacity,
	active, previous: int,
	reason:           string,
	error:            async.Error,
}

server_capacity_log :: proc(event: Capacity_Event) {
	state := event.state

	if event.previous > 0 {
		log.infof(
			"Connection capacity expanded: %d -> %d (active=%d, maximum=%d)",
			event.previous,
			state.current,
			event.active,
			state.maximum,
		)
	} else if event.reason != "" {
		log.warnf(
			"Connection capacity pressure: %s (active=%d, capacity=%d, maximum=%d, " +
			"rejected=%d, growth_failures=%d, admission_failures=%d, error=%v)",
			event.reason,
			event.active,
			state.current,
			state.maximum,
			state.rejected_capacity,
			state.growth_failures,
			state.admission_failures,
			event.error,
		)
	}
}

DEFAULT_OPERATION_RESOURCES :: budget.Limits{32 * mem.Megabyte, 1, 1}
// H2 can own both a protocol stream lease and a response-producer lease.
DEFAULT_CONNECTION_RESOURCES :: budget.Limits {
	bytes   = 64 * mem.Megabyte,
	streams = 64,
	jobs    = 4,
}
DEFAULT_SERVER_RESOURCES :: budget.Limits {
	bytes   = 256 * mem.Megabyte,
	streams = 4096,
	jobs    = 128,
}

// Nil limits select finite defaults; explicit zero limits admit nothing. Parent
// is borrowed during startup; the server owns a child and never closes Parent.
Resource_Config :: struct {
	parent:                                             budget.Scope,
	operation_limits, connection_limits, global_limits: Maybe(budget.Limits),
}
server_resources :: proc(control: ^Server_Control) -> (budget.Snapshot, bool) {
	if control == nil {
		return {}, false
	}
	sync.lock(&control._mutex)
	defer sync.unlock(&control._mutex)
	if control._server == nil {
		return {}, false
	}
	view, error := budget.snapshot(control._server.resources)

	return view, error == .None
}
// Returned ownership survives runtime retirement. Release it explicitly.
retain_server_resources :: proc(control: ^Server_Control) -> (budget.Scope, bool) {
	if control == nil {
		return {}, false
	}
	sync.lock(&control._mutex)
	defer sync.unlock(&control._mutex)
	if control._server == nil {
		return {}, false
	}
	owner, error := budget.retain_scope(control._server.resources)

	return owner, error == .None
}
initialize_resources :: proc(runtime: ^Server_Runtime) -> bool {
	config := runtime.config.resources
	runtime.operation_limits = DEFAULT_OPERATION_RESOURCES
	runtime.connection_limits = DEFAULT_CONNECTION_RESOURCES
	limits := DEFAULT_SERVER_RESOURCES
	if value, ok := config.operation_limits.?; ok {
		runtime.operation_limits = value
	}
	if value, ok := config.connection_limits.?; ok {
		runtime.connection_limits = value
	}
	if value, ok := config.global_limits.?; ok {
		limits = value
	}
	error: budget.Error

	if scope_managed(config.parent) {
		runtime.resources, error = budget.create_child(config.parent, limits)
	} else {
		runtime.resources, error = budget.create_root(limits)
	}

	if error != .None {
		return false
	}
	view, snapshot_error := budget.snapshot(runtime.resources)

	if snapshot_error != .None || view.depth > budget.MAX_DEPTH - 2 {
		budget.release_scope(&runtime.resources)
		return false
	}

	return true
}
scope_managed :: proc(scope: budget.Scope) -> bool {
	return budget.same_scope(scope, scope)
}

start_connection_resources :: proc(task: ^Connection_Task) -> bool {
	if !scope_managed(task.runtime.resources) {
		return true
	}

	owner, error := budget.create_child(task.runtime.resources, task.runtime.connection_limits)
	if error != .None {
		return false
	}
	task.resource_connection = owner

	return start_operation_resources(task)
}
start_operation_resources :: proc(task: ^Connection_Task) -> bool {
	if !scope_managed(task.resource_connection) {
		return true
	}

	owner, error := budget.create_child(task.resource_connection, task.runtime.operation_limits)
	if error != .None {
		return false
	}
	binding, binding_error := charged.create(owner)

	if binding_error.kind != .None {
		budget.release_scope(&owner)
		return false
	}

	task.resource_operation, task.resource_binding = owner, binding

	return true
}
finish_operation_resources :: proc(task: ^Connection_Task) {
	_ = budget.close(task.resource_operation)
	charged.release(&task.resource_binding)
	budget.release_scope(&task.resource_operation)
}
release_task_storage :: proc(task: ^Connection_Task) {
	mem.dynamic_arena_destroy(&task.arena)
	finish_operation_resources(task)
	charged.release(&task.resource_transport)
	budget.release_scope(&task.resource_connection)
}

resource_pressure :: proc(task: ^Connection_Task) -> bool {
	return charged.stats(task.resource_binding).rejected != 0
}
// Fixed task storage remains usable after payload admission is exhausted.
resource_reject :: proc(task: ^Connection_Task, status: HTTP_Status = .Service_Unavailable) -> bool {
	if task.http2_request != nil {
		return h2_request_emergency(task, status)
	}

	head, encoded := response_headers({status = status}, task.resource_emergency)
	if !encoded {
		return false
	}
	task.output = {head, nil, nil}
	task.output_index, task.output_offset = 0, 0
	task.reuse_after_write = false
	task.finish_after_write = true
	arm_write_deadline(task, task.runtime.timeouts.response)
	task.phase = .Write

	if task.observed {
		task.event.status = status
		task.event.outcome = .Timeout if status == .Request_Timeout else .Allocation_Error
	}

	return true
}
// Unknown raw borrows have no full-allocation provenance. Copy before suspension.
resource_copy_response :: proc(task: ^Connection_Task, response: ^Response) -> bool {
	if len(response.trailers) > 0 && task.request.version != "HTTP/3" {
		return false
	}

	if !scope_managed(task.resource_operation) {
		return true
	}

	allocator := mem.dynamic_arena_allocator(&task.arena)
	body := response.body
	// HEAD only needs the representation length while encoding its head.
	if task.request.method != "HEAD" {
		storage, error := make([]u8, len(body), allocator)
		if error != nil {
			return false
		}
		copy(storage, body)
		body = storage
	}

	headers, headers_ok := clone_headers(response.headers, allocator)

	if !headers_ok {
		return false
	}

	trailers, trailers_ok := clone_headers(response.trailers, allocator)

	if !trailers_ok {
		return false
	}

	response.body = body
	response.headers = headers
	response.trailers = trailers

	return true
}
clone_headers :: proc(fields: []Header, allocator: mem.Allocator) -> ([]Header, bool) {
	cloned, error := make([]Header, len(fields), allocator)

	if error != nil {
		return nil, false
	}

	for field, i in fields {
		name, name_error := strings.clone(field.name, allocator)
		value, value_error := strings.clone(field.value, allocator)

		if name_error != nil || value_error != nil {
			return nil, false
		}

		cloned[i] = {name, value}
	}

	return cloned, true
}

connection_storage_allocator :: proc(task: ^Connection_Task) -> mem.Allocator {
	if !scope_managed(task.resource_connection) {
		return rt.heap_allocator()
	}

	allocator := charged.allocator(task.resource_transport)

	if allocator.procedure == nil {
		binding, error := charged.create(task.resource_connection)
		if error.kind != .None {
			return {}
		}
		task.resource_transport = binding
		allocator = charged.allocator(binding)
	}

	return allocator
}

resource_failure_status :: proc(status: HTTP_Status) -> HTTP_Status {
	if status == .Request_Timeout || status == .Content_Too_Large {
		return status
	}

	return .Service_Unavailable
}

MAX_EVENT_ROUTE_BYTES :: 128

Request_Outcome :: enum {
	Completed,
	Timeout,
	Cancelled,
	Peer_Closed,
	IO_Error,
	Allocation_Error,
	Protocol_Error,
}

// Callback strings borrow request-owned/static data only until return. Route is
// a bounded matched template, never the raw path/query; unknown methods are OTHER.
Request_Event :: struct {
	request_id:                 u64,
	method, route:              string,
	status:                     HTTP_Status,
	duration:                   time.Duration,
	bytes_received, bytes_sent: u64,
	outcome:                    Request_Outcome,
}

// Keep data and callback state alive until serve returns. The synchronous hook
// runs on the finishing worker, once per HTTP attempt (101 completes on upgrade),
// before request storage is released and outside internal locks. Different
// requests may call it concurrently. Copy any retained event/strings. It may
// query snapshots or request stop/drain, but must not block or call serve again.
Observability_Config :: struct {
	enabled:     bool,
	on_complete: proc(data: rawptr, event: ^Request_Event),
	data:        rawptr,
}

Request_Metrics :: struct {
	started, completed, active:  u64,
	bytes_received, bytes_sent:  u64,
	timeouts, cancelled, errors: u64,
	// Index 0 means no HTTP status was prepared; other indices are wire codes.
	statuses:                    [600]u64,
	total_duration:              time.Duration,
}

// Snapshots never invoke observers or expose runtime pointers. False means the
// server is not published. Disabled observations return a zero snapshot.
server_metrics :: proc(control: ^Server_Control) -> (Request_Metrics, bool) {
	if control == nil {
		return {}, false
	}
	sync.lock(&control._mutex)
	defer sync.unlock(&control._mutex)
	runtime := control._server
	if runtime == nil {
		return {}, false
	}
	sync.lock(&runtime.observability_mutex)
	defer sync.unlock(&runtime.observability_mutex)

	return runtime.metrics, true
}

observability_enabled :: proc(config: Observability_Config) -> bool {
	return config.enabled || config.on_complete != nil
}

observe_start :: proc(task: ^Connection_Task) {
	if !observability_enabled(task.runtime.config.observability) {
		return
	}
	task.observed = true
	task.observed_at = time.tick_now()
	sync.lock(&task.runtime.observability_mutex)
	task.runtime.next_request_id += 1
	task.event.request_id = task.runtime.next_request_id
	task.runtime.metrics.started += 1
	task.runtime.metrics.active += 1
	sync.unlock(&task.runtime.observability_mutex)
}

observe_io_error :: proc(task: ^Connection_Task, error: async.Error) {
	status: Request_Status
	outcome: Request_Outcome
	#partial switch error.kind {
	case .None, .Pending:
		return
	case .Timeout:
		status, outcome = .Deadline, .Timeout
	case .Cancelled, .Stopping:
		status, outcome = .Shutdown, .Cancelled
	case .Peer_Closed:
		status, outcome = .Peer_Closed, .Peer_Closed
	case:
		status, outcome = .Failed, .IO_Error
	}

	cancel_request_context(task.request.cancellation, status)
	observe_failure(task, outcome)
}

event_method :: proc(method: string) -> string {
	switch method {
	case "GET", "POST", "HEAD", "PUT", "DELETE", "PATCH", "OPTIONS", "CONNECT", "TRACE":
		return method
	}

	return "OTHER"
}

observe_finish :: proc(task: ^Connection_Task) {
	if !task.observed || task.observation_finished {
		return
	}
	task.observation_finished = true
	event := task.event
	event.method = event_method(task.request.method)
	if len(task.request.route) <= MAX_EVENT_ROUTE_BYTES {
		event.route = task.request.route
	}
	event.duration = time.tick_diff(task.observed_at, time.tick_now())
	if !task.response_finished && async.cancelled(&task.task) && event.outcome == .Completed {
		event.outcome = .Cancelled
	}
	if !task.response_finished && event.outcome == .Completed {
		event.outcome = .IO_Error
	}
	runtime := task.runtime
	sync.lock(&runtime.observability_mutex)
	metrics := &runtime.metrics
	metrics.completed += 1
	metrics.active -= 1
	metrics.bytes_received += event.bytes_received
	metrics.bytes_sent += event.bytes_sent
	metrics.total_duration += min(event.duration, time.Duration(max(i64)) - metrics.total_duration)
	if event.outcome == .Timeout {
		metrics.timeouts += 1
	}
	if event.outcome == .Cancelled {
		metrics.cancelled += 1
	}
	if event.outcome != .Completed {
		metrics.errors += 1
	}
	if int(event.status) >= 0 && int(event.status) < len(metrics.statuses) {
		metrics.statuses[int(event.status)] += 1
	}
	sync.unlock(&runtime.observability_mutex)
	callback := runtime.config.observability.on_complete
	if callback != nil {
		callback(runtime.config.observability.data, &event)
	}
}

observe_failure :: proc(task: ^Connection_Task, outcome: Request_Outcome) {
	if task.observed {
		task.event.outcome = outcome
	}
}

Request_Status :: enum {
	Active,
	Unavailable,
	Completed,
	Deadline,
	Shutdown,
	Peer_Closed,
	Failed,
}

// Request.cancellation is borrowed during the handler. Retain explicitly for
// other work; each owned handle must be released once. Neither node retains the
// request arena, connection, runtime, socket, or response. Copies are aliases.
Request_Context :: struct {
	_state: ^Request_Cancellation,
}

Server_Cancellation :: struct {
	references: i64,
	stopping:   bool,
	drain_at:   i64,
}
Request_Cancellation :: struct {
	resources:            budget.Scope,
	connection_resources: budget.Scope,
	references:           i64,
	status:               Request_Status,
	deadline:             time.Tick,
	server:               ^Server_Cancellation,
	allocator:            mem.Allocator,
}

retain_request_context :: proc(source: Request_Context) -> (Request_Context, bool) {
	if source._state == nil {
		return {}, false
	}
	previous := sync.atomic_add(&source._state.references, 1)
	assert(previous > 0 && previous < max(i64))

	return source, true
}

release_request_context :: proc(owner: ^Request_Context) {
	if owner == nil {
		return
	}
	node := owner._state
	owner^ = {}
	if node == nil {
		return
	}

	if sync.atomic_sub(&node.references, 1) == 1 {
		budget.release_scope(&node.resources)
		release_server_cancellation(node.server)
		free(node, node.allocator)
	}
}

request_deadline :: proc(ctx: Request_Context) -> time.Tick {
	if ctx._state == nil {
		return {}
	}

	return ctx._state.deadline
}

// Terminal status is first-observed and stable. Deadline polling is monotonic;
// shutdown remains observable by retained owners even after serve returns.
request_context_status :: proc(ctx: Request_Context) -> Request_Status {
	node := ctx._state
	if node == nil {
		return .Unavailable
	}
	current := sync.atomic_load(&node.status)
	if current != .Active {
		return current
	}

	if node.server != nil && (sync.atomic_load(&node.server.stopping) || server_cancellation_expired(node.server)) {
		cancel_request_context(ctx, .Shutdown)
	} else if deadline_expired(node.deadline) {
		cancel_request_context(ctx, .Deadline)
	}

	return sync.atomic_load(&node.status)
}

request_cancelled :: proc(ctx: Request_Context) -> bool {
	status := request_context_status(ctx)

	return status != .Active && status != .Unavailable
}

cancel_request_context :: proc(ctx: Request_Context, status: Request_Status) {
	if ctx._state == nil {
		return
	}
	assert(status != .Active && status != .Unavailable)
	sync.atomic_compare_exchange_strong(&ctx._state.status, .Active, status)
}

new_request_context :: proc(
	server: ^Server_Cancellation,
	deadline: time.Tick,
	allocator: mem.Allocator,
) -> (
	Request_Context,
	bool,
) {
	node, error := new(Request_Cancellation, allocator)
	if error != nil || node == nil {
		return {}, false
	}
	node^ = {
		references = 1,
		deadline   = deadline,
		server     = server,
		allocator  = allocator,
	}
	if server != nil {
		sync.atomic_add(&server.references, 1)
	}
	return {node}, true
}

release_server_cancellation :: proc(state: ^Server_Cancellation) {
	if state != nil && sync.atomic_sub(&state.references, 1) == 1 {
		free(state, rt.heap_allocator())
	}
}

shutdown_runtime :: proc(runtime: ^Server_Runtime) {
	if runtime.cancellation != nil {
		sync.atomic_store(&runtime.cancellation.stopping, true)
	}
	// Existing shutdown owns sockets, task cancellation and worker joins.
	_ = budget.close(runtime.resources)
	async.shutdown(&runtime.executor)
}

begin_request_context :: proc(task: ^Connection_Task) -> bool {
	if task.request.cancellation._state != nil {
		return true
	}
	deadline: time.Tick
	if task.runtime.config.handler_timeout > 0 {
		deadline = time.tick_add(time.tick_now(), task.runtime.config.handler_timeout)
	}
	ctx, ok := new_request_context(task.runtime.cancellation, deadline, rt.heap_allocator())
	if !ok {
		return false
	}

	if scope_managed(task.resource_operation) {
		owner, error := budget.retain_scope(task.resource_operation)

		if error != .None {
			release_request_context(&ctx)
			return false
		}

		ctx._state.resources = owner

		if budget.covers(owner, task.resource_connection) {
			ctx._state.connection_resources = task.resource_connection
		}
	}

	task.request.cancellation = ctx

	return true
}

finish_request_context :: proc(task: ^Connection_Task) {
	ctx := task.request.cancellation
	if ctx._state == nil {
		return
	}
	_ = request_context_status(ctx)
	status: Request_Status = .Completed

	if !task.response_finished {
		status = .Failed
	}

	if async.cancelled(&task.task) {
		status = .Shutdown
	}

	cancel_request_context(ctx, status)
	release_request_context(&task.request.cancellation)
}

server_cancellation_expired :: proc(state: ^Server_Cancellation) -> bool {
	at := sync.atomic_load(&state.drain_at)

	return at != 0 && deadline_expired(time.tick_add({}, time.Duration(at)))
}

// Borrowed while the retained context lives; retain for an independent owner.
request_resources :: proc(ctx: Request_Context) -> budget.Scope {
	if ctx._state == nil {
		return {}
	}

	return ctx._state.resources
}

// Borrowed through the retained operation's parent link, never a raw connection.
request_connection_resources :: proc(ctx: Request_Context) -> budget.Scope {
	if ctx._state == nil {
		return {}
	}

	return ctx._state.connection_resources
}

// Independent of the request's stable terminal status. A retained request
// context can observe graceful drain or immediate stop after HTTP upgrade.
// Nil/unavailable contexts return false; no request arena or Runtime is retained.
request_server_stopping :: proc(ctx: Request_Context) -> bool {
	if ctx._state == nil || ctx._state.server == nil {
		return false
	}
	server := ctx._state.server

	return sync.atomic_load(&server.stopping) || sync.atomic_load(&server.drain_at) != 0
}

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
	resources:         budget.Scope,
	backing_allocator: mem.Allocator,
	allocator:         mem.Allocator,
	cancellation:      Request_Context,
	wake:              signal.Signal,
}

deferred_present :: proc(value: Deferred_Response) -> bool {
	return value.data != nil || value.poll != nil || value.drop != nil || value.timeout != 0
}

drop_deferred :: proc(task: ^Connection_Task) {
	old := task.deferred
	task.deferred = {}
	signal.detach(task.deferred_signal)
	signal.release(&task.deferred_signal)
	if old.drop != nil {
		old.drop(old.data)
	}
}

// queue_deferred wakes the TCP task; multiplexed transports hand the wake to their owner task.
rebind_deferred_signal :: proc(task: ^Connection_Task, owner: ^async.Task) -> bool {
	signal.detach(task.deferred_signal)
	signal.release(&task.deferred_signal)
	created: bool
	task.deferred_signal, created = signal.create(&task.runtime.executor, owner)

	return created
}

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
		discard_response(&prepared)
		observe_failure(task, .Protocol_Error)
		return false
	}

	duration := value.timeout
	if duration == 0 {
		duration = task.runtime.timeouts.response
	}

	if duration <= 0 || duration > MAX_SERVER_TIMEOUT {
		discard_response(&prepared)
		observe_failure(task, .Protocol_Error)
		return false
	}

	task.deferred = value
	task.deferred_expires = time.tick_add(time.tick_now(), duration)
	inherited := request_deadline(task.request.cancellation)

	if inherited != (time.Tick{}) && time.tick_diff(inherited, task.deferred_expires) > 0 {
		task.deferred_expires = inherited
	}

	remaining := time.tick_diff(time.tick_now(), task.deferred_expires)
	if remaining <= 0 {
		return false
	}
	task.deferred_deadline = async.deadline_after(&task.runtime.executor, remaining)
	s, ok := signal.create(&task.runtime.executor, &task.task)

	if !ok {
		observe_failure(task, .Allocation_Error)
		return false
	}

	task.deferred_signal = s
	task.deferred_used = len(task.connection.read_buffer)
	if task.deferred_used > REQUEST_HEADER_LIMIT {
		return false
	}
	capacity := max(512, task.deferred_used)
	buffer, error := make([]u8, capacity, mem.dynamic_arena_allocator(&task.arena))

	if error != nil {
		observe_failure(task, .Allocation_Error)
		return false
	}

	copy(buffer, task.connection.read_buffer)
	task.deferred_buffer = buffer
	task.phase = .Await_Response

	return true
}

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

		if status != .Deadline {
			response.status = .Service_Unavailable
		}
		if !queue_response(task, response) {
			return .Done
		}
		return .Yield
	}

	io := Deferred_IO {
		resources         = task.resource_operation,
		backing_allocator = task.request.backing_allocator,
		allocator         = mem.dynamic_arena_allocator(&task.arena),
		cancellation      = task.request.cancellation,
		wake              = task.deferred_signal,
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
				drop_deferred(task)
				resource_reject(task)
				return .Yield
			}

			observe_failure(task, .IO_Error)
			return .Done
		}

		return await_peer_or_result(task)
	}

	drop_deferred(task)

	if deferred_present(response.deferred) {
		discard_response(&response)
		observe_failure(task, .Protocol_Error)
		return .Done
	}

	task.connection.read_buffer = task.deferred_buffer[:task.deferred_used]
	task.deferred_buffer = nil
	task.deferred_used = 0
	task.phase = .Dispatch
	if !queue_response(task, response) {
		return .Done
	}

	return .Yield
}

// Read readiness detects EOF while work is blocked. Preserve bounded pipelined
// input for the next request, and never spin on an unread readable socket.
await_peer_or_result :: proc(task: ^Connection_Task) -> async.Resume_Result {
	if task.deferred_used == len(task.deferred_buffer) {
		if task.deferred_used == REQUEST_HEADER_LIMIT {
			observe_failure(task, .Protocol_Error)
			return .Done
		}

		capacity := min(2 * len(task.deferred_buffer), REQUEST_HEADER_LIMIT)
		buffer, error := make([]u8, capacity, mem.dynamic_arena_allocator(&task.arena))

		if error != nil {
			if resource_pressure(task) {
				drop_deferred(task)
				resource_reject(task)
				return .Yield
			}

			observe_failure(task, .Allocation_Error)
			return .Done
		}

		copy(buffer, task.deferred_buffer)
		task.deferred_buffer = buffer
	}

	n, error := transport_read(task, task.deferred_buffer[task.deferred_used:], task.deferred_deadline)
	if error.kind == .Pending {
		return .Waiting
	}

	if error.kind == .Timeout {
		cancel_request_context(task.request.cancellation, .Deadline)
		return .Yield
	}

	if error.kind != .None || n == 0 {
		cancel_request_context(task.request.cancellation, .Peer_Closed)
		observe_failure(task, .Cancelled)
		return .Done
	}

	task.deferred_used += n

	return .Yield
}

DEFAULT_DRAIN_TIMEOUT :: 5 * time.Second
MAX_DRAIN_TIMEOUT :: 24 * time.Hour

Server_State :: enum {
	Stopped,
	Starting,
	Ready,
	Draining,
	Stopping,
}

// Endpoint publication is independent of readiness: a draining server may still
// own its address and admitted requests. The snapshot never extends its lifetime.
server_state :: proc(control: ^Server_Control) -> Server_State {
	if control == nil {
		return .Stopped
	}
	sync.lock(&control._mutex)
	defer sync.unlock(&control._mutex)
	if !control._in_use {
		return .Stopped
	}

	if control._runtime == nil {
		return .Stopping if control._ever_published else .Starting
	}

	if control._stop_requested || async.cancelled(&control._server.accept_task) {
		return .Stopping
	}
	if server_is_draining(control._server) {
		return .Draining
	}

	return .Ready
}

server_ready :: proc(control: ^Server_Control) -> bool {
	return server_state(control) == .Ready
}

// Nonblocking, safe from observers/handlers or a controlling thread. Zero uses
// Server.drain_timeout (then the five-second default). Repeated requests may
// shorten but never extend the deadline. stop_server still means immediate stop.
// Calls before publication are remembered. Arbitrary blocking handlers cannot
// be preempted; serve joins only after their callbacks return cooperatively.
drain_server :: proc(control: ^Server_Control, timeout: time.Duration = 0) -> bool {
	if control == nil || !drain_duration_valid(timeout) {
		return false
	}
	sync.lock(&control._mutex)
	defer sync.unlock(&control._mutex)
	if control._stop_requested {
		return false
	}
	control._drain_requested = true
	if timeout == 0 {
		control._drain_default_requested = true
	}
	else if control._drain_timeout == 0 || timeout < control._drain_timeout {
		control._drain_timeout = timeout
	}

	if control._server != nil {
		request_runtime_drain(control._server, timeout)
	}

	return true
}

drain_duration_valid :: proc(timeout: time.Duration) -> bool {
	return timeout >= 0 && timeout <= MAX_DRAIN_TIMEOUT
}

server_is_draining :: proc(runtime: ^Server_Runtime) -> bool {
	if runtime == nil {
		return false
	}
	sync.lock(&runtime.drain_mutex)
	defer sync.unlock(&runtime.drain_mutex)

	return runtime.draining
}

request_runtime_drain :: proc(runtime: ^Server_Runtime, timeout: time.Duration) {
	budget := timeout
	if budget == 0 {
		budget = runtime.config.drain_timeout
	}
	if budget == 0 {
		budget = DEFAULT_DRAIN_TIMEOUT
	}
	deadline := async.deadline_after(&runtime.executor, budget)
	sync.lock(&runtime.drain_mutex)

	if !runtime.draining || deadline.at < runtime.drain_deadline.at {
		runtime.draining = true
		runtime.drain_deadline = deadline

		if runtime.cancellation != nil {
			at := time.tick_add(time.tick_now(), budget)
			sync.atomic_store(&runtime.cancellation.drain_at, i64(time.tick_diff({}, at)))
		}
	}

	sync.unlock(&runtime.drain_mutex)
	wake_keep_alive_connections(runtime)
	// The listener task closes its own socket, avoiding races with running accept.
	async.wake(&runtime.executor, &runtime.accept_task)
	if runtime.config.http3.enabled {
		async.wake(&runtime.executor, &runtime.http3.task)
	}
}

drain_connections :: proc(runtime: ^Server_Runtime) -> async.Resume_Result {
	// This is the accept task itself, so close cannot race its socket operations.
	async.close(runtime.listener)
	sync.lock(&runtime.drain_mutex)
	deadline := runtime.drain_deadline
	sync.unlock(&runtime.drain_mutex)
	if sync.atomic_load(&runtime.active_connections) == 0 &&
	   (!runtime.config.http3.enabled || !sync.atomic_load(&runtime.http3._pending)) {
		shutdown_runtime(runtime)
		return .Done
	}

	err := async.sleep_until(&runtime.executor, deadline)
	if err.kind == .Pending {
		return .Waiting
	}
	// Deadline expiry or runtime failure cancels residual readers/writers/WS.
	shutdown_runtime(runtime)

	return .Done
}

drain_connection_finished :: proc(runtime: ^Server_Runtime) {
	if server_is_draining(runtime) {
		async.wake(&runtime.executor, &runtime.accept_task)
	}
}
