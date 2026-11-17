package saba_websocket

import "core:time"
import core "../core"
import codec "../../websocket"
import "core:mem"
import charged "core:mem/budget"
import budget "core:sync/budget"
import async "../../async"
import "core:unicode/utf8"
import rt "base:runtime"
import "core:strings"

DEFAULT_FRAME_BYTES :: 64 << 10
DEFAULT_MESSAGE_BYTES :: 1 << 20
MAX_MESSAGE_BYTES :: 64 << 20
MAX_OUTPUT_CAPACITY :: 1024
MAX_SUBPROTOCOLS :: 32

config_normalize :: proc(config: Config) -> (Config, Error) {
	result := config
	if result.max_frame_bytes == 0 {
		result.max_frame_bytes = DEFAULT_FRAME_BYTES
	}
	if result.max_message_bytes == 0 {
		result.max_message_bytes = DEFAULT_MESSAGE_BYTES
	}
	if result.max_output_bytes == 0 {
		result.max_output_bytes = DEFAULT_MESSAGE_BYTES
	}
	if result.output_capacity == 0 {
		result.output_capacity = 4
	}
	if result.max_fragments == 0 {
		result.max_fragments = 1024
	}
	if result.idle_timeout == 0 {
		result.idle_timeout = 60 * time.Second
	}
	if result.frame_timeout == 0 {
		result.frame_timeout = 5 * time.Second
	}
	if result.message_timeout == 0 {
		result.message_timeout = 30 * time.Second
	}
	if result.write_timeout == 0 {
		result.write_timeout = 5 * time.Second
	}
	if result.close_timeout == 0 {
		result.close_timeout = time.Second
	}
	if result.max_frame_bytes < 1 ||
	   result.max_frame_bytes > MAX_MESSAGE_BYTES ||
	   result.max_message_bytes < 1 ||
	   result.max_message_bytes > MAX_MESSAGE_BYTES ||
	   result.max_output_bytes < 1 ||
	   result.max_output_bytes > MAX_MESSAGE_BYTES ||
	   result.output_capacity < 1 ||
	   result.output_capacity > MAX_OUTPUT_CAPACITY ||
	   result.max_fragments < 1 ||
	   result.max_fragments > 65536 {
		return {}, {kind = .Invalid_Config}
	}

	for duration in ([5]time.Duration {
			result.idle_timeout,
			result.frame_timeout,
			result.message_timeout,
			result.write_timeout,
			result.close_timeout,
		}) {
		if duration <= 0 || duration > 24 * time.Hour {
			return {}, {kind = .Invalid_Config}
		}
	}

	return result, {}
}

new_session :: proc(
	scope: budget.Scope,
	config: Config,
	app: Application,
	backing: mem.Allocator,
) -> (
	^Session,
	Error,
) {
	resolved, validation := config_normalize(config)
	if validation.kind != .None {
		return nil, validation
	}
	if !scope_managed(scope) {
		return nil, {kind = .Invalid_Context}
	}
	binding, binding_error := charged.create(scope, {backing = backing})
	if binding_error.kind != .None {
		return nil, {kind = .Budget_Rejected, budget = binding_error.budget, allocation = binding_error.allocation}
	}
	allocator := charged.allocator(binding)
	session, allocation := new(Session, allocator)
	if allocation != nil {
		charged.release(&binding)
		return nil, {kind = .Allocation_Failed, allocation = allocation}
	}
	resolved.check_origin, resolved.select_subprotocol, resolved.policy_data = nil, nil, nil
	session^ = {
		config = resolved,
		app = app,
		binding = binding,
		allocator = allocator,
		header_expected = 2,
		event = {reason = .Owner_Stopped},
	}
	outputs, error := make([]Output, resolved.output_capacity, allocator)
	if error != nil {
		drop_session(session)
		return nil, {kind = .Allocation_Failed, allocation = error}
	}
	session.outputs = outputs
	return session, {}
}

clear_outputs :: proc(session: ^Session) {
	for &output in session.outputs {
		delete(output.payload, session.allocator)
		output = {}
	}

	session.output_head, session.output_count = 0, 0
	session.metrics.queued_bytes, session.metrics.queued_messages = 0, 0
}

