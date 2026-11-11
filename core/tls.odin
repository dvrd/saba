package saba_core

import tls "core:crypto/tls"
import store "core:crypto/tls/credentials/store"
import "core:mem"
import "core:net"
import "core:time"
import async "shared:async"
import bridge "shared:async/connection"

// Nil Server.tls preserves HTTP. Config, store and callbacks outlive serve.
// Store replacement is thread-safe; Core pins each admitted credential generation.
TLS_Config :: struct {
	store: ^store.Store,
	handshake_timeout, close_timeout: time.Duration,
	max_owned_bytes, max_handshake_records: int,
	on_event: proc(data: rawptr, event: ^TLS_Event),
	data: rawptr,
}
TLS_Event_Kind :: enum {Handshake, Closed}
// Values and protocol strings borrow only until callback return. No keys or
// certificate contents are exposed. Callbacks run outside locks on the owner.
TLS_Event :: struct {
	kind: TLS_Event_Kind,
	handshake_complete: bool,
	error, close_error: net.Connection_Error,
	failure: tls.Server_Async_Failure,
	negotiated_protocol: string,
	stats: tls.Server_Async_Stats,
	callbacks, write_waits, transport_partial_writes: u64,
}

@(private)
TLS_State :: struct {
	owner: tls.Server_Async_Conn,
	executor: bridge.Executor,
	transport: bridge.Transport,
	handshake: tls.Server_Async_Handshake_Operation,
	read, write, close: net.Async_Operation,
	initialized, handshake_done, ready, closing, close_done: bool,
	read_started, read_done, write_started, write_done: bool,
	read_retarget, handshake_reported: bool,
	read_phase: Connection_Phase,
	read_deadline: async.Deadline,
	input: [16 * mem.Kilobyte]u8,
	// Server preference: h2 when the client offers it, otherwise http/1.1.
	// h3 is not a token on this TCP listener.
	protocols: [2]string,
	protocol: [8]u8,
	protocol_len: int,
	negotiated: bool,
	input_at: int,
	error: net.Connection_Error,
	handshake_deadline: async.Deadline,
}

@(private)
tls_config_valid :: proc(config: ^TLS_Config) -> bool {
	if config == nil do return true
	if config.store == nil || config.handshake_timeout < 0 ||
	   config.handshake_timeout > MAX_SERVER_TIMEOUT || config.close_timeout < 0 ||
	   config.close_timeout > MAX_SERVER_TIMEOUT {return false}
	if config.max_owned_bytes != 0 &&
	   (config.max_owned_bytes < 1024 || config.max_owned_bytes > tls.SERVER_ASYNC_MAX_OWNED_BYTES) {return false}
	if config.max_handshake_records < 0 || config.max_handshake_records > 65536 do return false
	stats, error := store.stats(config.store)
	return error.kind == .None && !stats.closed && stats.current_generation != 0
}

@(private)
tls_begin :: proc(task: ^Connection_Task) -> bool {
	config := task.runtime.config.tls
	allocator := connection_storage_allocator(task)
	if allocator.procedure == nil do return false
	state, error := new(TLS_State, allocator)
	if error != nil do return false
	task.tls_state = state
	if bridge.init_executor(&state.executor, &task.runtime.executor, &task.task).kind != .None do return false
	if bridge.init_transport(&state.transport, &state.executor, task.socket).kind != .None do return false
	state.protocols = {"h2", "http/1.1"}
	settings := tls.Server_Async_Config {
		store = config.store, handshake_timeout = config.handshake_timeout,
		close_timeout = config.close_timeout, max_owned_bytes = config.max_owned_bytes,
		max_handshake_records = config.max_handshake_records,
		parameters = {alpn_protocols = state.protocols[:]},
	}
	if tls.server_async_server(&state.owner, bridge.stream(&state.transport),
		bridge.executor(&state.executor), settings, allocator) != .None {return false}
	state.initialized = true
	state.handshake = {callback = tls_handshake_done, user_data = state}
	state.read = {callback = tls_read_done, user_data = state}
	state.write = {callback = tls_write_done, user_data = state}
	state.close = {callback = tls_close_done, user_data = state}
	duration := config.handshake_timeout
	if duration == 0 do duration = 10 * time.Second
	state.handshake_deadline = async.deadline_after(&task.runtime.executor, duration)
	if bridge.set_request_budget(&state.executor, state.handshake_deadline).kind != .None do return false
	state.error = tls.server_async_handshake(&state.owner, &state.handshake, bridge.wall_budget(&state.executor))
	return state.error.kind == .None
}

