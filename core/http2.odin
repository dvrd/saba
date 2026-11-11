package saba_core

import http "../../http"
import h2 "shared:http/v2"
import hpack "shared:http/v2/hpack"
import "core:fmt"
import "core:mem"
import owned "core:mem/owned"
import "core:strings"
import budget "core:sync/budget"
import "core:time"
import async "shared:async"

// One active stream. Its lease is the connection stream allowance, so a second
// concurrent HTTP/2 stream is refused instead of reserving another exchange stream.
// A closed stream keeps its metadata until the grace barrier is acknowledged.
// H2_STREAM_SLOTS holds those records so the next request can be admitted.
// Buffered responses, including gzip, still enter through queue_response.
H2_MAX_STREAMS :: 1
H2_STREAM_SLOTS :: 8
H2_FRAME_BYTES :: 16384
H2_BODY_BUFFER :: 64 * 1024
H2_BODY_CHUNKS :: 8
H2_EVENTS :: 16
H2_CONTROL_FRAMES :: 8
H2_INGRESS :: 16 * 1024
H2_NAME_SCRATCH :: 2048
H2_FIELD_CAP :: 64

HTTP2_Session :: struct {
	engine: h2.Connection,
	allocator: mem.Allocator,
	limits: h2.Limits,
	engine_ready, failed, peer_gone, shutdown, request_open, receiving: bool,
	response_ready, headers_sent, have_length, discard_input, needs_reset: bool,
	handle: h2.Stream_Handle,
	reap: [H2_STREAM_SLOTS]h2.Stream_Handle,
	reap_count: int,
	expected, body_len, body_sent, limit: int,
	body_deadline, idle_deadline, response_deadline: time.Tick,
	response: Response,
	chunk: owned.Chunk,
	ingress: [H2_INGRESS]u8,
	ingress_len: int,
	names: [H2_NAME_SCRATCH]u8,
	name_used: int,
}

h2_make_limits :: proc(streams: int) -> h2.Limits {
	return {
		frame_payload_bytes = H2_FRAME_BYTES,
		streams = streams,
		reserved_streams = 0,
		header_block_bytes = REQUEST_HEADER_LIMIT,
		header_list_bytes = REQUEST_HEADER_LIMIT,
		header_fields = REQUEST_HEADER_COUNT_LIMIT,
		hpack_table_bytes = 4096,
		retained_body_bytes = H2_BODY_BUFFER,
		body_chunks = H2_BODY_CHUNKS,
		events = H2_EVENTS,
		control_frames = H2_CONTROL_FRAMES,
		pending_settings = 4,
		pending_pings = 4,
		continuation_frames = 8,
		work_per_feed = 32 * 1024,
	}
}

// Exactly the negotiated token. Absent ALPN, http/1.1 and h3 stay off this path.
h2_selected_protocol :: proc(protocol: string) -> bool {
	return protocol == "h2"
}

@(private)
h2_stream_allowance :: proc(task: ^Connection_Task) -> int {
	if !budget.same_scope(task.resource_connection, task.resource_connection) do return H2_MAX_STREAMS
	view, error := budget.snapshot(task.resource_connection)
	if error != .None || view.limits.streams == 0 do return 0
	if view.limits.streams > u64(H2_MAX_STREAMS) do return H2_MAX_STREAMS
	return int(view.limits.streams)
}

@(private)
h2_begin :: proc(task: ^Connection_Task) -> bool {
	if task.http2 != nil do return true
	allowance := h2_stream_allowance(task)
	limits := h2_make_limits(allowance)
	if h2.limits_validate(limits).kind != .None do return false
	allocator := connection_storage_allocator(task)
	if allocator.procedure == nil do return false
	session, alloc_error := new(HTTP2_Session, allocator)
	if alloc_error != nil || session == nil do return false
	session.allocator = allocator
	session.limits = limits
	scope: budget.Scope
	if budget.same_scope(task.resource_connection, task.resource_connection) {
		scope = task.resource_connection
	}
	options := h2.Engine_Options{
		max_stream_capacity = H2_STREAM_SLOTS,
		control_frame_bytes = 256,
		header_sections = 4,
		enable_push = false,
		promise_policy = .Decline,
	}
	init_error := h2.connection_init(&session.engine, {
		role = .Server, limits = limits, initial_stream_capacity = H2_STREAM_SLOTS, scope = scope,
	}, options, allocator)
	if init_error.kind != .None {
		free(session, allocator)
		return false
	}
	session.engine_ready = true
	session.idle_deadline = time.tick_add(time.tick_now(), task.runtime.timeouts.header)
	task.http2 = session
	return true
}