drop_session :: proc(data: rawptr) {
	session := cast(^Session)data
	if session == nil {
		return
	}
	app, owned := session.app, session.owns_app
	session.owns_app, session.dropped = false, true
	clear_outputs(session)
	codec.message_release(&session.message)
	delete(session.frame_wire, session.allocator)
	delete(session.outputs, session.allocator)
	delete(session.protocol, session.allocator)
	event := session.event
	event.clean =
		session.close_sent &&
		session.peer_closed &&
		event.transport.kind == .None &&
		event.frame == .None &&
		event.message.kind == .None &&
		event.reason != .Protocol_Error &&
		event.reason != .Timeout &&
		event.reason != .IO_Error
	event.stats = session.metrics
	event.stats.message_capacity = 0
	if !session.opened {
		event.reason = .Not_Opened
	}
	else if event.reason == .Owner_Stopped && core.request_server_stopping(session.request_context) {
		event.reason = .Shutdown
	}

	core.release_request_context(&session.request_context)
	binding, allocator := session.binding, session.allocator
	mem.zero(session, size_of(Session))
	free(session, allocator)
	charged.release(&binding)

	if owned {
		if app.on_close != nil {
			app.on_close(app.data, &event)
		}
		if app.drop != nil {
			app.drop(app.data)
		}
	}
}

reset_read :: proc(session: ^Session, io: ^IO) {
	session.header_used, session.header_expected, session.payload_used = 0, 2, 0
	session.reading_payload, session.payload = false, nil
	session.read_deadline = async.deadline_after(io._transport.runtime, session.config.idle_timeout)

	if session.message_deadline.epoch != 0 && session.message_deadline.at < session.read_deadline.at {
		session.read_deadline = session.message_deadline
	}
}

protocol_close :: proc(session: ^Session, code: u16, reason: Close_Reason) {
	payload := [2]u8{u8(code >> 8), u8(code & 255)}
	request_close(session, payload[:], reason, true)
}

accept_header :: proc(session: ^Session, io: ^IO) -> Step {
	header, _, error := codec.frame_header_decode(session.input_header[:session.header_used], true)

	if error != .None {
		session.event.frame = error
		protocol_close(session, 1002, .Protocol_Error)
		return .Progress
	}

	if header.payload_length > u64(session.config.max_frame_bytes) {
		protocol_close(session, 1009, .Protocol_Error)
		return .Progress
	}

	session.header = header

	if u8(header.opcode) >= 8 {
		session.payload = session.control_input[:int(header.payload_length)]
	} else {
		if session.close_requested {
			return .Done
		}

		if session.fragments == session.config.max_fragments {
			protocol_close(session, 1009, .Protocol_Error)
			return .Progress
		}

		session.fragments += 1

		if session.message_deadline.epoch == 0 {
			session.message_deadline = async.deadline_after(io._transport.runtime, session.config.message_timeout)
		}

		payload, allocation := codec.message_prepare(
			&session.message,
			header,
			session.config.max_message_bytes,
			session.allocator,
		)

		if allocation.kind != .None {
			session.event.message = allocation
			code := u16(1002)
			if allocation.kind == .Message_Oversized {
				code = 1009
			}
			if allocation.kind == .Allocation_Failed {
				code = 1011
			}
			protocol_close(session, code, .Protocol_Error)
			return .Progress
		}

		session.payload = payload
		session.metrics.peak_message_bytes = max(session.metrics.peak_message_bytes, len(session.message.message))
	}

	session.reading_payload, session.payload_used = true, 0

	return .Progress
}

finish_frame :: proc(session: ^Session, io: ^IO) -> Step {
	session.metrics.frames_in += 1
	opcode := session.header.opcode

	if opcode == .Close {
		error := codec.close_payload_validate(session.payload)

		if error != .None {
			session.event.frame = error
			protocol_close(session, 1007 if error == .Invalid_UTF8 else 1002, .Protocol_Error)
			return .Progress
		}

		session.peer_closed = true
		if len(session.payload) >= 2 {
			session.event.peer_code = u16(session.payload[0]) << 8 | u16(session.payload[1])
		}
		request_close(session, session.payload, .Peer_Close, false)
	} else if opcode == .Ping {
		if !session.close_requested {
			count, error := codec.frame_encode(session.control[:], true, .Pong, session.payload, {}, false)
			assert(error == .None)
			session.control_used, session.control_sent, session.control_close = count, 0, false
			session.control_deadline = async.deadline_after(io._transport.runtime, session.config.write_timeout)
		}
	} else if opcode != .Pong {
		error := codec.message_finish(&session.message, session.header.fin)

		if error.kind != .None {
			session.event.message = error
			protocol_close(session, 1007, .Protocol_Error)
			return .Progress
		}

		if session.message.message_ready {
			session.metrics.messages_in += 1

			if session.app.on_message != nil {
				session.app.on_message(
					session.app.data,
					io,
					session.message.message_opcode,
					session.message.message[:],
				)
			}

			_, _, delivered := codec.message_deliver(&session.message, session.message.message[:])
			assert(delivered.kind == .None)
			session.fragments, session.message_deadline = 0, {}
		}
	}

	reset_read(session, io)

	return .Progress
}

