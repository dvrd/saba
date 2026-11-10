package saba_websocket

import core "../core"
import rt "base:runtime"
import "core:mem"
import budget "core:sync/budget"
import "core:testing"

WS79_Application_Probe :: struct {
    opens, closes, drops: int,
    protocol: [256]u8,
    protocol_size: int,
}

ws79_application :: proc(probe: ^WS79_Application_Probe) -> Application {
    return {data = probe,
        on_open = proc(data: rawptr, io: ^IO) {
            probe := cast(^WS79_Application_Probe)data
            probe.opens += 1
            probe.protocol_size = copy(probe.protocol[:], subprotocol(io))
        },
        on_close = proc(data: rawptr, _: ^Close_Event) {
            (cast(^WS79_Application_Probe)data).closes += 1
        },
        drop = proc(data: rawptr) {(cast(^WS79_Application_Probe)data).drops += 1},
    }
}

ws79_headers :: proc() -> [5]core.Header {
    return {{"Upgrade", "websocket"}, {"Connection", "keep-alive, Upgrade"},
        {"Sec-WebSocket-Version", "13"},
        {"Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="}, {"Host", "example.test"}}
}

ws79_request :: proc(headers: []core.Header, allocator: mem.Allocator) -> core.Request {
    return {method = "GET", version = "HTTP/1.1", path = "/chat", headers = headers,
        allocator = allocator}
}

@(test)
failed_upgrade_keeps_application_owner_with_caller :: proc(t: ^testing.T) {
    probe: WS79_Application_Probe
    headers := ws79_headers()
    headers[2].value = "12"
    request := ws79_request(headers[:], context.allocator)
    response, error := upgrade(&request, {}, ws79_application(&probe))
    testing.expect(t, error.kind != .None)
    testing.expect(t, response.upgrade.data == nil)
    testing.expect_value(t, probe.opens, 0)
    testing.expect_value(t, probe.closes, 0)
    testing.expect_value(t, probe.drops, 0)
    core.discard_response(&response)
}

@(test)
committed_session_discard_drops_application_once_before_any_resume :: proc(t: ^testing.T) {
    scope, created := budget.create_root({bytes = 4 << 20, streams = 1, jobs = 1})
    assert(created == .None)
    defer budget.release_scope(&scope)
    probe: WS79_Application_Probe
    session, error := new_session(scope, {}, ws79_application(&probe), rt.heap_allocator())
    assert(error.kind == .None)
    session.owns_app = true
    response := core.Response{status = .Switching_Protocols,
        upgrade = {data = session, drop = drop_session}}
    // A failed HTTP101 write reaches this same public disposal contract.
    core.discard_response(&response)
    core.discard_response(&response)
    testing.expect_value(t, probe.opens, 0)
    testing.expect_value(t, probe.closes, 1)
    testing.expect_value(t, probe.drops, 1)
    view, viewed := budget.snapshot(scope)
    testing.expect_value(t, viewed, .None)
    testing.expect_value(t, view.used, budget.Usage{})
}

@(test)
missing_connection_context_rejects_without_using_request_arena :: proc(t: ^testing.T) {
    probe: WS79_Application_Probe
    headers := ws79_headers()
    request := ws79_request(headers[:], mem.panic_allocator())
    response, error := upgrade(&request, {}, ws79_application(&probe))
    testing.expect_value(t, error.kind, .Invalid_Context)
    testing.expect(t, response.upgrade.data == nil)
    testing.expect_value(t, probe.drops, 0)
    core.discard_response(&response)
}

@(test)
connection_budget_rejection_never_falls_back_to_unbounded_heap :: proc(t: ^testing.T) {
    scope, created := budget.create_root({bytes = 0, streams = 1, jobs = 1})
    assert(created == .None)
    defer budget.release_scope(&scope)
    session, error := new_session(scope, {}, {}, rt.heap_allocator())
    testing.expect(t, error.kind != .None)
    testing.expect(t, session == nil)
    snapshot, viewed := budget.snapshot(scope)
    testing.expect_value(t, viewed, .None)
    testing.expect_value(t, snapshot.used, budget.Usage{})
    testing.expect_value(t, snapshot.scope_nodes, u64(1))
    testing.expect(t, snapshot.rejected > 0)
}