@(private)
h2_destroy :: proc(task: ^Connection_Task) {
	session := task.http2
	if session == nil do return
	task.http2 = nil
	owned.destroy(&session.chunk)
	if session.response_ready {
		discard_response(&session.response)
	}
	if session.engine_ready {
		if view, borrowed := h2.connection_output_front(&session.engine); borrowed {
			_ = h2.connection_output_release(&session.engine, view.token)
		}
		for _ in 0 ..< H2_EVENTS {
			event, ok := h2.connection_poll(&session.engine)
			if !ok do break
			_ = h2.connection_event_release(&session.engine, event.token)
		}
		_ = h2.connection_destroy(&session.engine)
	}
	free(session, session.allocator)
}

@(private)
h2_queue_response :: proc(task: ^Connection_Task, response: Response) -> bool {
	session := task.http2
	if session == nil || session.failed || session.response_ready {
		discarded := response
		discard_response(&discarded)
		return false
	}
	prepared := response
	unsupported := stream_present(prepared.stream) || deferred_present(prepared.deferred) ||
		prepared.upgrade.resume != nil || prepared.upgrade.drop != nil || prepared.upgrade.data != nil ||
		prepared.status == .Switching_Protocols
	if unsupported {
		discard_response(&prepared)
		prepared = {status = .Not_Implemented}
	}
	content_coding_prepare(&task.request, &prepared)
	if stream_present(prepared.stream) {
		discard_response(&prepared)
		prepared = {status = .Not_Implemented}
	}
	if !resource_copy_response(task, &prepared) {
		discard_response(&prepared)
		session.failed = true
		return false
	}
	if prepared.status == .None do prepared.status = .OK
	session.response = prepared
	session.response_ready = true
	session.headers_sent = false
	session.body_sent = 0
	session.response_deadline = time.tick_add(time.tick_now(), task.runtime.timeouts.response)
	task.event.status = prepared.status
	if prepared.status == .Request_Timeout do observe_failure(task, .Timeout)
	if prepared.status == .Request_Header_Fields_Too_Large do observe_failure(task, .Protocol_Error)
	return true
}

@(private)
h2_shutdown :: proc(task: ^Connection_Task) {
	session := task.http2
	if session == nil || !session.engine_ready || session.shutdown || session.failed do return
	error := h2.connection_shutdown_begin(&session.engine)
	if error.kind == .None || error.kind == .Closed do session.shutdown = true
}

@(private)
h2_reset_stream :: proc(task: ^Connection_Task, code: h2.Error_Code) -> bool {
	session := task.http2
	if session == nil || !session.engine_ready do return true
	session.receiving = false
	session.needs_reset = true
	if session.handle == {} {
		session.needs_reset = false
		session.request_open = false
		return true
	}
	error := h2.connection_reset(&session.engine, session.handle, code)
	if error.kind == .Limit_Exceeded do return false
	h2_remember(session, session.handle)
	session.needs_reset = false
	session.request_open = false
	session.handle = {}
	return true
}

@(private)
h2_remember :: proc(session: ^HTTP2_Session, handle: h2.Stream_Handle) {
	if session == nil || handle.stream_id == 0 do return
	for index in 0 ..< session.reap_count {
		if session.reap[index] == handle do return
	}
	if session.reap_count >= len(session.reap) do return
	session.reap[session.reap_count] = handle
	session.reap_count += 1
}