read_step :: proc(session: ^Session, io: ^IO) -> Step {
	if session.reading_payload && session.payload_used == len(session.payload) {
		return finish_frame(session, io)
	}

	if !session.reading_payload && session.header_used == session.header_expected {
		if session.header_used == 2 {
			// A masked two-byte prefix is never a whole header, so anything other
			// than Header_Incomplete is a real prefix violation.
			_, _, error := codec.frame_header_decode(session.input_header[:2], true)

			if error != .Header_Incomplete {
				session.event.frame = error
				protocol_close(session, 1002, .Protocol_Error)
				return .Progress
			}

			length := session.input_header[1] & 127
			session.header_expected = 6
			if length == 126 {
				session.header_expected += 2
			}
			if length == 127 {
				session.header_expected += 8
			}
		} else {
			return accept_header(session, io)
		}
	}

	deadline := session.read_deadline
	if session.message_deadline.epoch != 0 && session.message_deadline.at < deadline.at {
		deadline = session.message_deadline
	}
	if session.close_requested && session.close_deadline.at < deadline.at {
		deadline = session.close_deadline
	}
	now := async.deadline_after(io._transport.runtime, 0)
	io._transport.connection.read_deadline = time.tick_add(
		time.tick_now(),
		time.Duration(max(i64(0), deadline.at - now.at)),
	)
	destination := session.input_header[session.header_used:session.header_expected]

	if session.reading_payload {
		destination = session.payload[session.payload_used:min(session.payload_used + 16 * 1024, len(session.payload))]
	}

	n, error := core.upgrade_read(io._transport, destination, deadline)
	if error.kind == .Pending {
		return .Waiting
	}

	if error.kind != .None || n == 0 {
		if session.event.transport.kind == .None {
			session.event.transport = error
		}

		if error.kind == .Timeout {
			protocol_close(session, 1001, .Timeout)
			return .Progress
		}

		if session.event.reason == .Owner_Stopped {
			session.event.reason = .Peer_EOF if error.kind == .None || error.kind == .Peer_Closed else .IO_Error
		}

		return .Done
	}

	if session.reading_payload {
		codec.mask_payload(destination[:n], session.header.masking_key, u64(session.payload_used))
		session.payload_used += n
	} else {
		if session.header_used == 0 {
			session.read_deadline = async.deadline_after(io._transport.runtime, session.config.frame_timeout)
		}

		session.header_used += n
	}

	return .Progress
}

valid_io :: proc(io: ^IO) -> bool {
	return io != nil && io._active && io._session != nil && io._session.opened && !io._session.dropped
}

// Copies the complete message before returning. Rejection never retains payload.
// Frames are generated serially; a large message is fragmented at max_frame_bytes.
send :: proc(io: ^IO, opcode: codec.Opcode, payload: []u8) -> Send_Result {
	if !valid_io(io) {
		return .Closed
	}
	session := io._session
	if session.close_requested {
		return .Closed
	}
	if opcode != .Text && opcode != .Binary {
		return .Invalid
	}

	if len(payload) > session.config.max_message_bytes || len(payload) > session.config.max_output_bytes {
		return .Limit_Exceeded
	}

	if opcode == .Text && !utf8.valid_string(string(payload)) {
		return .Invalid
	}
	if session.output_count == len(session.outputs) ||
	   len(payload) > session.config.max_output_bytes - session.metrics.queued_bytes {
		session.writable_wanted = true
		return .Backpressure
	}

	storage, error := make([]u8, len(payload), session.allocator)
	if error != nil {
		return .Allocation_Failed
	}
	copy(storage, payload)
	index := (session.output_head + session.output_count) % len(session.outputs)
	session.outputs[index] = {
		opcode  = opcode,
		payload = storage,
	}

	session.output_count += 1
	metrics := &session.metrics
	metrics.queued_bytes += len(storage)
	metrics.queued_messages = session.output_count
	metrics.peak_output_bytes = max(metrics.peak_output_bytes, metrics.queued_bytes)
	metrics.peak_output_messages = max(metrics.peak_output_messages, metrics.queued_messages)

	return .Accepted
}

