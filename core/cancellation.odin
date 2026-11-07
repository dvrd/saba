package saba_core

import rt "base:runtime"
import "core:mem"
import "core:sync"
import "core:time"
import async "shared:async"

Request_Status :: enum {
	Active,
	Unavailable,
	Completed,
	Deadline,
	Shutdown,
	Peer_Closed,
	Failed,
}

// Request.cancellation is borrowed during the handler. Retain explicitly for
// other work; each owned handle must be released once. Neither node retains the
// request arena, connection, runtime, socket, or response. Copies are aliases.
Request_Context :: struct {
	_state: ^Request_Cancellation,
}

@(private)
Server_Cancellation :: struct {
	references: i64,
	stopping:   bool,
	drain_at:   i64,
}
@(private)
Request_Cancellation :: struct {
	references: i64,
	status:     Request_Status,
	deadline:   time.Tick,
	server:     ^Server_Cancellation,
	allocator:  mem.Allocator,
}

retain_request_context :: proc(source: Request_Context) -> (Request_Context, bool) {
	if source._state == nil do return {}, false
	previous := sync.atomic_add(&source._state.references, 1)
	assert(previous > 0 && previous < max(i64))
	return source, true
}

release_request_context :: proc(owner: ^Request_Context) {
	if owner == nil do return
	node := owner._state; owner^ = {}
	if node == nil do return
	if sync.atomic_sub(&node.references, 1) == 1 {
		release_server_cancellation(node.server)
		free(node, node.allocator)
	}
}

request_deadline :: proc(ctx: Request_Context) -> time.Tick {
	if ctx._state == nil do return {}
	return ctx._state.deadline
}

// Terminal status is first-observed and stable. Deadline polling is monotonic;
// shutdown remains observable by retained owners even after serve returns.
request_context_status :: proc(ctx: Request_Context) -> Request_Status {
	node := ctx._state
	if node == nil do return .Unavailable
	current := sync.atomic_load(&node.status)
	if current != .Active do return current
	if node.server != nil && sync.atomic_load(&node.server.stopping) {
		cancel_request_context(ctx, .Shutdown)
	} else if node.server != nil && server_cancellation_expired(node.server) {
		cancel_request_context(ctx, .Shutdown)
	} else if deadline_expired(node.deadline) {
		cancel_request_context(ctx, .Deadline)
	}
	return sync.atomic_load(&node.status)
}

request_cancelled :: proc(ctx: Request_Context) -> bool {
	status := request_context_status(ctx)
	return status != .Active && status != .Unavailable
}

@(private)
cancel_request_context :: proc(ctx: Request_Context, status: Request_Status) {
	if ctx._state == nil do return
	assert(status != .Active && status != .Unavailable)
	sync.atomic_compare_exchange_strong(&ctx._state.status, .Active, status)
}

@(private)
new_request_context :: proc(
	server: ^Server_Cancellation,
	deadline: time.Tick,
	allocator: mem.Allocator,
) -> (
	Request_Context,
	bool,
) {
	node, error := new(Request_Cancellation, allocator)
	if error != nil || node == nil do return {}, false
	node^ = {
		references = 1,
		deadline   = deadline,
		server     = server,
		allocator  = allocator,
	}
	if server != nil do sync.atomic_add(&server.references, 1)
	return {node}, true
}

@(private)
release_server_cancellation :: proc(state: ^Server_Cancellation) {
	if state != nil && sync.atomic_sub(&state.references, 1) == 1 do free(state, rt.heap_allocator())
}

@(private)
shutdown_runtime :: proc(runtime: ^Server_Runtime) {
	if runtime.cancellation != nil do sync.atomic_store(&runtime.cancellation.stopping, true)
	// Existing shutdown owns sockets, task cancellation and worker joins.
	async.shutdown(&runtime.executor)
}

@(private)
begin_request_context :: proc(task: ^Connection_Task) -> bool {
	if task.request.cancellation._state != nil do return true
	deadline: time.Tick
	if task.runtime.config.handler_timeout > 0 do deadline = time.tick_add(time.tick_now(), task.runtime.config.handler_timeout)
	ctx, ok := new_request_context(task.runtime.cancellation, deadline, rt.heap_allocator())
	if !ok do return false
	task.request.cancellation = ctx
	return true
}

@(private)
finish_request_context :: proc(task: ^Connection_Task) {
	ctx := task.request.cancellation
	if ctx._state == nil do return
	_ = request_context_status(ctx)
	status: Request_Status = .Completed
	if !task.response_finished {
		status = .Failed
	}
	if async.cancelled(&task.task) {
		status = .Shutdown
	}
	cancel_request_context(ctx, status)
	release_request_context(&task.request.cancellation)
}

@(private)
server_cancellation_expired :: proc(state: ^Server_Cancellation) -> bool {
	at := sync.atomic_load(&state.drain_at)
	return at != 0 && deadline_expired(time.tick_add({}, time.Duration(at)))
}
