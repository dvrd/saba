package saba_websocket

import core "../core"
import async "../../async"
import codec "../../websocket"
import budget "core:sync/budget"
import "core:testing"

WS79_Message_Probe :: struct {calls: int, bytes: [32]u8, size: int, copied: Send_Result}

ws79_message :: proc(data: rawptr, io: ^IO, opcode: codec.Opcode, payload: []u8) {
    probe := cast(^WS79_Message_Probe)data
    assert(opcode == .Text)
    probe.calls += 1
    probe.size = copy(probe.bytes[:], payload)
    probe.copied = send(io, .Text, payload)
}

ws79_frame_fixture :: proc(t: ^testing.T, config: Config, runtime: ^async.Runtime,
    transport: ^core.Upgrade_IO, conn: ^core.Connection,
) -> (^Session, budget.Scope, IO) {
    assert(async.init(runtime, {workers = 1, task_capacity = 1, io_capacity = 1}).kind == .None)
    transport^ = {runtime = runtime, connection = conn}
    session, scope := ws79_queue_fixture(config)
    io := IO{_session = session, _transport = transport, _active = true}
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
    session, scope, io := ws79_frame_fixture(t, {max_frame_bytes = 4,
        max_message_bytes = 8, max_output_bytes = 16, max_fragments = 2},
        &runtime, &transport, &conn)
    defer assert(async.destroy(&runtime).kind == .None)
    defer budget.release_scope(&scope)
    defer drop_session(session)
    probe: WS79_Message_Probe
    session.app = {data = &probe, on_message = ws79_message}
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
    before, viewed := budget.snapshot(scope); assert(viewed == .None)
    ws79_header(session, 0x80, 0)
    assert(accept_header(session, &io) == .Progress)
    testing.expect(t, session.close_requested)
    testing.expect_value(t, session.event.code, u16(1009))
    testing.expect_value(t, session.message_deadline, original)
    after, after_error := budget.snapshot(scope); assert(after_error == .None)
    testing.expect_value(t, after.used, before.used)
}

@(test)
aggregate_message_limit_is_independent_of_individually_valid_frame_limits :: proc(t: ^testing.T) {
    runtime: async.Runtime
    conn: core.Connection
    transport: core.Upgrade_IO
    session, scope, io := ws79_frame_fixture(t, {max_frame_bytes = 3,
        max_message_bytes = 3}, &runtime, &transport, &conn)
    defer assert(async.destroy(&runtime).kind == .None)
    defer budget.release_scope(&scope)
    defer drop_session(session)
    ws79_header(session, 0x02, 2)
    assert(accept_header(session, &io) == .Progress)
    copy(session.payload, []u8{1, 2})
    assert(finish_frame(session, &io) == .Progress)
    before, viewed := budget.snapshot(scope); assert(viewed == .None)
    ws79_header(session, 0x80, 2)
    assert(accept_header(session, &io) == .Progress)
    testing.expect(t, session.close_requested)
    testing.expect_value(t, session.event.message.kind, .Message_Oversized)
    testing.expect_value(t, session.event.code, u16(1009))
    after, after_error := budget.snapshot(scope); assert(after_error == .None)
    testing.expect_value(t, after.used, before.used)
}

@(test)
invalid_masked_prefix_fails_before_payload_allocation :: proc(t: ^testing.T) {
    session, scope := ws79_queue_fixture({})
    defer budget.release_scope(&scope)
    defer drop_session(session)
    io := IO{_session = session, _active = true}
    session.input_header[0], session.input_header[1] = 0x81, 1
    session.header_used, session.header_expected = 2, 2
    before, viewed := budget.snapshot(scope); assert(viewed == .None)
    testing.expect_value(t, read_step(session, &io), .Progress)
    testing.expect_value(t, session.event.frame, .Unexpected_Masking)
    testing.expect_value(t, session.event.code, u16(1002))
    after, after_error := budget.snapshot(scope); assert(after_error == .None)
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

WS79_Close_Probe :: struct {event: Close_Event, calls: int, scope: budget.Scope, released: bool}
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
        probe := WS79_Close_Probe{scope = scope}
        session.app = {data = &probe, on_close = ws79_closed}
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
        snapshot, error := budget.snapshot(scope); assert(error == .None)
        testing.expect_value(t, snapshot.used, budget.Usage{})
        budget.release_scope(&scope)
        assert(async.destroy(&runtime).kind == .None)
    }
}