close :: proc(io: ^IO, code: u16, reason: string) -> Error {
	if !valid_io(io) {
		return {kind = .Invalid_Context}
	}
	if len(reason) > 123 {
		return {kind = .Invalid_Close}
	}
	payload: [125]u8
	payload[0], payload[1] = u8(code >> 8), u8(code & 255)
	copy(payload[2:], reason)
	if codec.close_payload_validate(payload[:2 + len(reason)]) != .None {
		return {kind = .Invalid_Close}
	}
	session := io._session
	if session.close_requested {
		return {}
	}
	request_close(session, payload[:2 + len(reason)], .Application_Close, false)

	return {}
}

subprotocol :: proc(io: ^IO) -> string {
	if !valid_io(io) {
		return ""
	}

	return io._session.protocol
}
stats :: proc(io: ^IO) -> Stats {
	if !valid_io(io) {
		return {}
	}
	result := io._session.metrics
	result.message_capacity = cap(io._session.message.message)

	return result
}

request_close :: proc(session: ^Session, payload: []u8, reason: Close_Reason, abort: bool) {
	if session.close_requested {
		// Escalate termination without replacing close bytes already in flight.
		if abort {
			session.abort_after_close = true
		}
		return
	}

	session.close_requested, session.abort_after_close = true, abort
	session.close_size = copy(session.close_payload[:], payload)
	session.event.reason = reason
	if len(payload) >= 2 {
		session.event.code = u16(payload[0]) << 8 | u16(payload[1])
	}
}

SESSION_WORK_LIMIT :: 32

semantic_deadline :: proc(session: ^Session) -> async.Deadline {
	result := session.read_deadline

	for deadline in ([3]async.Deadline {
			session.message_deadline,
			session.control_deadline if session.control_used > 0 else async.Deadline{},
			session.close_deadline if session.close_requested else async.Deadline{},
		}) {
		if deadline.epoch != 0 && (result.epoch == 0 || deadline.at < result.at) {
			result = deadline
		}
	}

	if session.output_count > 0 {
		deadline := session.outputs[session.output_head].deadline
		if deadline.epoch != 0 && (result.epoch == 0 || deadline.at < result.at) {
			result = deadline
		}
	}

	return result
}

// A semantic cutoff cannot wait behind an accepted outbound write. Returning
// Done leaves its stable buffers untouched until Core drains the I/O callbacks.
session_budget_expired :: proc(session: ^Session, runtime: ^async.Runtime) -> bool {
	deadline := semantic_deadline(session)
	if deadline.epoch == 0 || async.deadline_after(runtime, 0).at < deadline.at {
		return false
	}

	if session.event.transport.kind == .None {
		session.event.transport = {
			kind = .Timeout,
		}
	}

	if session.event.reason == .Owner_Stopped {
		session.event.reason = .Timeout
	}

	return true
}

wait_session :: proc(session: ^Session, io: ^IO, read, write: bool) -> async.Resume_Result {
	transport := io._transport
	deadline := semantic_deadline(session)

	if transport.stream_wait != nil {
		error := transport.stream_wait(transport.stream_data, read, write, deadline)
		if error.kind == .None || error.kind == .Timeout {
			return .Yield
		}

		if error.kind != .Pending {
			session.event.transport = error
			session.event.reason = .IO_Error
			return .Done
		}

		return .Waiting
	}

	if transport.socket != (async.Socket{}) && (read || write) {
		// Individual native read/write calls replace the socket interest. Restore
		// both directions explicitly after attempting them, then recheck budgets.
		error := async.wait_stream(transport.socket, read, write, deadline)
		if error.kind == .None || error.kind == .Timeout {
			return .Yield
		}

		if error.kind != .Pending {
			record_io_failure(session, error)
			return .Done
		}
	}

	if deadline.epoch != 0 {
		error := async.sleep_until_earlier(transport.runtime, deadline)
		if error.kind == .None {
			return .Yield
		}
		if error.kind != .Pending {
			return .Done
		}
	}

	return .Waiting
}

