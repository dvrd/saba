package saba_websocket

import core "../core"
import codec "../../websocket"
import async "../../async"
import "core:time"

@(private)
reset_read :: proc(session: ^Session, io: ^IO) {
	session.header_used, session.header_expected, session.payload_used = 0, 2, 0
	session.reading_payload, session.payload = false, nil
	session.read_deadline = async.deadline_after(io._transport.runtime, session.config.idle_timeout)
	if session.message_deadline.epoch != 0 && session.message_deadline.at < session.read_deadline.at {
		session.read_deadline = session.message_deadline
	}
}

@(private)
protocol_close :: proc(session: ^Session, code: u16, reason: Close_Reason) {
	payload := [2]u8{u8(code >> 8), u8(code & 255)}
	request_close(session, payload[:], reason, true)
}

@(private)
accept_header :: proc(session: ^Session, io: ^IO) -> Step {
	header, _, error := codec.frame_header_decode(session.input_header[:session.header_used], true)
	if error != .None {
		session.event.frame = error; protocol_close(session, 1002, .Protocol_Error); return .Progress
	}
	if header.payload_length > u64(session.config.max_frame_bytes) {
		protocol_close(session, 1009, .Protocol_Error); return .Progress
	}
	session.header = header
	if u8(header.opcode) >= 8 {
		session.payload = session.control_input[:int(header.payload_length)]
	} else {
		if session.close_requested {return .Done}
		if session.fragments == session.config.max_fragments {
			protocol_close(session, 1009, .Protocol_Error); return .Progress
		}
		session.fragments += 1
		if session.message_deadline.epoch == 0 {
			session.message_deadline = async.deadline_after(io._transport.runtime, session.config.message_timeout)
		}
		payload, allocation := codec.message_prepare(&session.message, header,
			session.config.max_message_bytes, session.allocator)
		if allocation.kind != .None {
			session.event.message = allocation
			code := u16(1002)
			if allocation.kind == .Message_Oversized do code = 1009
			if allocation.kind == .Allocation_Failed do code = 1011
			protocol_close(session, code, .Protocol_Error); return .Progress
		}
		session.payload = payload
		session.metrics.peak_message_bytes = max(session.metrics.peak_message_bytes, len(session.message.message))
	}
	session.reading_payload, session.payload_used = true, 0
	return .Progress
}

@(private)
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
		if len(session.payload) >= 2 do session.event.peer_code = u16(session.payload[0]) << 8 | u16(session.payload[1])
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
			protocol_close(session, 1007, .Protocol_Error); return .Progress
		}
		if session.message.message_ready {
			session.metrics.messages_in += 1
			if session.app.on_message != nil {
				session.app.on_message(session.app.data, io, session.message.message_opcode, session.message.message[:])
			}
			_, _, delivered := codec.message_deliver(&session.message, session.message.message[:])
			assert(delivered.kind == .None)
			session.fragments, session.message_deadline = 0, {}
		}
	}
	reset_read(session, io)
	return .Progress
}

@(private)
read_step :: proc(session: ^Session, io: ^IO) -> Step {
	if session.reading_payload && session.payload_used == len(session.payload) do return finish_frame(session, io)
	if !session.reading_payload && session.header_used == session.header_expected {
		if session.header_used == 2 {
			_, error := codec.frame_prefix_decode(session.input_header[:2], true)
			if error != .None {
				session.event.frame = error; protocol_close(session, 1002, .Protocol_Error); return .Progress
			}
			length := session.input_header[1] & 127
			session.header_expected = 6
			if length == 126 do session.header_expected += 2
			if length == 127 do session.header_expected += 8
		} else {return accept_header(session, io)}
	}
	deadline := session.read_deadline
	if session.message_deadline.epoch != 0 && session.message_deadline.at < deadline.at do deadline = session.message_deadline
	if session.close_requested && session.close_deadline.at < deadline.at do deadline = session.close_deadline
	now := async.deadline_after(io._transport.runtime, 0)
	io._transport.connection.read_deadline = time.tick_add(time.tick_now(), time.Duration(max(i64(0), deadline.at - now.at)))
	destination := session.input_header[session.header_used:session.header_expected]
	if session.reading_payload {
		destination = session.payload[session.payload_used:min(session.payload_used + 16 * 1024, len(session.payload))]
	}
	n, error := core.upgrade_read(io._transport, destination, deadline)
	if error.kind == .Pending do return .Waiting
	if error.kind != .None || n == 0 {
		if session.event.transport.kind == .None do session.event.transport = error
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