@(private)
tls_handshake_done :: proc(op: ^tls.Server_Async_Handshake_Operation) {
	state := cast(^TLS_State)op.user_data
	state.handshake_done = true
	if state.error.kind == .None do state.error = op.err
	if state.error.kind == .None do state.error = bridge.budget_error(&state.executor)
}
@(private)
tls_read_done :: proc(op: ^net.Async_Operation) { (cast(^TLS_State)op.user_data).read_done = true }
@(private)
tls_write_done :: proc(op: ^net.Async_Operation) { (cast(^TLS_State)op.user_data).write_done = true }
@(private)
tls_close_done :: proc(op: ^net.Async_Operation) {
	state := cast(^TLS_State)op.user_data
	state.close_done = true
	if state.error.kind == .None && op.result.err.kind != .None do state.error = op.result.err
}

@(private)
tls_event :: proc(task: ^Connection_Task, kind: TLS_Event_Kind) {
	config := task.runtime.config.tls
	if kind == .Handshake do task.tls_state.handshake_reported = true
	if config.on_event == nil do return
	state := task.tls_state
	event := TLS_Event {kind = kind, handshake_complete = state.ready,
		error = state.error, close_error = state.close.result.err,
	failure = tls.server_async_failure(&state.owner),
		negotiated_protocol = string(state.protocol[:state.protocol_len]),
		stats = tls.server_async_stats(&state.owner), callbacks = state.executor.callbacks,
		write_waits = state.executor.write_waits, transport_partial_writes = state.executor.partial_writes}
	config.on_event(config.data, &event)
}

@(private)
tls_start_close :: proc(task: ^Connection_Task, abort: bool) {
	state := task.tls_state
	if state.closing do return
	state.closing = true
	if abort {
		if state.error.kind == .None do state.error = {kind = .Cancelled}
		tls.server_async_cancel_handshake(&state.owner)
	}
	error := net.async_close(tls.server_async_connection(&state.owner), &state.close)
	if error.kind != .None {
		state.error = error
		// Core's stable owner accepts exactly one close after successful init.
		// A rejection is an invariant failure; never free pending TLS callbacks.
		assert(false, "TLS close rejected on a live Saba owner")
	}
	if abort do bridge.abort(&state.executor)
}

@(private)
handle_connection :: proc(data: rawptr) -> async.Resume_Result {
	task := cast(^Connection_Task)data
	state := task.tls_state
	if state == nil || !state.initialized {
		step := handle_http(data)
		state = task.tls_state
		if state == nil || !state.initialized do return step
		if step == .Done do tls_start_close(task, true)
	}
	if async.cancelled(&task.task) do tls_start_close(task, true)
	if !state.closing && state.handshake_done && !state.ready {
		if state.error.kind != .None {
			tls_event(task, .Handshake); tls_start_close(task, false)
		} else if bridge.set_request_budget(&state.executor, {}).kind == .None {
			state.ready = true
			selected := tls.server_async_connection_state(&state.owner).negotiated_protocol
			state.protocol_len = 0
			if selected == "h2" || selected == "http/1.1" {
				state.protocol_len = copy(state.protocol[:], selected)
			}
			state.negotiated = state.protocol_len > 0
			tls_event(task, .Handshake)
			if selected == "h2" {
				if !h2_begin(task) {
					tls_start_close(task, false)
				} else {
					task.phase = .HTTP2
				}
			} else {
				begin_http_headers(task)
			}
		}
	}
	http_step := async.Resume_Result.Waiting
	if !state.closing && state.ready {
		http_step = handle_http(data)
		if http_step == .Done do tls_start_close(task, false)
	}
	if !state.closing && state.read_started && state.read_phase != task.phase {
		tls_retarget_read(state)
	}
	read_was_done, write_was_done := state.read_done, state.write_done
	step := bridge.drive(&state.executor)
	if state.closing && state.close_done && bridge.quiescent(&state.executor) {
		if !state.handshake_reported do tls_event(task, .Handshake)
		tls_event(task, .Closed)
		return .Done
	}
	if state.handshake_done && !state.ready && !state.closing do return .Yield
	completed := (state.read_done && !read_was_done) || (state.write_done && !write_was_done)
	if !state.closing && (completed || http_step == .Yield) do return .Yield
	return step
}

@(private)
connection_cancel :: proc(data: rawptr) -> async.Resume_Result {
	task := cast(^Connection_Task)data
	if task.tls_state == nil || !task.tls_state.initialized do return .Done
	tls_start_close(task, true)
	return handle_connection(data)
}

