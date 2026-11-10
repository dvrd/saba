package saba_websocket

import core "../core"
import async "../../async"

@(private)
SESSION_WORK_LIMIT :: 32

@(private)
semantic_deadline :: proc(session: ^Session) -> async.Deadline {
	result := session.read_deadline
	for deadline in ([3]async.Deadline{session.message_deadline,
		session.control_deadline if session.control_used > 0 else async.Deadline{},
		session.close_deadline if session.close_requested else async.Deadline{}}) {
		if deadline.epoch != 0 && (result.epoch == 0 || deadline.at < result.at) do result = deadline
	}
	if session.output_count > 0 {
		deadline := session.outputs[session.output_head].deadline
		if deadline.epoch != 0 && (result.epoch == 0 || deadline.at < result.at) do result = deadline
	}
	return result
}

// A semantic cutoff cannot wait behind an accepted outbound write. Returning
// Done leaves its stable buffers untouched until Core drains the I/O callbacks.
@(private)
session_budget_expired :: proc(session: ^Session, runtime: ^async.Runtime) -> bool {
	deadline := semantic_deadline(session)
	if deadline.epoch == 0 || async.deadline_after(runtime, 0).at < deadline.at do return false
	if session.event.transport.kind == .None do session.event.transport = {kind = .Timeout}
	if session.event.reason == .Owner_Stopped do session.event.reason = .Timeout
	return true
}

@(private)
wait_session :: proc(session: ^Session, io: ^IO, read, write: bool) -> async.Resume_Result {
	transport := io._transport
	deadline := semantic_deadline(session)
	if transport.socket != (async.Socket{}) && (read || write) {
		// Individual native read/write calls replace the socket interest. Restore
		// both directions explicitly after attempting them, then recheck budgets.
		error := async.wait_stream(transport.socket, read, write, deadline)
		if error.kind == .None || error.kind == .Timeout do return .Yield
		if error.kind != .Pending {
			if session.event.transport.kind == .None do session.event.transport = error
			if session.event.reason == .Owner_Stopped do session.event.reason = .IO_Error
			return .Done
		}
	}
	if deadline.epoch != 0 {
		error := async.sleep_until_earlier(transport.runtime, deadline)
		if error.kind == .None do return .Yield
		if error.kind != .Pending do return .Done
	}
	return .Waiting
}

@(private)
resume_session :: proc(data: rawptr, transport: ^core.Upgrade_IO) -> async.Resume_Result {
	session := cast(^Session)data
	io := IO{_session = session, _transport = transport, _active = true}
	defer {io._active = false}
	if !session.opened {
		session.opened = true
		reset_read(session, &io)
		if session.app.on_open != nil do session.app.on_open(session.app.data, &io)
	}
	for _ in 0 ..< SESSION_WORK_LIMIT {
		if core.request_server_stopping(session.request_context) {
			protocol_close(session, 1001, .Shutdown)
		}
		if session.close_requested && session.close_deadline.epoch == 0 {
			session.close_deadline = async.deadline_after(transport.runtime, session.config.close_timeout)
		}
		if session.close_sent && (session.peer_closed || session.abort_after_close) do return .Done
		if session_budget_expired(session, transport.runtime) do return .Done
		read := Step.Idle
		// Service input while output is blocked. A pending control response owns
		// its fixed slot, so pause input until it is written instead of overwriting.
		if session.control_used == 0 && (!session.close_requested || session.close_sent) {
			read = read_step(session, &io)
			if read == .Done do return .Done
		}
		// Input policy/callbacks may have requested close during this step.
		if session.close_requested && session.close_deadline.epoch == 0 {
			session.close_deadline = async.deadline_after(transport.runtime, session.config.close_timeout)
		}
		write := write_step(session, &io)
		if write == .Done do return .Done
		if session.close_sent && (session.peer_closed || session.abort_after_close) do return .Done
		if read != .Progress && write != .Progress {
			return wait_session(session, &io, read == .Waiting, write == .Waiting)
		}
	}
	return .Yield
}
