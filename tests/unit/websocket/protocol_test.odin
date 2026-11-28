package saba_websocket

import core "../core"
import rt "base:runtime"
import async "shared:async"
import codec "shared:async/websocket"
import budget "shared:async/budget"
import "core:testing"

WS79_Message_Probe :: struct {
	calls:  int,
	bytes:  [32]u8,
	size:   int,
	copied: Send_Result,
}

ws79_message :: proc(data: rawptr, io: ^IO, opcode: codec.Opcode, payload: []u8) {
	probe := cast(^WS79_Message_Probe)data
	assert(opcode == .Text)
	probe.calls += 1
	probe.size = copy(probe.bytes[:], payload)
	probe.copied = send(io, .Text, payload)
}

ws79_frame_fixture :: proc(
	t: ^testing.T,
	config: Config,
	runtime: ^async.Runtime,
	transport: ^core.Upgrade_IO,
	conn: ^core.Connection,
) -> (
	^Session,
	budget.Scope,
	IO,
) {
	assert(async.init(runtime, {workers = 1, task_capacity = 1, io_capacity = 1}).kind == .None)
	transport^ = {
		runtime    = runtime,
		connection = conn,
	}
	session, scope := ws79_queue_fixture(config)
	io := IO {
		_session   = session,
		_transport = transport,
		_active    = true,
	}
	reset_read(session, &io)
	testing.expect(t, session.read_deadline.epoch != 0)
	return session, scope, io
}

// Literal RFC6455 headers: FIN/opcode, masked seven-bit length, four-byte mask.
// The payload below is already unmasked so this helper isolates assembler and
// control/lifetime behavior from the separately wire-tested XOR decoder.
ws79_header :: proc(session: ^Session, first: u8, length: u8) {
	assert(length <= 125)
	copy(session.input_header[:], []u8{first, 0x80 | length, 1, 2, 3, 4})
	session.header_used = 6
}

@(test)
fragmented_utf8_message_and_interleaved_ping_share_one_fixed_message_deadline :: proc(t: ^testing.T) {
	runtime: async.Runtime
	conn: core.Connection
	transport: core.Upgrade_IO
	session, scope, io := ws79_frame_fixture(
		t,
		{max_frame_bytes = 4, max_message_bytes = 8, max_output_bytes = 16, max_fragments = 2},
		&runtime,
		&transport,
		&conn,
	)
	defer assert(async.destroy(&runtime).kind == .None)
	defer budget.release_scope(&scope)
	defer drop_session(session)
	probe: WS79_Message_Probe
	session.app = {
		data       = &probe,
		on_message = ws79_message,
	}

	ws79_header(session, 0x01, 1)
	testing.expect_value(t, accept_header(session, &io), .Progress)
	session.payload[0] = 0xe2
	testing.expect_value(t, finish_frame(session, &io), .Progress)
	original := session.message_deadline
	testing.expect(t, original.epoch != 0 && session.message.fragmented)
	ws79_header(session, 0x89, 1)
	testing.expect_value(t, accept_header(session, &io), .Progress)
	session.payload[0] = 'p'
	testing.expect_value(t, finish_frame(session, &io), .Progress)
	testing.expect_value(t, session.message_deadline, original)
	testing.expect_value(t, session.control[0], u8(0x8a))
	testing.expect_value(t, session.control[2], u8('p'))
	testing.expect_value(t, probe.calls, 0)
	ws79_header(session, 0x80, 2)
	testing.expect_value(t, accept_header(session, &io), .Progress)
	copy(session.payload, []u8{0x82, 0xac})
	testing.expect_value(t, finish_frame(session, &io), .Progress)
	testing.expect_value(t, probe.calls, 1)
	testing.expect_value(t, probe.size, 3)
	testing.expect_value(t, string(probe.bytes[:probe.size]), "€")
	testing.expect_value(t, probe.copied, .Accepted)
	testing.expect_value(t, string(session.outputs[0].payload), "€")
	testing.expect_value(t, len(session.message.message), 0)
	testing.expect_value(t, session.message_deadline, async.Deadline{})
}