@(private)
begin_http_headers :: proc(task: ^Connection_Task) {
	task.header = task.initial_header[:]
	task.header_deadline = async.deadline_after(&task.runtime.executor, task.runtime.timeouts.header)
	task.header_read_deadline = time.tick_add(time.tick_now(), task.runtime.timeouts.header)
	task.deadline = async.deadline_after(&task.runtime.executor, task.runtime.timeouts.idle)
	task.connection.read_deadline = time.tick_add(time.tick_now(), task.runtime.timeouts.idle)
	task.phase = .Headers
}

@(private)
tls_translate :: proc(error: net.Connection_Error) -> async.Error {
	#partial switch error.kind {
	case .None: return {}
	case .Timeout: return {kind = .Timeout}
	case .Cancelled: return {kind = .Cancelled}
	case .Peer_Closed: return {kind = .Peer_Closed}
	case .Closed: return {kind = .Closed}
	case: return {kind = .Network_Error}
	}
}

@(private)
tls_deadline_valid :: proc(task: ^Connection_Task, deadline: async.Deadline) -> bool {
	if deadline.epoch == 0 do return deadline.at == 0
	now := async.deadline_after(&task.runtime.executor, 0)
	return deadline.epoch == now.epoch
}

@(private)
tls_wall_deadline :: proc(task: ^Connection_Task, deadline: async.Deadline) -> time.Time {
	if deadline.epoch == 0 do return {}
	now := async.deadline_after(&task.runtime.executor, 0)
	return time.time_add(time.now(), time.Duration(max(i64(0), deadline.at - now.at)))
}

// A pending plaintext read uses stable staging. Retire its old phase deadline
// before the next read; authenticated bytes that won cancellation stay buffered.
@(private)
tls_retarget_read :: proc(state: ^TLS_State) {
	if state.read_retarget do return
	state.read_retarget = true
	if state.read.pending do net.async_cancel(tls.server_async_connection(&state.owner), &state.read)
}

@(private)
transport_read :: proc(task: ^Connection_Task, destination: []u8, deadline: async.Deadline) -> (int, async.Error) {
	state := task.tls_state
	if state == nil do return async.read(task.socket, destination, deadline)
	if !tls_deadline_valid(task, deadline) do return 0, {kind = .Invalid_Config}
	if state.read_started && (state.read_phase != task.phase || state.read_deadline != deadline) {
		tls_retarget_read(state)
	}
	if state.read_done && state.read_retarget {
		if state.read.result.err.kind == .Cancelled || state.read.result.err.kind == .Timeout {
			state.read.result.err = {}
			if state.read.result.count == 0 do state.read_started, state.read_done = false, false
		}
		state.read_retarget = false
	}
	if state.read_done {
		count := min(len(destination), state.read.result.count - state.input_at)
		copy(destination[:count], state.input[state.input_at:state.input_at + count])
		state.input_at += count
		if state.input_at < state.read.result.count do return count, {}
		state.read_started, state.read_done, state.input_at = false, false, 0
		if state.read.result.err.kind != .None do state.error = state.read.result.err
		return count, tls_translate(state.read.result.err)
	}
	if !state.read_started {
		state.read_started = true
		state.read_phase, state.read_deadline = task.phase, deadline
		error := net.async_read(tls.server_async_connection(&state.owner), &state.read,
			state.input[:min(len(destination), len(state.input))], tls_wall_deadline(task, deadline))
		if error.kind != .None {state.read_started = false; return 0, tls_translate(error)}
	}
	return 0, {kind = .Pending}
}

@(private)
transport_write :: proc(task: ^Connection_Task, source: []u8, deadline: async.Deadline) -> (int, async.Error) {
	state := task.tls_state
	if state == nil do return async.write(task.socket, source, deadline)
	if !tls_deadline_valid(task, deadline) do return 0, {kind = .Invalid_Config}
	if state.write_done {
		state.write_started, state.write_done = false, false
		if state.write.result.err.kind != .None do state.error = state.write.result.err
		return state.write.result.count, tls_translate(state.write.result.err)
	}
	if !state.write_started {
		state.write_started = true
		error := net.async_write(tls.server_async_connection(&state.owner), &state.write,
			source, tls_wall_deadline(task, deadline))
		if error.kind != .None {state.write_started = false; return 0, tls_translate(error)}
	}
	return 0, {kind = .Pending}
}