resume_session :: proc(data: rawptr, transport: ^core.Upgrade_IO) -> async.Resume_Result {
	session := cast(^Session)data
	io := IO {
		_session   = session,
		_transport = transport,
		_active    = true,
	}

	defer {
		io._active = false
	}

	if !session.opened {
		session.opened = true
		reset_read(session, &io)
		if session.app.on_open != nil {
			session.app.on_open(session.app.data, &io)
		}
	}

	for _ in 0 ..< SESSION_WORK_LIMIT {
		if core.request_server_stopping(session.request_context) {
			protocol_close(session, 1001, .Shutdown)
		}

		if session.close_requested && session.close_deadline.epoch == 0 {
			session.close_deadline = async.deadline_after(transport.runtime, session.config.close_timeout)
		}

		if session.close_sent && (session.peer_closed || session.abort_after_close) {
			return .Done
		}
		if session_budget_expired(session, transport.runtime) {
			return .Done
		}
		read := Step.Idle
		// Service input while output is blocked. A pending control response owns
		// its fixed slot, so pause input until it is written instead of overwriting.
		if session.control_used == 0 && (!session.close_requested || session.close_sent) {
			read = read_step(session, &io)
			if read == .Done {
				return .Done
			}
		}

		// Input policy/callbacks may have requested close during this step.
		if session.close_requested && session.close_deadline.epoch == 0 {
			session.close_deadline = async.deadline_after(transport.runtime, session.config.close_timeout)
		}

		write := write_step(session, &io)
		if write == .Done {
			return .Done
		}
		if session.close_sent && (session.peer_closed || session.abort_after_close) {
			return .Done
		}

		if read != .Progress && write != .Progress {
			return wait_session(session, &io, read == .Waiting, write == .Waiting)
		}
	}

	return .Yield
}

Config :: struct {
	max_frame_bytes, max_message_bytes, max_output_bytes, output_capacity:      int,
	max_fragments:                                                              int,
	idle_timeout, frame_timeout, message_timeout, write_timeout, close_timeout: time.Duration,
	check_origin:                                                               proc(
		data: rawptr,
		request: ^core.Request,
		origin: string,
		present: bool,
	) -> bool,
	select_subprotocol:                                                         proc(
		data: rawptr,
		request: ^core.Request,
		offered: []string,
	) -> (
		string,
		bool,
	),
	policy_data:                                                                rawptr,
}
// All callbacks run serially on the existing task and must not block. IO and
// message bytes borrow only through callback return. data survives until drop.
Application :: struct {
	data:        rawptr,
	on_open:     proc(data: rawptr, io: ^IO),
	on_message:  proc(data: rawptr, io: ^IO, opcode: codec.Opcode, payload: []u8),
	on_writable: proc(data: rawptr, io: ^IO),
	on_close:    proc(data: rawptr, event: ^Close_Event),
	drop:        proc(data: rawptr),
}
Error_Kind :: enum {
	None,
	Invalid_Config,
	Invalid_Context,
	Invalid_Request,
	Origin_Rejected,
	Protocol_Rejected,
	Allocation_Failed,
	Budget_Rejected,
	Invalid_Close,
}
Error :: struct {
	kind:       Error_Kind,
	status:     core.HTTP_Status,
	allocation: mem.Allocator_Error,
	budget:     budget.Error,
	upgrade:    codec.Upgrade_Error,
}
Send_Result :: enum {
	Accepted,
	Backpressure,
	Closed,
	Invalid,
	Limit_Exceeded,
	Allocation_Failed,
}
Close_Reason :: enum {
	Not_Opened,
	Owner_Stopped,
	Shutdown,
	Peer_Close,
	Peer_EOF,
	Application_Close,
	Protocol_Error,
	Timeout,
	IO_Error,
}
Stats :: struct {
	frames_in, frames_out, messages_in, messages_out:                       u64,
	queued_bytes, peak_output_bytes, queued_messages, peak_output_messages: int,
	message_capacity, peak_message_bytes:                                   int,
}
Close_Event :: struct {
	clean:           bool,
	reason:          Close_Reason,
	code, peer_code: u16,
	transport:       async.Error,
	frame:           codec.Frame_Error,
	message:         codec.Message_Error,
	stats:           Stats,
}
// A call-scoped capability. Do not retain, copy for later use, or call concurrently.
IO :: struct {
	_session:   ^Session,
	_transport: ^core.Upgrade_IO,
	_active:    bool,
}

Output :: struct {
	opcode:   codec.Opcode,
	payload:  []u8,
	offset:   int,
	deadline: async.Deadline,
}
Session :: struct {
	config:                                                      Config,
	app:                                                         Application,
	allocator:                                                   mem.Allocator,
	binding:                                                     charged.Binding,
	request_context:                                             core.Request_Context,
	owns_app, opened, dropped, writable_wanted:                  bool,
	protocol:                                                    string,
	metrics:                                                     Stats,
	event:                                                       Close_Event,
	outputs:                                                     []Output,
	output_head, output_count:                                   int,
	frame_wire:                                                  []u8,
	frame_used, frame_sent:                                      int,
	frame_final:                                                 bool,
	control:                                                     [127]u8,
	control_used, control_sent:                                  int,
	control_close:                                               bool,
	close_requested, close_sent, peer_closed, abort_after_close: bool,
	close_payload:                                               [125]u8,
	close_size:                                                  int,
	close_deadline, control_deadline:                            async.Deadline,
	input_header:                                                [14]u8,
	header_used, header_expected:                                int,
	reading_payload:                                             bool,
	header:                                                      codec.Frame_Header,
	payload:                                                     []u8,
	payload_used:                                                int,
	control_input:                                               [125]u8,
	message:                                                     codec.Message_State,
	fragments:                                                   int,
	read_deadline, message_deadline:                             async.Deadline,
}