@(test)
zero_payload_fragment_flood_hits_fragment_limit_without_extending_message_deadline :: proc(t: ^testing.T) {
	runtime: async.Runtime
	conn: core.Connection
	transport: core.Upgrade_IO
	session, scope, io := ws79_frame_fixture(t, {max_fragments = 1}, &runtime, &transport, &conn)
	defer assert(async.destroy(&runtime).kind == .None)
	defer budget.release_scope(&scope)
	defer drop_session(session)
	ws79_header(session, 0x01, 0)
	assert(accept_header(session, &io) == .Progress)
	assert(finish_frame(session, &io) == .Progress)
	original := session.message_deadline
	before, viewed := budget.snapshot(scope)
	assert(viewed == .None)
	ws79_header(session, 0x80, 0)
	assert(accept_header(session, &io) == .Progress)
	testing.expect(t, session.close_requested)
	testing.expect_value(t, session.event.code, u16(1009))
	testing.expect_value(t, session.message_deadline, original)
	after, after_error := budget.snapshot(scope)
	assert(after_error == .None)
	testing.expect_value(t, after.used, before.used)
}

@(test)
aggregate_message_limit_is_independent_of_individually_valid_frame_limits :: proc(t: ^testing.T) {
	runtime: async.Runtime
	conn: core.Connection
	transport: core.Upgrade_IO
	session, scope, io := ws79_frame_fixture(
		t,
		{max_frame_bytes = 3, max_message_bytes = 3},
		&runtime,
		&transport,
		&conn,
	)
	defer assert(async.destroy(&runtime).kind == .None)
	defer budget.release_scope(&scope)
	defer drop_session(session)
	ws79_header(session, 0x02, 2)
	assert(accept_header(session, &io) == .Progress)
	copy(session.payload, []u8{1, 2})
	assert(finish_frame(session, &io) == .Progress)
	before, viewed := budget.snapshot(scope)
	assert(viewed == .None)
	ws79_header(session, 0x80, 2)
	assert(accept_header(session, &io) == .Progress)
	testing.expect(t, session.close_requested)
	testing.expect_value(t, session.event.message.kind, .Message_Oversized)
	testing.expect_value(t, session.event.code, u16(1009))
	after, after_error := budget.snapshot(scope)
	assert(after_error == .None)
	testing.expect_value(t, after.used, before.used)
}

@(test)
invalid_masked_prefix_fails_before_payload_allocation :: proc(t: ^testing.T) {
	session, scope := ws79_queue_fixture({})
	defer budget.release_scope(&scope)
	defer drop_session(session)
	io := IO {
		_session = session,
		_active  = true,
	}

	session.input_header[0], session.input_header[1] = 0x81, 1
	session.header_used, session.header_expected = 2, 2
	before, viewed := budget.snapshot(scope)
	assert(viewed == .None)
	testing.expect_value(t, read_step(session, &io), .Progress)
	testing.expect_value(t, session.event.frame, .Unexpected_Masking)
	testing.expect_value(t, session.event.code, u16(1002))
	after, after_error := budget.snapshot(scope)
	assert(after_error == .None)
	testing.expect_value(t, after.used, before.used)
}

@(test)
malformed_frame_after_sent_application_close_escalates_without_reparsing :: proc(t: ^testing.T) {
	runtime: async.Runtime
	conn: core.Connection
	transport: core.Upgrade_IO
	session, scope, io := ws79_frame_fixture(t, {}, &runtime, &transport, &conn)
	defer assert(async.destroy(&runtime).kind == .None)
	defer budget.release_scope(&scope)
	defer drop_session(session)
	assert(close(&io, 1000, "done").kind == .None)
	session.close_sent = true
	session.close_deadline = async.deadline_after(&runtime, session.config.close_timeout)
	deadline := session.close_deadline
	session.input_header[0], session.input_header[1] = 0x81, 1
	session.header_used, session.header_expected = 2, 2
	testing.expect_value(t, resume_session(session, &transport), .Done)
	testing.expect(t, session.abort_after_close)
	testing.expect_value(t, session.event.frame, .Unexpected_Masking)
	testing.expect_value(t, session.event.reason, .Application_Close)
	testing.expect_value(t, session.event.code, u16(1000))
	testing.expect_value(t, string(session.close_payload[2:session.close_size]), "done")
	testing.expect_value(t, session.close_deadline, deadline)
}

