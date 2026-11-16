package saba_websocket

import rt "base:runtime"
import core "../core"
import async "../../async"
import "core:mem"
import budget "core:sync/budget"
import "core:testing"

WS79_Allocator :: struct {
    track: mem.Tracking_Allocator,
    calls, fail_at, failures: int,
}

ws79_allocate :: proc(data: rawptr, mode: mem.Allocator_Mode,
    size, alignment: int, old_memory: rawptr, old_size: int, location := #caller_location,
) -> ([]u8, mem.Allocator_Error) {
    state := cast(^WS79_Allocator)data
    if mode == .Alloc || mode == .Alloc_Non_Zeroed ||
       mode == .Resize || mode == .Resize_Non_Zeroed {
        state.calls += 1
        if state.calls == state.fail_at {
            state.failures += 1
            return nil, .Out_Of_Memory
        }
    }
    backing := mem.tracking_allocator(&state.track)
    return backing.procedure(backing.data, mode, size, alignment,
        old_memory, old_size, location)
}

ws79_small_config :: proc() -> Config {
    return {max_frame_bytes = 1024, max_message_bytes = 2048,
        max_output_bytes = 4096, output_capacity = 2}
}

ws79_constructor_run :: proc(t: ^testing.T, fail_at: int) -> int {
    scope, created := budget.create_root({bytes = 1 << 20, streams = 1, jobs = 1})
    assert(created == .None)
    defer budget.release_scope(&scope)
    state := WS79_Allocator{fail_at = fail_at}
    mem.tracking_allocator_init(&state.track, rt.heap_allocator(), rt.heap_allocator())
    defer mem.tracking_allocator_destroy(&state.track)
    session, error := new_session(scope, ws79_small_config(), {}, {ws79_allocate, &state})
    if fail_at == 0 {
        testing.expect_value(t, error.kind, .None)
        assert(session != nil)
        view, viewed := budget.snapshot(scope)
        testing.expect_value(t, viewed, .None)
        testing.expect(t, view.used.bytes > 0)
        testing.expect_value(t, view.used.bytes, u64(state.track.current_memory_allocated))
        // Closing admission never refunds live backing or invalidates cleanup.
        assert(budget.close(scope) == .None)
        closed, closed_error := budget.snapshot(scope)
        testing.expect_value(t, closed_error, .None)
        testing.expect_value(t, closed.used, view.used)
        drop_session(session)
    } else {
        testing.expect(t, session == nil && error.kind != .None)
        testing.expect_value(t, state.failures, 1)
    }
    final, viewed := budget.snapshot(scope)
    testing.expect_value(t, viewed, .None)
    testing.expect_value(t, final.used, budget.Usage{})
    testing.expect_value(t, final.scope_nodes, u64(1))
    testing.expect_value(t, state.track.current_memory_allocated, i64(0))
    return state.calls
}

@(test)
constructor_backing_is_charged_until_physical_drop_and_every_failure_cleans_up :: proc(t: ^testing.T) {
    calls := ws79_constructor_run(t, 0)
    testing.expect(t, calls > 0)
    for failure in 1 ..= calls do ws79_constructor_run(t, failure)
}

@(test)
closed_connection_scope_cannot_admit_a_new_session :: proc(t: ^testing.T) {
    scope, created := budget.create_root({bytes = 1 << 20, streams = 1, jobs = 1})
    assert(created == .None)
    defer budget.release_scope(&scope)
    assert(budget.close(scope) == .None)
    session, error := new_session(scope, ws79_small_config(), {}, rt.heap_allocator())
    testing.expect(t, session == nil && error.kind != .None)
    view, viewed := budget.snapshot(scope)
    testing.expect_value(t, viewed, .None)
    testing.expect_value(t, view.used, budget.Usage{})
}

@(test)
failed_send_allocation_preserves_existing_queue_and_releases_failed_grant :: proc(t: ^testing.T) {
    scope, created := budget.create_root({bytes = 1 << 20, streams = 1, jobs = 1})
    assert(created == .None)
    defer budget.release_scope(&scope)
    state: WS79_Allocator
    mem.tracking_allocator_init(&state.track, rt.heap_allocator(), rt.heap_allocator())
    defer mem.tracking_allocator_destroy(&state.track)
    session, error := new_session(scope, ws79_small_config(), {}, {ws79_allocate, &state})
    assert(error.kind == .None)
    session.opened = true
    io := IO{_session = session, _active = true}
    testing.expect_value(t, send(&io, .Text, []u8{'o', 'k'}), .Accepted)
    before, viewed := budget.snapshot(scope)
    assert(viewed == .None)
    state.fail_at = state.calls + 1
    testing.expect_value(t, send(&io, .Binary, []u8{1, 2}), .Allocation_Failed)
    testing.expect_value(t, state.failures, 1)
    testing.expect_value(t, session.output_count, 1)
    testing.expect_value(t, string(session.outputs[0].payload), "ok")
    testing.expect_value(t, session.metrics.queued_bytes, 2)
    after, after_error := budget.snapshot(scope)
    testing.expect_value(t, after_error, .None)
    testing.expect_value(t, after.used, before.used)
    drop_session(session)
    final, final_error := budget.snapshot(scope)
    testing.expect_value(t, final_error, .None)
    testing.expect_value(t, final.used, budget.Usage{})
    testing.expect_value(t, state.track.current_memory_allocated, i64(0))
}

@(test)
lazy_message_and_frame_allocation_failure_keep_existing_owners_until_drop :: proc(t: ^testing.T) {
    for writing in ([]bool{false, true}) {
        scope, created := budget.create_root({bytes = 1 << 20, streams = 1, jobs = 1})
        assert(created == .None)
        runtime: async.Runtime
        assert(async.init(&runtime, {workers = 1, task_capacity = 1, io_capacity = 1}).kind == .None)
        conn: core.Connection
        transport := core.Upgrade_IO{runtime = &runtime, connection = &conn}
        state: WS79_Allocator
        mem.tracking_allocator_init(&state.track, rt.heap_allocator(), rt.heap_allocator())
        session, error := new_session(scope, ws79_small_config(), {}, {ws79_allocate, &state})
        assert(error.kind == .None)
        session.opened = true
        io := IO{_session = session, _transport = &transport, _active = true}
        reset_read(session, &io)
        if writing do assert(send(&io, .Text, []u8{'a'}) == .Accepted)
        before, viewed := budget.snapshot(scope); assert(viewed == .None)
        state.fail_at = state.calls + 1
        if writing {
            testing.expect_value(t, write_step(session, &io), .Done)
            testing.expect_value(t, session.event.reason, .IO_Error)
            testing.expect_value(t, session.output_count, 1)
            testing.expect(t, session.frame_wire == nil)
        } else {
            ws79_header(session, 0x82, 2)
            testing.expect_value(t, accept_header(session, &io), .Progress)
            testing.expect_value(t, session.event.message.kind, .Allocation_Failed)
            testing.expect_value(t, session.event.code, u16(1011))
        }
        testing.expect_value(t, state.failures, 1)
        after, after_error := budget.snapshot(scope); assert(after_error == .None)
        testing.expect_value(t, after.used, before.used)
        drop_session(session)
        final, final_error := budget.snapshot(scope); assert(final_error == .None)
        testing.expect_value(t, final.used, budget.Usage{})
        testing.expect_value(t, state.track.current_memory_allocated, i64(0))
        mem.tracking_allocator_destroy(&state.track)
        budget.release_scope(&scope)
        assert(async.destroy(&runtime).kind == .None)
    }
}