Upgrade_Fields :: struct {
	key, version, origin:                          string,
	origin_present, upgrade_seen, connection_seen: bool,
	offered:                                       [MAX_SUBPROTOCOLS]string,
	offered_count:                                 int,
}

// RFC 8441 / RFC 9220 Extended CONNECT carries no Upgrade handshake fields.
extended_connect :: proc(request: ^core.Request) -> bool {
	return(
		(request.version == "HTTP/2" || request.version == "HTTP/3") &&
		request.method == "CONNECT" &&
		request.protocol == "websocket" \
	)
}

request_fields :: proc(request: ^core.Request) -> (Upgrade_Fields, Error) {
	fields: Upgrade_Fields
	extended := request != nil && extended_connect(request)
	if request == nil ||
	   (!extended && (request.method != "GET" || request.version != "HTTP/1.1")) ||
	   len(request.headers) > core.REQUEST_HEADER_COUNT_LIMIT ||
	   request.content_length != 0 ||
	   request.chunked ||
	   len(request.body) != 0 {
		return {}, {kind = .Invalid_Request, status = .Bad_Request}
	}

	key_seen, version_seen, host_seen := false, false, false

	for header in request.headers {
		value := codec.upgrade_trim_ows(header.value)

		if strings.equal_fold(header.name, "Host") {
			if host_seen || !codec.upgrade_host_valid(value) {
				return {}, {kind = .Invalid_Request, status = .Bad_Request}
			}
			host_seen = true
		} else if strings.equal_fold(header.name, "Sec-WebSocket-Key") {
			if key_seen {
				return {}, {kind = .Invalid_Request, status = .Bad_Request}
			}
			fields.key, key_seen = value, true
		} else if strings.equal_fold(header.name, "Sec-WebSocket-Version") {
			if version_seen {
				return {}, {kind = .Invalid_Request, status = .Bad_Request}
			}
			fields.version, version_seen = value, true
		} else if strings.equal_fold(header.name, "Origin") {
			if fields.origin_present || value == "" || !codec.upgrade_origin_valid(value) {
				return {}, {kind = .Invalid_Request, status = .Bad_Request}
			}

			fields.origin, fields.origin_present = value, true
		} else if strings.equal_fold(header.name, "Upgrade") || strings.equal_fold(header.name, "Connection") {
			if extended {
				return {}, {kind = .Invalid_Request, status = .Bad_Request}
			}

			upgrade := strings.equal_fold(header.name, "Upgrade")
			wanted := "websocket" if upgrade else "upgrade"
			found, valid := codec.upgrade_list_contains(value, wanted, upgrade)
			if !valid {
				return {}, {kind = .Invalid_Request, status = .Bad_Request}
			}

			if upgrade {
				fields.upgrade_seen = fields.upgrade_seen || found
			} else {
				fields.connection_seen = fields.connection_seen || found
			}
		} else if strings.equal_fold(header.name, "Sec-WebSocket-Protocol") {
			remaining := value

			for token in strings.split_iterator(&remaining, ",") {
				if fields.offered_count == MAX_SUBPROTOCOLS {
					return {}, {kind = .Invalid_Request, status = .Bad_Request}
				}
				fields.offered[fields.offered_count] = codec.upgrade_trim_ows(token)
				fields.offered_count += 1
			}
		}
	}

	if extended {
		if !host_seen || fields.version != "13" || key_seen || fields.upgrade_seen || fields.connection_seen {
			return {}, {kind = .Invalid_Request, status = .Bad_Request}
		}
	} else if !host_seen ||
	   !fields.upgrade_seen ||
	   !fields.connection_seen ||
	   !codec.upgrade_request_fields_valid(fields.key, fields.version, "websocket", "upgrade") {
		return {}, {kind = .Invalid_Request, status = .Bad_Request}
	}

	if error := codec.upgrade_protocols_validate(fields.offered[:fields.offered_count]); error != .None {
		return {}, {kind = .Invalid_Request, status = .Bad_Request, upgrade = error}
	}

	return fields, {}
}