@(test)
application_close_drains_accepted_output_under_fixed_close_deadline :: proc(t: ^testing.T) {
	runtime: async.Runtime
	conn: core.Connection
	transport: core.Upgrade_IO
	session, scope, io := ws79_frame_fixture(t, {max_frame_bytes = 2}, &runtime, &transport, &conn)
	defer assert(async.destroy(&runtime).kind == .None)
	defer budget.release_scope(&scope)
	defer drop_session(session)
	assert(send(&io, .Text, []u8{'a', 'b', 'c'}) == .Accepted)
	assert(close(&io, 1000, "done").kind == .None)
	session.close_deadline = async.deadline_after(&runtime, session.config.close_timeout)
	deadline := session.close_deadline
	// Preparing the first frame performs no transport write or syscall.
	testing.expect_value(t, write_step(session, &io), .Progress)
	testing.expect_value(t, session.output_count, 1)
	testing.expect_value(t, session.frame_wire[0], u8(0x01))
	testing.expect_value(t, string(session.frame_wire[2:session.frame_used]), "ab")
	testing.expect(t, !session.close_sent && !session.frame_final)
	testing.expect_value(t, session.close_deadline, deadline)
}

WS79_Close_Probe :: struct {
	event:    Close_Event,
	calls:    int,
	scope:    budget.Scope,
	released: bool,
}
ws79_closed :: proc(data: rawptr, event: ^Close_Event) {
	probe := cast(^WS79_Close_Probe)data
	probe.event = event^
	probe.calls += 1
	snapshot, error := budget.snapshot(probe.scope)
	probe.released = error == .None && snapshot.used == budget.Usage{}
}

@(test)
empty_peer_close_is_clean_and_application_close_cutoff_retains_timeout_detail :: proc(t: ^testing.T) {
	for expired in ([]bool{false, true}) {
		runtime: async.Runtime
		conn: core.Connection
		transport: core.Upgrade_IO
		session, scope, io := ws79_frame_fixture(t, {}, &runtime, &transport, &conn)
		probe := WS79_Close_Probe {
			scope = scope,
		}

		session.app = {
			data     = &probe,
			on_close = ws79_closed,
		}

		session.owns_app = true

		if expired {
			assert(close(&io, 1000, "done").kind == .None)
			session.close_sent = true
			session.close_deadline = async.deadline_after(&runtime, -1)
			testing.expect_value(t, resume_session(session, &transport), .Done)
		} else {
			ws79_header(session, 0x88, 0)
			assert(accept_header(session, &io) == .Progress)
			assert(finish_frame(session, &io) == .Progress)
			session.close_sent = true
			testing.expect_value(t, resume_session(session, &transport), .Done)
		}

		drop_session(session)
		testing.expect_value(t, probe.calls, 1)
		testing.expect(t, probe.released)
		testing.expect_value(t, probe.event.clean, !expired)
		testing.expect_value(t, probe.event.peer_code, u16(0))

		if expired {
			testing.expect_value(t, probe.event.reason, .Application_Close)
			testing.expect_value(t, probe.event.transport.kind, .Timeout)
		} else {
			testing.expect_value(t, probe.event.reason, .Peer_Close)
			testing.expect_value(t, probe.event.transport.kind, .None)
		}

		budget.release_scope(&scope)
		assert(async.destroy(&runtime).kind == .None)
	}
}

@(test)
inbound_budget_expiry_preempts_longer_outbound_write_and_keeps_borrowed_frame_stable :: proc(t: ^testing.T) {
	for message_budget in ([]bool{false, true}) {
		runtime: async.Runtime
		conn: core.Connection
		transport: core.Upgrade_IO
		session, scope, io := ws79_frame_fixture(t, {}, &runtime, &transport, &conn)
		assert(send(&io, .Binary, []u8{1, 2, 3, 4}) == .Accepted)
		assert(write_step(session, &io) == .Progress)
		// Model a transport retaining the uncompleted remainder. Expiry must
		// terminate before another syscall and must not alter its borrowed bytes.
		session.frame_sent = 1
		original: [6]u8
		assert(copy(original[:], session.frame_wire[:session.frame_used]) == 6)
		deadline := session.outputs[session.output_head].deadline

		if message_budget {
			session.fragments = 1
			session.message_deadline = async.deadline_after(&runtime, 0)
		} else {
			session.header_used = 1
			session.read_deadline = async.deadline_after(&runtime, 0)
		}

		testing.expect_value(t, resume_session(session, &transport), .Done)
		testing.expect_value(t, session.event.transport.kind, .Timeout)
		testing.expect_value(t, session.event.reason, .Timeout)
		testing.expect_value(t, session.frame_sent, 1)
		testing.expect_value(t, session.outputs[session.output_head].deadline, deadline)
		testing.expect(t, string(session.frame_wire[:session.frame_used]) == string(original[:]))
		testing.expect_value(t, session.output_count, 1)
		drop_session(session)
		snapshot, error := budget.snapshot(scope)
		assert(error == .None)
		testing.expect_value(t, snapshot.used, budget.Usage{})
		budget.release_scope(&scope)
		assert(async.destroy(&runtime).kind == .None)
	}
}

