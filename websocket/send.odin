package saba_websocket

import codec "../../websocket"
import "core:unicode/utf8"

@(private)
valid_io :: proc(io: ^IO) -> bool {
	return io != nil && io._active && io._session != nil &&
		io._session.opened && !io._session.dropped
}

// Copies the complete message before returning. Rejection never retains payload.
// Frames are generated serially; a large message is fragmented at max_frame_bytes.
send :: proc(io: ^IO, opcode: codec.Opcode, payload: []u8) -> Send_Result {
	if !valid_io(io) do return .Closed
	session := io._session
	if session.close_requested do return .Closed
	if opcode != .Text && opcode != .Binary do return .Invalid
	if len(payload) > session.config.max_message_bytes ||
	   len(payload) > session.config.max_output_bytes {return .Limit_Exceeded}
	if opcode == .Text && !utf8.valid_string(string(payload)) do return .Invalid
	if session.output_count == len(session.outputs) ||
	   len(payload) > session.config.max_output_bytes - session.metrics.queued_bytes {
		session.writable_wanted = true
		return .Backpressure
	}
	storage, error := make([]u8, len(payload), session.allocator)
	if error != nil do return .Allocation_Failed
	copy(storage, payload)
	index := (session.output_head + session.output_count) % len(session.outputs)
	session.outputs[index] = {opcode = opcode, payload = storage}
	session.output_count += 1
	metrics := &session.metrics
	metrics.queued_bytes += len(storage)
	metrics.queued_messages = session.output_count
	metrics.peak_output_bytes = max(metrics.peak_output_bytes, metrics.queued_bytes)
	metrics.peak_output_messages = max(metrics.peak_output_messages, metrics.queued_messages)
	return .Accepted
}

close :: proc(io: ^IO, code: u16, reason: string) -> Error {
	if !valid_io(io) do return {kind = .Invalid_Context}
	if len(reason) > 123 do return {kind = .Invalid_Close}
	payload: [125]u8
	payload[0], payload[1] = u8(code >> 8), u8(code & 255)
	copy(payload[2:], reason)
	if codec.close_payload_validate(payload[:2 + len(reason)]) != .None do return {kind = .Invalid_Close}
	session := io._session
	if session.close_requested do return {}
	request_close(session, payload[:2 + len(reason)], .Application_Close, false)
	return {}
}

subprotocol :: proc(io: ^IO) -> string {
	if !valid_io(io) do return ""
	return io._session.protocol
}
stats :: proc(io: ^IO) -> Stats {
	if !valid_io(io) do return {}
	result := io._session.metrics
	result.message_capacity = cap(io._session.message.message)
	return result
}

@(private)
request_close :: proc(session: ^Session, payload: []u8, reason: Close_Reason, abort: bool) {
	if session.close_requested {
		// Escalate termination without replacing close bytes already in flight.
		if abort do session.abort_after_close = true
		return
	}
	session.close_requested, session.abort_after_close = true, abort
	session.close_size = copy(session.close_payload[:], payload)
	session.event.reason = reason
	if len(payload) >= 2 do session.event.code = u16(payload[0]) << 8 | u16(payload[1])
}
