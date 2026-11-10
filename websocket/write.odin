package saba_websocket

import core "../core"
import codec "../../websocket"
import async "../../async"
import "core:time"

@(private)
Step :: enum {Idle, Progress, Waiting, Done}

@(private)
set_write_deadline :: proc(io: ^core.Upgrade_IO, deadline: async.Deadline) {
	now := async.deadline_after(io.runtime, 0)
	io.connection.write_deadline = time.tick_add(time.tick_now(), time.Duration(max(i64(0), deadline.at - now.at)))
}

@(private)
notify_writable :: proc(session: ^Session, io: ^IO) {
	if !session.writable_wanted || session.close_requested do return
	session.writable_wanted = false
	if session.app.on_writable != nil do session.app.on_writable(session.app.data, io)
}

@(private)
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

@(private)
write_step :: proc(session: ^Session, io: ^IO) -> Step {
	transport := io._transport
	if session.frame_used > 0 {
		output := &session.outputs[session.output_head]
		deadline := output.deadline
		if session.close_requested && session.close_deadline.at < deadline.at do deadline = session.close_deadline
		set_write_deadline(transport, deadline)
		n, error := core.upgrade_write(transport, session.frame_wire[session.frame_sent:session.frame_used], deadline)
		if error.kind == .Pending do return .Waiting
		if error.kind != .None {if session.event.transport.kind == .None do session.event.transport = error; if session.event.reason == .Owner_Stopped do session.event.reason = .IO_Error; return .Done}
		if n <= 0 {if session.event.reason == .Owner_Stopped do session.event.reason = .IO_Error; return .Done}
		session.frame_sent += n
		if session.frame_sent != session.frame_used do return .Progress
		session.metrics.frames_out += 1
		session.frame_used, session.frame_sent = 0, 0
		if session.frame_final {finish_output(session, io)}
		return .Progress
	}
	abandon := session.peer_closed || session.abort_after_close || session.event.reason == .Shutdown
	if session.close_requested && !session.close_sent && session.control_used == 0 &&
	   (abandon || session.output_count == 0) {
		clear_outputs(session)
		count, error := codec.frame_encode(session.control[:], true, .Close,
			session.close_payload[:session.close_size], {}, false)
		assert(error == .None)
		session.control_used, session.control_sent, session.control_close = count, 0, true
		session.control_deadline = session.close_deadline
	}
	if session.control_used > 0 {
		if session.close_requested && session.close_deadline.at < session.control_deadline.at {
			session.control_deadline = session.close_deadline
		}
		set_write_deadline(transport, session.control_deadline)
		n, error := core.upgrade_write(transport,
			session.control[session.control_sent:session.control_used], session.control_deadline)
		if error.kind == .Pending do return .Waiting
		if error.kind != .None {if session.event.transport.kind == .None do session.event.transport = error; if session.event.reason == .Owner_Stopped do session.event.reason = .IO_Error; return .Done}
		if n <= 0 {if session.event.reason == .Owner_Stopped do session.event.reason = .IO_Error; return .Done}
		session.control_sent += n
		if session.control_sent != session.control_used do return .Progress
		session.metrics.frames_out += 1
		if session.control_close do session.close_sent = true
		session.control_used, session.control_sent = 0, 0
		return .Progress
	}
	if session.close_sent || session.output_count == 0 do return .Idle
	output := &session.outputs[session.output_head]
	if output.deadline.epoch == 0 do output.deadline = async.deadline_after(transport.runtime, session.config.write_timeout)
	if session.frame_wire == nil {
		buffer, allocation := make([]u8, session.config.max_frame_bytes + codec.MAX_FRAME_HEADER_SIZE, session.allocator)
		if allocation != nil {if session.event.reason == .Owner_Stopped do session.event.reason = .IO_Error; return .Done}
		session.frame_wire = buffer
	}
	count := min(session.config.max_frame_bytes, len(output.payload) - output.offset)
	opcode := output.opcode if output.offset == 0 else codec.Opcode.Continuation
	final := output.offset + count == len(output.payload)
	n, error := codec.frame_encode(session.frame_wire, final, opcode,
		output.payload[output.offset:output.offset + count], {}, false)
	assert(error == .None)
	output.offset += count
	session.frame_used, session.frame_sent, session.frame_final = n, 0, final
	return .Progress
}
