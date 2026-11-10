package saba_websocket

import core "../core"
import codec "../../websocket"
import "core:mem"
import charged "core:mem/budget"
import budget "core:sync/budget"

@(private)
new_session :: proc(scope: budget.Scope, config: Config, app: Application,
	backing: mem.Allocator) -> (^Session, Error) {
	resolved, validation := config_normalize(config)
	if validation.kind != .None do return nil, validation
	if !budget.same_scope(scope, scope) do return nil, {kind = .Invalid_Context}
	binding, binding_error := charged.create(scope, {backing = backing})
	if binding_error.kind != .None {
		return nil, {kind = .Budget_Rejected, budget = binding_error.budget,
			allocation = binding_error.allocation}
	}
	allocator := charged.allocator(binding)
	session, allocation := new(Session, allocator)
	if allocation != nil {
		charged.release(&binding)
		return nil, {kind = .Allocation_Failed, allocation = allocation}
	}
	resolved.check_origin, resolved.select_subprotocol, resolved.policy_data = nil, nil, nil
	session^ = {config = resolved, app = app, binding = binding, allocator = allocator,
		header_expected = 2, event = {reason = .Owner_Stopped}}
	outputs, error := make([]Output, resolved.output_capacity, allocator)
	if error != nil {
		drop_session(session)
		return nil, {kind = .Allocation_Failed, allocation = error}
	}
	session.outputs = outputs
	return session, {}
}

@(private)
clear_outputs :: proc(session: ^Session) {
	for &output in session.outputs {
		delete(output.payload, session.allocator)
		output = {}
	}
	session.output_head, session.output_count = 0, 0
	session.metrics.queued_bytes, session.metrics.queued_messages = 0, 0
}

@(private)
drop_session :: proc(data: rawptr) {
	session := cast(^Session)data
	if session == nil do return
	app, owned := session.app, session.owns_app
	session.owns_app, session.dropped = false, true
	clear_outputs(session)
	codec.message_release(&session.message)
	delete(session.frame_wire, session.allocator)
	delete(session.outputs, session.allocator)
	delete(session.protocol, session.allocator)
	event := session.event
	event.clean = session.close_sent && session.peer_closed &&
		event.transport.kind == .None && event.frame == .None && event.message.kind == .None &&
		event.reason != .Protocol_Error && event.reason != .Timeout && event.reason != .IO_Error
	event.stats = session.metrics
	event.stats.message_capacity = 0
	if !session.opened do event.reason = .Not_Opened
	else if event.reason == .Owner_Stopped && core.request_server_stopping(session.request_context) {
		event.reason = .Shutdown
	}
	core.release_request_context(&session.request_context)
	binding, allocator := session.binding, session.allocator
	mem.zero(session, size_of(Session))
	free(session, allocator)
	charged.release(&binding)
	if owned {
		if app.on_close != nil do app.on_close(app.data, &event)
		if app.drop != nil do app.drop(app.data)
	}
}