// Release a finished stream's exchange lease and metadata before the next
// HEADERS frame. The grace barrier can outlive the lease; spare slots cover that.
@(private)
h2_settle :: proc(task: ^Connection_Task) {
	session := task.http2
	if session == nil || !session.engine_ready || session.failed do return
	for _ in 0 ..< H2_STREAM_SLOTS {
		h2_pump_events(task)
		h2_pump_engine(task)
		if session.failed do return
		kept := 0
		released := false
		for index in 0 ..< session.reap_count {
			handle := session.reap[index]
			error := h2.connection_reap(&session.engine, handle)
			if error.kind == .Invalid_State {
				session.reap[kept] = handle
				kept += 1
				continue
			}
			released = true
		}
		session.reap_count = kept
		if !released do return
	}
}

@(private)
h2_finish_request :: proc(task: ^Connection_Task, success: bool) {
	session := task.http2
	if session == nil do return
	if session.response_ready {
		discard_response(&session.response)
		session.response_ready = false
	}
	owned.destroy(&session.chunk)
	session.headers_sent = false
	session.body_sent = 0
	session.request_open = false
	session.receiving = false
	session.needs_reset = false
	session.have_length = false
	session.discard_input = false
	h2_remember(session, session.handle)
	session.handle = {}
	session.body_len = 0
	session.response_deadline = {}
	if success do task.response_finished = true
	task.requests_completed += 1
	finish_request_context(task)
	observe_finish(task)
	task.request = {}
	task.header = nil
	task.output = {}
	task.header_used, task.body_used = 0, 0
	mem.dynamic_arena_destroy(&task.arena)
	finish_operation_resources(task)
	if !start_operation_resources(task) {
		session.failed = true
		return
	}
	init_connection_arena(task)
	session.idle_deadline = time.tick_add(time.tick_now(), task.runtime.timeouts.idle)
}

@(private)
h2_lower_name :: proc(session: ^HTTP2_Session, name: string) -> string {
	start := session.name_used
	for index in 0 ..< len(name) {
		if session.name_used >= len(session.names) do return ""
		byte := name[index]
		if byte >= 'A' && byte <= 'Z' do byte += 32
		session.names[session.name_used] = byte
		session.name_used += 1
	}
	return string(session.names[start:session.name_used])
}

@(private)
h2_skip_response_header :: proc(name: string) -> bool {
	switch name {
	case "connection", "proxy-connection", "keep-alive", "upgrade", "transfer-encoding", "te", "content-length":
		return true
	}
	return len(name) > 0 && name[0] == ':'
}

@(private)
h2_submit_response :: proc(task: ^Connection_Task) -> bool {
	session := task.http2
	if session == nil || !session.response_ready || session.failed do return false
	progress := false
	code := int(session.response.status)
	if code == 0 do code = 200
	send_body := http.response_body_allowed(code, task.request.method) && len(session.response.body) > 0
	if !session.headers_sent {
		session.name_used = 0
		fields: [H2_FIELD_CAP]hpack.Field
		status_text: [3]u8
		status_text[0] = u8('0' + code / 100)
		status_text[1] = u8('0' + (code / 10) % 10)
		status_text[2] = u8('0' + code % 10)
		count := 0
		fields[count] = {":status", string(status_text[:]), false}
		count += 1
		for header in session.response.headers {
			if count + 1 >= len(fields) do break
			lowered := h2_lower_name(session, header.name)
			if lowered == "" || h2_skip_response_header(lowered) do continue
			fields[count] = {lowered, header.value, false}
			count += 1
		}
		length_text: [32]u8
		if send_body || task.request.method == "HEAD" {
			fields[count] = {"content-length", fmt.bprintf(length_text[:], "%d", len(session.response.body)), false}
			count += 1
		}
		error := h2.connection_send_headers(&session.engine, session.handle, fields[:count], !send_body)
		if error.kind == .Limit_Exceeded do return progress
		if error.kind != .None {
			session.failed = true
			return progress
		}
		session.headers_sent = true
		progress = true
		if !send_body {
			close_connection := session.response.close_connection
			h2_finish_request(task, true)
			if close_connection || server_is_draining(task.runtime) do h2_shutdown(task)
			return true
		}
	}
	for session.body_sent < len(session.response.body) {
		if len(session.chunk.storage) == 0 {
			amount := min(H2_FRAME_BYTES, len(session.response.body) - session.body_sent)
			chunk, alloc := owned.allocate(amount, session.allocator)
			if alloc.kind != .None {
				session.failed = true
				return progress
			}
			copy(chunk.data, session.response.body[session.body_sent:][:amount])
			session.chunk = chunk
		}
		amount := len(session.chunk.data)
		end := session.body_sent + amount == len(session.response.body)
		error := h2.connection_send_data(&session.engine, session.handle, &session.chunk, end)
		if error.kind == .Limit_Exceeded do return progress
		if error.kind != .None {
			owned.destroy(&session.chunk)
			session.failed = true
			return progress
		}
		session.body_sent += amount
		progress = true
		if end {
			close_connection := session.response.close_connection
			h2_finish_request(task, true)
			if close_connection || server_is_draining(task.runtime) do h2_shutdown(task)
			return true
		}
	}
	return progress
}

