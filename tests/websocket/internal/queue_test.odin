package saba_websocket

import rt "base:runtime"
import budget "shared:async/budget"
import "core:testing"

ws79_queue_fixture :: proc(config: Config) -> (^Session, budget.Scope) {
	scope, created := budget.create_root({bytes = 1 << 20, streams = 1, jobs = 1})
	assert(created == .None)
	session, error := new_session(scope, config, {}, rt.heap_allocator())
	assert(error.kind == .None)
	session.opened = true

	return session, scope
}

@(test)
send_copies_callback_bytes_and_backpressure_never_takes_another_owner :: proc(t: ^testing.T) {
	session, scope := ws79_queue_fixture(
		{max_frame_bytes = 2, max_message_bytes = 8, max_output_bytes = 4, output_capacity = 2},
	)
	defer budget.release_scope(&scope)
	defer drop_session(session)
	io := IO {
		_session = session,
		_active  = true,
	}

	payload := [2]u8{'A', 'B'}
	testing.expect_value(t, send(&io, .Text, payload[:]), .Accepted)
	payload[0], payload[1] = 'x', 'y'
	testing.expect_value(t, string(session.outputs[0].payload), "AB")
	testing.expect_value(t, send(&io, .Binary, []u8{3, 4}), .Accepted)
	before, viewed := budget.snapshot(scope)
	assert(viewed == .None)
	testing.expect_value(t, send(&io, .Text, []u8{'z'}), .Backpressure)
	testing.expect_value(t, session.output_count, 2)
	testing.expect(t, session.writable_wanted)
	after, after_error := budget.snapshot(scope)
	testing.expect_value(t, after_error, .None)
	testing.expect_value(t, after.used, before.used)
	snapshot := stats(&io)
	testing.expect_value(t, snapshot.queued_bytes, 4)
	testing.expect_value(t, snapshot.queued_messages, 2)
}

@(test)
permanent_send_rejection_preserves_queue_and_does_not_request_writable_callbacks :: proc(t: ^testing.T) {
	session, scope := ws79_queue_fixture(
		{max_frame_bytes = 2, max_message_bytes = 8, max_output_bytes = 16, output_capacity = 2},
	)
	defer budget.release_scope(&scope)
	defer drop_session(session)
	io := IO {
		_session = session,
		_active  = true,
	}

	before, viewed := budget.snapshot(scope)
	assert(viewed == .None)
	testing.expect_value(t, send(&io, .Text, []u8{0xff}), .Invalid)
	testing.expect_value(t, send(&io, .Ping, nil), .Invalid)
	testing.expect_value(t, send(&io, .Binary, []u8{1, 2, 3, 4, 5, 6, 7, 8, 9}), .Limit_Exceeded)
	testing.expect_value(t, session.output_count, 0)
	testing.expect(t, !session.writable_wanted)
	after, after_error := budget.snapshot(scope)
	testing.expect_value(t, after_error, .None)
	testing.expect_value(t, after.used, before.used)
}

@(test)
reserved_close_storage_survives_full_application_queue_and_closed_budget :: proc(t: ^testing.T) {
	session, scope := ws79_queue_fixture(
		{max_frame_bytes = 2, max_message_bytes = 8, max_output_bytes = 4, output_capacity = 1},
	)
	defer budget.release_scope(&scope)
	defer drop_session(session)
	io := IO {
		_session = session,
		_active  = true,
	}

	testing.expect_value(t, send(&io, .Text, []u8{'a', 'b', 'c', 'd'}), .Accepted)
	testing.expect_value(t, send(&io, .Text, []u8{'x'}), .Backpressure)
	assert(budget.close(scope) == .None)
	before, viewed := budget.snapshot(scope)
	assert(viewed == .None)
	testing.expect_value(t, close(&io, 1005, "reserved").kind, .Invalid_Close)
	testing.expect(t, !session.close_requested)
	testing.expect_value(t, close(&io, 1000, "done").kind, .None)
	testing.expect(t, session.close_requested)
	testing.expect_value(t, session.close_size, 6)
	testing.expect_value(t, string(session.close_payload[2:session.close_size]), "done")
	session.close_deadline = {
		epoch = 1,
		at    = 1234,
	}

	testing.expect_value(t, close(&io, 1001, "later").kind, .None)
	testing.expect_value(t, session.close_deadline.at, 1234)
	testing.expect_value(t, session.event.code, u16(1000))
	testing.expect_value(t, send(&io, .Text, []u8{'x'}), .Closed)
	after, after_error := budget.snapshot(scope)
	testing.expect_value(t, after_error, .None)
	testing.expect_value(t, after.used, before.used)
}

@(test)
inactive_callback_capability_cannot_enqueue_close_or_observe_session_borrows :: proc(t: ^testing.T) {
	session, scope := ws79_queue_fixture({})
	defer budget.release_scope(&scope)
	defer drop_session(session)
	io := IO {
		_session = session,
	}

	testing.expect_value(t, send(&io, .Text, []u8{'x'}), .Closed)
	testing.expect_value(t, close(&io, 1000, "").kind, .Invalid_Context)
	testing.expect_value(t, subprotocol(&io), "")
	testing.expect_value(t, stats(&io), Stats{})
	testing.expect_value(t, session.output_count, 0)
	testing.expect(t, !session.close_requested)
}

WS79_Writable_Probe :: struct {
	calls:     int,
	available: bool,
	sent:      Send_Result,
}
ws79_writable :: proc(data: rawptr, io: ^IO) {
	probe := cast(^WS79_Writable_Probe)data
	probe.calls += 1
	current := stats(io)
	probe.available = current.queued_bytes == 0 && current.queued_messages == 0
	probe.sent = send(io, .Binary, []u8{42})
}

@(test)
freed_output_credit_notifies_once_and_allows_callback_to_enqueue :: proc(t: ^testing.T) {
	session, scope := ws79_queue_fixture({max_output_bytes = 1, output_capacity = 1})
	defer budget.release_scope(&scope)
	defer drop_session(session)
	probe: WS79_Writable_Probe
	session.app = {
		data        = &probe,
		on_writable = ws79_writable,
	}

	io := IO {
		_session = session,
		_active  = true,
	}

	assert(send(&io, .Binary, []u8{1}) == .Accepted)
	assert(send(&io, .Binary, []u8{2}) == .Backpressure)
	finish_output(session, &io)
	testing.expect_value(t, probe.calls, 1)
	testing.expect(t, probe.available)
	testing.expect_value(t, probe.sent, .Accepted)
	testing.expect_value(t, session.output_count, 1)
	testing.expect_value(t, session.outputs[session.output_head].payload[0], u8(42))
	finish_output(session, &io)
	testing.expect_value(t, probe.calls, 1)
	testing.expect_value(t, session.output_count, 0)
}