WS_Ping_Sink :: struct {
	bytes: [32]u8,
	size:  int,
}

ws_ping_capture :: proc(data: rawptr, source: []u8, _: async.Deadline) -> (int, async.Error) {
	sink := cast(^WS_Ping_Sink)data
	sink.size += copy(sink.bytes[sink.size:], source)
	return len(source), {}
}

// A browser that only receives cannot originate pings, so without a server
// ping its session was closed at every idle_timeout.
@(test)
quiet_receive_only_peer_is_pinged_before_idle_timeout_and_pong_rearms_both_timers :: proc(t: ^testing.T) {
	resolved, valid := config_normalize({})
	testing.expect_value(t, valid.kind, Error_Kind.None)
	testing.expect_value(t, resolved.ping_interval, resolved.idle_timeout / 2)
	disabled, disabled_valid := config_normalize({ping_interval = -1})
	testing.expect_value(t, disabled_valid.kind, Error_Kind.None)
	testing.expect(t, disabled.ping_interval < 0)

	runtime: async.Runtime
	conn: core.Connection
	transport: core.Upgrade_IO
	session, scope, io := ws79_frame_fixture(t, {}, &runtime, &transport, &conn)
	defer assert(async.destroy(&runtime).kind == .None)
	defer budget.release_scope(&scope)
	defer drop_session(session)
	sink: WS_Ping_Sink
	transport.stream_data = &sink
	transport.stream_write = ws_ping_capture

	// Armed below the idle cutoff, and a session that is not yet quiet sends nothing.
	testing.expect(t, session.ping_deadline.epoch != 0)
	testing.expect(t, session.ping_deadline.at < session.read_deadline.at)
	testing.expect_value(t, write_step(session, &io), Step.Idle)
	testing.expect_value(t, sink.size, 0)

	// The quiet interval elapses: exactly one unmasked empty Ping goes out.
	session.ping_deadline = async.deadline_after(&runtime, 0)
	testing.expect_value(t, write_step(session, &io), Step.Progress)
	testing.expect_value(t, sink.size, 2)
	testing.expect_value(t, sink.bytes[0], u8(0x89))
	testing.expect_value(t, sink.bytes[1], u8(0))
	testing.expect(t, !session.close_requested && !session.close_sent)
	testing.expect_value(t, write_step(session, &io), Step.Idle)
	testing.expect_value(t, sink.size, 2)

	// The peer's Pong counts as inbound traffic and re-arms idle and ping timers.
	session.read_deadline = async.deadline_after(&runtime, 0)
	ws79_header(session, 0x8a, 0)
	testing.expect_value(t, accept_header(session, &io), Step.Progress)
	testing.expect_value(t, finish_frame(session, &io), Step.Progress)
	now := async.deadline_after(&runtime, 0)
	testing.expect(t, session.read_deadline.at > now.at)
	testing.expect(t, session.ping_deadline.at > now.at && session.ping_deadline.at < session.read_deadline.at)
	testing.expect(t, !session_budget_expired(session, &runtime))
}

@(test)
disabled_keepalive_never_pings_and_a_closing_session_does_not_start_one :: proc(t: ^testing.T) {
	runtime: async.Runtime
	conn: core.Connection
	transport: core.Upgrade_IO
	session, scope, io := ws79_frame_fixture(t, {ping_interval = -1}, &runtime, &transport, &conn)
	defer assert(async.destroy(&runtime).kind == .None)
	defer budget.release_scope(&scope)
	defer drop_session(session)
	sink: WS_Ping_Sink
	transport.stream_data = &sink
	transport.stream_write = ws_ping_capture
	testing.expect_value(t, session.ping_deadline, async.Deadline{})
	testing.expect_value(t, write_step(session, &io), Step.Idle)
	testing.expect_value(t, sink.size, 0)

	session.config.ping_interval = session.config.idle_timeout / 2
	session.ping_deadline = async.deadline_after(&runtime, 0)
	session.close_deadline = async.deadline_after(&runtime, session.config.close_timeout)
	request_close(session, []u8{0x03, 0xe8}, .Application_Close, false)
	testing.expect_value(t, write_step(session, &io), Step.Progress)
	testing.expect_value(t, sink.bytes[0], u8(0x88))
}