@(private)
h2_clone :: proc(value: string, allocator: mem.Allocator) -> (string, bool) {
	if len(value) == 0 do return "", true
	copy, error := strings.clone(value, allocator)
	return copy, error == nil
}

@(private)
h2_open_request :: proc(task: ^Connection_Task, summary: h2.Header_Summary, end_stream: bool) -> bool {
	session := task.http2
	if task.observation_finished {
		task.observed = false
		task.observation_finished = false
		task.response_finished = false
		task.event = {}
		observe_start(task)
	}
	allocator := mem.dynamic_arena_allocator(&task.arena)
	method, method_ok := h2_clone(summary.method, allocator)
	path_raw, path_ok := h2_clone(summary.path, allocator)
	authority, authority_ok := h2_clone(summary.authority, allocator)
	if !method_ok || !path_ok || !authority_ok {
		session.failed = true
		return false
	}
	path, query := path_raw, ""
	if mark := strings.index(path, "?"); mark >= 0 {
		query = path[mark + 1:]
		path = path[:mark]
	}
	regular := 0
	has_host := false
	for field in summary.fields {
		if len(field.name) == 0 || field.name[0] == ':' do continue
		if strings.equal_fold(field.name, "host") do has_host = true
		regular += 1
	}
	if !has_host && authority != "" do regular += 1
	if regular > REQUEST_HEADER_COUNT_LIMIT {
		observe_failure(task, .Protocol_Error)
		return false
	}
	headers, header_error := make([]Header, regular, allocator)
	if header_error != nil {
		session.failed = true
		return false
	}
	index := 0
	for field in summary.fields {
		if len(field.name) == 0 || field.name[0] == ':' do continue
		name, name_ok := h2_clone(field.name, allocator)
		value, value_ok := h2_clone(field.value, allocator)
		if !name_ok || !value_ok {
			session.failed = true
			return false
		}
		headers[index] = {name, value}
		index += 1
	}
	if !has_host && authority != "" {
		headers[index] = {"host", authority}
		index += 1
	}
	limit := REQUEST_BODY_LIMIT
	request := Request{
		resources = task.resource_operation,
		backing_allocator = connection_storage_allocator(task),
		allocator = allocator,
		method = method,
		path = path,
		query = query,
		version = "HTTP/2",
		headers = headers[:index],
		request_id = task.event.request_id,
		_observe = task.observed,
	}
	task.request = request
	if task.runtime.config.request_body_limit != nil {
		limit = task.runtime.config.request_body_limit(&task.request)
	}
	if limit < 0 {
		observe_failure(task, .Protocol_Error)
		return false
	}
	expected := 0
	have_length := false
	if length, present := summary.content_length.?; present {
		if length > u64(max(int)) || int(length) > limit {
			observe_failure(task, .Protocol_Error)
			return false
		}
		expected = int(length)
		have_length = true
	}
	capacity := expected if have_length else limit
	if !end_stream || (have_length && expected > 0) {
		body, body_error := make([]u8, capacity, allocator)
		if body_error != nil {
			session.failed = true
			return false
		}
		task.request.body = body
	}
	task.request.has_content_length = have_length
	task.request.content_length = expected
	session.have_length = have_length
	session.expected = expected
	session.limit = capacity
	session.body_len = 0
	session.request_open = true
	session.receiving = !end_stream
	duration := body_timeout(task.runtime.timeouts, expected if have_length else 0)
	session.body_deadline = time.tick_add(time.tick_now(), duration)
	if task.observed do task.event.method = method
	if end_stream do h2_complete_request(task)
	return true
}