// Application ownership transfers only on success. Dispose an unused successful
// Response with core.discard_response; its drop remains exact if the handshake fails.
// Config hooks run only now; request headers and policy_data are not retained.
prepare_upgrade :: proc(request: ^core.Request, config: Config, app: Application) -> (core.Response, Error) {
	resolved, validation := config_normalize(config)

	if validation.kind != .None {
		validation.status = .Internal_Server_Error
		return {}, validation
	}

	fields, error := request_fields(request)
	if error.kind != .None {
		return {}, error
	}
	allowed := !fields.origin_present

	if resolved.check_origin != nil {
		allowed = resolved.check_origin(resolved.policy_data, request, fields.origin, fields.origin_present)
	}

	if !allowed {
		return {}, {kind = .Origin_Rejected, status = .Forbidden}
	}
	protocol := ""

	if resolved.select_subprotocol != nil {
		selected, accepted := resolved.select_subprotocol(
			resolved.policy_data,
			request,
			fields.offered[:fields.offered_count],
		)
		if !accepted {
			return {}, {kind = .Protocol_Rejected, status = .Bad_Request}
		}
		protocol = selected

		if selected != "" {
			found := false

			for offer in fields.offered[:fields.offered_count] {
				if selected == offer {
					found = true
				}
			}

			if !found || codec.upgrade_protocols_validate([]string{selected}) != .None {
				return {}, {kind = .Protocol_Rejected, status = .Bad_Request}
			}
		}
	}

	session, allocation := new_session(
		core.request_connection_resources(request.cancellation),
		resolved,
		app,
		rt.heap_allocator(),
	)

	if allocation.kind != .None {
		allocation.status = .Internal_Server_Error
		return {}, allocation
	}

	committed := false
	defer if !committed {
		drop_session(session)
	}
	retained, retained_ok := core.retain_request_context(request.cancellation)
	if !retained_ok {
		return {}, {kind = .Invalid_Context, status = .Internal_Server_Error}
	}
	session.request_context = retained

	if protocol != "" {
		copy, copy_error := strings.clone(protocol, session.allocator)
		if copy_error != nil {
			return {}, {kind = .Allocation_Failed, allocation = copy_error, status = .Internal_Server_Error}
		}
		session.protocol = copy
	}

	extended := extended_connect(request)
	headers: []core.Header
	status := core.HTTP_Status.Switching_Protocols

	if extended {
		status = .OK

		if protocol != "" {
			allocated, header_error := make([]core.Header, 1, request.allocator)
			if header_error != nil {
				return {}, {kind = .Allocation_Failed, allocation = header_error, status = .Internal_Server_Error}
			}
			headers = allocated
			headers[0] = {"sec-websocket-protocol", session.protocol}
		}
	} else {
		accept, accept_error := make([]u8, 28, request.allocator)
		if accept_error != nil {
			return {}, {kind = .Allocation_Failed, allocation = accept_error, status = .Internal_Server_Error}
		}
		accepted := codec.upgrade_accept_encoded(fields.key)
		copy(accept, accepted[:])
		count := 2
		if protocol != "" {
			count += 1
		}
		allocated_headers, headers_error := make([]core.Header, count, request.allocator)
		headers = allocated_headers
		if headers_error != nil {
			return {}, {kind = .Allocation_Failed, allocation = headers_error, status = .Internal_Server_Error}
		}
		headers[0], headers[1] = {"Upgrade", "websocket"}, {"Sec-WebSocket-Accept", string(accept)}
		if protocol != "" {
			headers[2] = {"Sec-WebSocket-Protocol", session.protocol}
		}
	}

	session.owns_app, committed = true, true

	return {
		status = status,
		headers = headers,
		upgrade = {data = session, resume = resume_session, drop = drop_session},
	}, {}
}

// On rejection the returned ordinary HTTP response carries the typed error's
// status; no Application ownership transfers. The caller still drops its data.
upgrade :: proc(request: ^core.Request, config: Config, app: Application) -> (core.Response, Error) {
	response, error := prepare_upgrade(request, config, app)

	if error.kind != .None {
		if error.status == .None {
			error.status = .Internal_Server_Error
		}
		return {status = error.status}, error
	}

	return response, {}
}

Step :: enum {
	Idle,
	Progress,
	Waiting,
	Done,
}

set_write_deadline :: proc(io: ^core.Upgrade_IO, deadline: async.Deadline) {
	now := async.deadline_after(io.runtime, 0)
	io.connection.write_deadline = time.tick_add(time.tick_now(), time.Duration(max(i64(0), deadline.at - now.at)))
}