@(test)
data_frame_after_sent_close_is_dropped_and_the_peer_close_still_completes :: proc(t: ^testing.T) {
	runtime: async.Runtime
	conn: core.Connection
	transport: core.Upgrade_IO
	session, scope, io := ws79_frame_fixture(t, {}, &runtime, &transport, &conn)
	defer assert(async.destroy(&runtime).kind == .None)
	defer budget.release_scope(&scope)
	defer drop_session(session)
	assert(close(&io, 1000, "done").kind == .None)
	session.close_sent = true
	session.close_deadline = async.deadline_after(&runtime, session.config.close_timeout)

	// A text frame the peer sent before it saw the Close.
	ws79_header(session, 0x81, 5)
	testing.expect_value(t, accept_header(session, &io), .Progress)
	testing.expect(t, session.discarding && session.reading_payload)
	testing.expect_value(t, len(session.payload), 5)
	testing.expect_value(t, finish_frame(session, &io), .Progress)
	testing.expect(t, !session.discarding && !session.reading_payload)
	testing.expect_value(t, session.metrics.messages_in, 0)
	testing.expect_value(t, session.fragments, 0)

	// The peer's answering Close is then read as usual.
	ws79_header(session, 0x88, 2)
	testing.expect_value(t, accept_header(session, &io), .Progress)
	copy(session.payload, []u8{0x03, 0xe8})
	testing.expect_value(t, finish_frame(session, &io), .Progress)
	testing.expect(t, session.peer_closed)
	testing.expect_value(t, session.event.peer_code, u16(1000))
	testing.expect_value(t, session.event.reason, .Application_Close)
}

ws_read_timeout :: proc(_: rawptr, _: []u8, _: async.Deadline) -> (int, async.Error) {
	return 0, {kind = .Timeout}
}

// A peer that goes quiet past idle_timeout is closed with 1001 Going Away
// (RFC 6455 7.4.1), and the event keeps the timeout as its reason.
@(test)
idle_read_timeout_closes_with_going_away :: proc(t: ^testing.T) {
	runtime: async.Runtime
	conn: core.Connection
	transport: core.Upgrade_IO
	session, scope, io := ws79_frame_fixture(t, {}, &runtime, &transport, &conn)
	defer assert(async.destroy(&runtime).kind == .None)
	defer budget.release_scope(&scope)
	defer drop_session(session)
	transport.stream_read = ws_read_timeout

	testing.expect_value(t, read_step(session, &io), Step.Progress)
	testing.expect(t, session.close_requested && session.abort_after_close)
	testing.expect_value(t, session.event.code, u16(1001))
	testing.expect_value(t, session.event.reason, Close_Reason.Timeout)
	testing.expect_value(t, session.event.transport.kind, async.Error_Kind.Timeout)
	testing.expect_value(t, session.close_payload[0], u8(0x03))
	testing.expect_value(t, session.close_payload[1], u8(0xe9))
}

// A server that stops closes each open session with 1001 Going Away before it
// leaves, instead of a normal 1000 the peer could take for an orderly end.
@(test)
server_shutdown_closes_open_session_with_going_away :: proc(t: ^testing.T) {
	runtime: async.Runtime
	conn: core.Connection
	transport: core.Upgrade_IO
	session, scope, _ := ws79_frame_fixture(t, {}, &runtime, &transport, &conn)
	defer assert(async.destroy(&runtime).kind == .None)
	defer budget.release_scope(&scope)
	defer drop_session(session)
	stopping, allocated := new(core.Server_Cancellation, rt.heap_allocator())
	assert(allocated == nil)
	stopping^ = {
		references = 1,
		stopping   = true,
	}
	defer core.release_server_cancellation(stopping)
	retained, created := core.new_request_context(stopping, {}, rt.heap_allocator())
	assert(created)
	session.request_context = retained
	sink: WS_Ping_Sink
	transport.stream_data = &sink
	transport.stream_write = ws_ping_capture

	testing.expect_value(t, resume_session(session, &transport), async.Resume_Result.Done)
	testing.expect(t, session.close_sent)
	testing.expect_value(t, session.event.reason, Close_Reason.Shutdown)
	testing.expect_value(t, session.event.code, u16(1001))
	testing.expect_value(t, sink.size, 4)
	testing.expect_value(t, sink.bytes[0], u8(0x88))
	testing.expect_value(t, sink.bytes[1], u8(2))
	testing.expect_value(t, sink.bytes[2], u8(0x03))
	testing.expect_value(t, sink.bytes[3], u8(0xe9))
}