@(private)
h2_complete_request :: proc(task: ^Connection_Task) {
	session := task.http2
	if session == nil || session.response_ready || session.failed do return
	session.receiving = false
	if session.have_length && session.body_len != session.expected {
		observe_failure(task, .Protocol_Error)
		if !queue_response(task, {status = .Bad_Request, close_connection = true}) {
			session.failed = true
		}
		return
	}
	if task.request.body != nil {
		task.request.body = task.request.body[:session.body_len]
	}
	task.request.content_length = session.body_len
	if task.runtime.config.handler == nil {
		session.failed = true
		return
	}
	response := dispatch_request(task)
	if !queue_response(task, response) do session.failed = true
}

@(private)
h2_append_body :: proc(task: ^Connection_Task, view: []u8) -> bool {
	session := task.http2
	if session.body_len > session.limit || len(view) > session.limit - session.body_len do return false
	if len(view) > 0 {
		if task.request.body == nil do return false
		copy(task.request.body[session.body_len:], view)
		session.body_len += len(view)
		if task.observed do task.event.bytes_received += u64(len(view))
	}
	if session.have_length && session.body_len > session.expected do return false
	return true
}

@(private)
h2_on_data :: proc(task: ^Connection_Task, event: h2.Event_View, value: h2.Data_Event) -> bool {
	session := task.http2
	if !session.request_open || value.stream != session.handle {
		return false
	}
	owner: h2.Incoming_Data
	if h2.connection_data_take(&session.engine, event.token, &owner).kind != .None do return false
	view, ok := h2.incoming_data_bytes(&owner)
	if !ok do view = nil
	accepted := !session.discard_input && session.receiving && h2_append_body(task, view)
	if len(view) == 0 || !accepted {
		_ = h2.connection_discard(&session.engine, value.consumption)
	} else {
		_ = h2.connection_consume(&session.engine, value.consumption, u32(len(view)))
	}
	h2.incoming_data_destroy(&owner)
	if !accepted && session.receiving {
		observe_failure(task, .Protocol_Error)
		session.receiving = false
		session.discard_input = true
		if !queue_response(task, {status = .Content_Too_Large, close_connection = true}) {
			_ = h2_reset_stream(task, .Cancel)
			h2_finish_request(task, false)
		}
		return true
	}
	if value.end_stream && session.receiving do h2_complete_request(task)
	return true
}

@(private)
h2_pump_events :: proc(task: ^Connection_Task) -> bool {
	session := task.http2
	progress := false
	for _ in 0 ..< H2_EVENTS {
		event, ok := h2.connection_poll(&session.engine)
		if !ok do break
		progress = true
		taken := false
		switch value in event.payload {
		case h2.Ready_Event, h2.Peer_Settings_Event, h2.Ping_Ack_Event:
		case h2.Headers_Event:
			if value.kind == .Trailers {
				if session.request_open && value.stream == session.handle && session.receiving {
					h2_complete_request(task)
				}
			} else if value.kind == .Request {
				if session.request_open || session.response_ready || server_is_draining(task.runtime) || session.shutdown || session.needs_reset {
					_ = h2.connection_reset(&session.engine, value.stream, .Refused_Stream)
					h2_remember(session, value.stream)
				} else {
					session.handle = value.stream
					session.request_open = true
					if !h2_open_request(task, value.summary, value.end_stream) {
						if h2_reset_stream(task, .Cancel) do h2_finish_request(task, false)
					}
				}
			}
		case h2.Data_Event:
			taken = h2_on_data(task, event, value)
		case h2.Stream_End_Event:
			if session.request_open && value.stream == session.handle && session.receiving {
				h2_complete_request(task)
			}
		case h2.Reset_Event:
			h2_remember(session, value.stream)
			if session.request_open && value.stream == session.handle {
				session.request_open = false
				session.receiving = false
				observe_failure(task, .Cancelled)
				h2_finish_request(task, false)
			}
		case h2.Promise_Event:
			// promise_policy is Decline. Releasing the event is enough.
		case h2.Goaway_Event:
			session.peer_gone = value.code != .No_Error
			h2_shutdown(task)
		case h2.Terminal_Event:
			session.failed = true
		case h2.Not_Processed_Event:
			h2_remember(session, value.stream)
		}
		if !taken {
			_ = h2.connection_event_release(&session.engine, event.token)
		}
	}
	return progress
}