// The first transport error and the first close reason win.
record_io_failure :: proc(session: ^Session, error: async.Error) {
	if error.kind != .None && session.event.transport.kind == .None {
		session.event.transport = error
	}
	if session.event.reason == .Owner_Stopped {
		session.event.reason = .IO_Error
	}
}

notify_writable :: proc(session: ^Session, io: ^IO) {
	if !session.writable_wanted || session.close_requested {
		return
	}
	session.writable_wanted = false
	if session.app.on_writable != nil {
		session.app.on_writable(session.app.data, io)
	}
}

finish_output :: proc(session: ^Session, io: ^IO) {
	index := session.output_head
	payload := session.outputs[index].payload
	session.outputs[index] = {}
	session.output_head = (index + 1) % len(session.outputs)
	session.output_count -= 1
	session.metrics.queued_bytes -= len(payload)
	session.metrics.queued_messages = session.output_count
	session.metrics.messages_out += 1
	delete(payload, session.allocator)
	notify_writable(session, io)
}

write_step :: proc(session: ^Session, io: ^IO) -> Step {
	transport := io._transport

	if session.frame_used > 0 {
		output := &session.outputs[session.output_head]
		deadline := output.deadline
		if session.close_requested && session.close_deadline.at < deadline.at {
			deadline = session.close_deadline
		}
		set_write_deadline(transport, deadline)
		n, error := core.upgrade_write(transport, session.frame_wire[session.frame_sent:session.frame_used], deadline)
		if error.kind == .Pending {
			return .Waiting
		}

		if error.kind != .None || n <= 0 {
			record_io_failure(session, error)
			return .Done
		}

		session.frame_sent += n
		if session.frame_sent != session.frame_used {
			return .Progress
		}
		session.metrics.frames_out += 1
		session.frame_used, session.frame_sent = 0, 0

		if session.frame_final {
			finish_output(session, io)
		}

		return .Progress
	}

	abandon := session.peer_closed || session.abort_after_close || session.event.reason == .Shutdown
	if session.close_requested &&
	   !session.close_sent &&
	   session.control_used == 0 &&
	   (abandon || session.output_count == 0) {
		clear_outputs(session)
		count, error := codec.frame_encode(
			session.control[:],
			true,
			.Close,
			session.close_payload[:session.close_size],
			{},
			false,
		)
		assert(error == .None)
		session.control_used, session.control_sent, session.control_close = count, 0, true
		session.control_deadline = session.close_deadline
	}

	if session.control_used > 0 {
		if session.close_requested && session.close_deadline.at < session.control_deadline.at {
			session.control_deadline = session.close_deadline
		}

		set_write_deadline(transport, session.control_deadline)
		n, error := core.upgrade_write(
			transport,
			session.control[session.control_sent:session.control_used],
			session.control_deadline,
		)
		if error.kind == .Pending {
			return .Waiting
		}

		if error.kind != .None || n <= 0 {
			record_io_failure(session, error)
			return .Done
		}

		session.control_sent += n
		if session.control_sent != session.control_used {
			return .Progress
		}
		session.metrics.frames_out += 1
		if session.control_close {
			session.close_sent = true
		}
		session.control_used, session.control_sent = 0, 0
		return .Progress
	}

	if session.close_sent || session.output_count == 0 {
		return .Idle
	}
	output := &session.outputs[session.output_head]
	if output.deadline.epoch == 0 {
		output.deadline = async.deadline_after(transport.runtime, session.config.write_timeout)
	}

	if session.frame_wire == nil {
		buffer, allocation := make(
			[]u8,
			session.config.max_frame_bytes + codec.MAX_FRAME_HEADER_SIZE,
			session.allocator,
		)

		if allocation != nil {
			record_io_failure(session, {})
			return .Done
		}

		session.frame_wire = buffer
	}

	count := min(session.config.max_frame_bytes, len(output.payload) - output.offset)
	opcode := output.opcode if output.offset == 0 else codec.Opcode.Continuation
	final := output.offset + count == len(output.payload)
	n, error := codec.frame_encode(
		session.frame_wire,
		final,
		opcode,
		output.payload[output.offset:output.offset + count],
		{},
		false,
	)
	assert(error == .None)
	output.offset += count
	session.frame_used, session.frame_sent, session.frame_final = n, 0, final

	return .Progress
}

// A scope is managed when it names a live budget node. Replace with
// budget.managed once core:sync/budget exports it.
scope_managed :: proc(scope: budget.Scope) -> bool {
	return budget.same_scope(scope, scope)
}