@(private)
h2_wait_budget :: proc(task: ^Connection_Task) -> time.Duration {
	session := task.http2
	deadline := session.idle_deadline
	if session.receiving do deadline = session.body_deadline
	if session.response_ready do deadline = session.response_deadline
	if deadline == {} do return task.runtime.timeouts.header
	remaining := time.tick_diff(time.tick_now(), deadline)
	if remaining < 0 do return 0
	return remaining
}

@(private)
h2_check_deadlines :: proc(task: ^Connection_Task) -> bool {
	session := task.http2
	if session.receiving && deadline_expired(session.body_deadline) {
		observe_failure(task, .Timeout)
		if h2_reset_stream(task, .Cancel) {
			h2_finish_request(task, false)
			return true
		}
	}
	if !session.request_open && !session.response_ready && deadline_expired(session.idle_deadline) {
		h2_shutdown(task)
		return true
	}
	if server_is_draining(task.runtime) {
		h2_shutdown(task)
	}
	return false
}

@(private)
h2_read :: proc(task: ^Connection_Task) -> (bool, bool) {
	session := task.http2
	if session.failed || session.peer_gone do return false, false
	if session.ingress_len == len(session.ingress) do return false, false
	task.deadline = async.deadline_after(&task.runtime.executor, h2_wait_budget(task))
	n, error := transport_read(task, session.ingress[session.ingress_len:], task.deadline)
	if n > 0 {
		session.ingress_len += n
		session.idle_deadline = time.tick_add(time.tick_now(), task.runtime.timeouts.idle)
	}
	if error.kind == .Pending do return n > 0, true
	if error.kind == .Timeout {
		if task.tls_state != nil && task.tls_state.error.kind == .Timeout do task.tls_state.error = {}
		return n > 0, false
	}
	if error.kind != .None || (error.kind == .None && n == 0) {
		session.peer_gone = true
	}
	return n > 0, false
}

@(private)
h2_feed :: proc(task: ^Connection_Task) -> bool {
	session := task.http2
	if !session.engine_ready do return false
	progress := false
	source := session.ingress[:session.ingress_len] if !session.failed else nil
	fed := h2.connection_feed(&session.engine, source, u32(session.limits.work_per_feed))
	if fed.consumed > 0 {
		remain := session.ingress_len - fed.consumed
		for index in 0 ..< remain {
			session.ingress[index] = session.ingress[fed.consumed + index]
		}
		session.ingress_len = remain
		progress = true
	}
	if fed.error.kind != .None && h2_connection_fatal(fed.error.kind) {
		session.failed = true
		session.ingress_len = 0
	}
	if fed.work_used > 0 do progress = true
	return progress
}

@(private)
h2_output_pending :: proc(session: ^HTTP2_Session) -> bool {
	stats, ok := h2.connection_stats(&session.engine)
	return ok && (stats.output_count > 0 || stats.output_borrowed)
}

@(private)
h2_write :: proc(task: ^Connection_Task) -> (bool, bool) {
	session := task.http2
	state := task.tls_state
	if state == nil do return false, false
	task.deadline = async.deadline_after(&task.runtime.executor, h2_wait_budget(task))
	if state.write_started {
		n, error := transport_write(task, nil, task.deadline)
		if error.kind == .Pending do return false, true
		view, borrowed := h2.connection_output_front(&session.engine)
		if borrowed {
			if error.kind == .None && n > 0 {
				if h2.connection_output_advance(&session.engine, view.token, n).kind != .None {
					session.failed = true
				} else if task.observed do task.event.bytes_sent += u64(n)
			} else {
				_ = h2.connection_output_release(&session.engine, view.token)
				session.peer_gone = true
			}
		}
		return n > 0, false
	}
	if !h2_output_pending(session) do return false, false
	view, borrowed := h2.connection_output_front(&session.engine)
	if !borrowed do return false, false
	n, error := transport_write(task, view.bytes, task.deadline)
	if error.kind == .Pending do return false, true
	if error.kind != .None || n <= 0 {
		_ = h2.connection_output_release(&session.engine, view.token)
		session.peer_gone = true
		return false, false
	}
	if h2.connection_output_advance(&session.engine, view.token, n).kind != .None {
		session.failed = true
	} else if task.observed do task.event.bytes_sent += u64(n)
	return true, false
}

@(private)
h2_pump_engine :: proc(task: ^Connection_Task) {
	session := task.http2
	work := u32(session.limits.work_per_feed)
	for _ in 0 ..< 4 {
		_ = h2.connection_feed(&session.engine, nil, work)
		flushed := h2.connection_flush(&session.engine, work)
		life := h2.connection_lifecycle(&session.engine, 32)
		if h2_connection_fatal(flushed.error.kind) do session.failed = true
		if h2_connection_fatal(life.error.kind) do session.failed = true
		if session.failed do break
	}
}

@(private)
h2_connection_fatal :: proc(kind: h2.Error_Kind) -> bool {
	switch kind {
	case .None, .Limit_Exceeded, .Allocation_Failed, .Budget_Rejected, .Closed:
		return false
	case .Invalid_Config, .Invalid_State, .Invalid_Input, .Destination_Undersized, .Overlapping_Buffers, .Protocol_Violation:
		return true
	}
	return true
}

@(private)
h2_finished :: proc(task: ^Connection_Task) -> bool {
	session := task.http2
	if session == nil || !session.engine_ready do return true
	pending := h2_output_pending(session)
	writing := task.tls_state != nil && task.tls_state.write_started
	if pending || writing do return false
	if session.failed || session.peer_gone do return true
	if !session.shutdown do return false
	stats, ok := h2.connection_shutdown_status(&session.engine)
	if !ok do return false
	return stats.phase == .Draining || stats.phase == .Complete || stats.phase == .Aborted || stats.phase == .Final
}

@(private)
h2_step :: proc(task: ^Connection_Task) -> async.Resume_Result {
	session := task.http2
	if session == nil || !session.engine_ready do return .Done
	if async.cancelled(&task.task) {
		if !session.failed do _ = h2.connection_abort(&session.engine, {kind = .Closed})
		return .Done
	}
	if session.needs_reset && h2_reset_stream(task, .Cancel) && !session.response_ready {
		h2_finish_request(task, false)
	}
	waiting := false
	for _ in 0 ..< 8 {
		progress := false
		h2_settle(task)
		if h2_check_deadlines(task) do progress = true
		read_progress, read_wait := h2_read(task)
		if read_progress do progress = true
		if read_wait do waiting = true
		if h2_feed(task) do progress = true
		if h2_pump_events(task) do progress = true
		if h2_submit_response(task) do progress = true
		h2_pump_engine(task)
		if h2_pump_events(task) do progress = true
		write_progress, write_wait := h2_write(task)
		if write_progress do progress = true
		if write_wait do waiting = true
		if h2_finished(task) do return .Done
		if progress do continue
		if waiting do return .Waiting
		break
	}
	if h2_finished(task) do return .Done
	if waiting do return .Waiting
	return .Yield
}
