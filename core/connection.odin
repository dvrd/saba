package saba_core

import "core:log"
import "core:mem"
import "core:net"
import "core:crypto/tls"
import "core:sys/posix"
import "core:time"
import rt "base:runtime"
import budget "core:sync/budget"
import "core:sync"
import async "shared:async"
import store "core:crypto/tls/credentials/store"
import bridge "shared:async/connection"
import "core:strings"
import http "../../http"

Connection :: struct {
	_task: ^Connection_Task,
	_secure: bool,
	_peer_identity: tls.Peer_Identity,
	socket:         net.TCP_Socket,
	read_buffer:    []u8,
	read_deadline:  time.Tick,
	write_deadline: time.Tick,
	_timeouts:      Resolved_Timeouts,
}

deadline_expired :: proc(deadline: time.Tick) -> bool {
	return deadline != time.Tick{} && time.tick_diff(time.tick_now(), deadline) <= 0
}

wait_ready :: proc(
	client: net.TCP_Socket,
	events: posix.Poll_Event,
	deadline: time.Tick,
) -> (
	ready, timed_out: bool,
) {
	descriptor := posix.pollfd {
		fd     = posix.FD(client),
		events = events,
	}

	for {
		timeout_ms: i32 = -1
		if deadline != (time.Tick{}) {
			remaining := time.tick_diff(time.tick_now(), deadline)
			if remaining <= 0 do return false, true

			// Round up to milliseconds; -1 means no deadline, and zero means no wait.
			milliseconds := i64(remaining / time.Millisecond + 1)
			timeout_ms = cast(i32)min(milliseconds, cast(i64)max(i32))
		}

		descriptor.revents = {}
		result := posix.poll(&descriptor, 1, timeout_ms)
		if result < 0 {
			err := posix.errno()
			if err == .EINTR do continue
			log.error("Could not wait for socket readiness:", err, "| socket:", client)
			return false, false
		}
		if result == 0 do continue

		if .NVAL in descriptor.revents {
			log.error("Invalid socket while waiting for readiness | socket:", client)
			return false, false
		}

		// On hangup/error, let recv/send report EOF or the underlying socket error.
		if descriptor.revents & events != {} ||
		   .HUP in descriptor.revents ||
		   .ERR in descriptor.revents {
			return true, false
		}

		log.error("Unexpected socket readiness events:", descriptor.revents, "| socket:", client)
		return false, false
	}
}

read_connection :: proc(
	conn: ^Connection,
	buffer: []u8,
) -> (
	received: int,
	err: net.TCP_Recv_Error,
) {
	if conn._secure && len(conn.read_buffer) == 0 do return 0, .Unknown
	for {
		if deadline_expired(conn.read_deadline) do return 0, .Timeout

		if len(conn.read_buffer) > 0 {
			n := copy(buffer, conn.read_buffer)
			conn.read_buffer = conn.read_buffer[n:]

			return n, nil
		}

		n, read_err := net.recv_tcp(conn.socket, buffer)
		if read_err == .Interrupted do continue
		if read_err != .Would_Block do return n, read_err

		ready, timed_out := wait_ready(conn.socket, {.IN}, conn.read_deadline)
		if !ready {
			if timed_out do return 0, .Timeout
			return 0, .Unknown
		}
	}
}

write_connection :: proc(conn: ^Connection, data: []u8) -> (sent: int, err: net.TCP_Send_Error) {
	if conn._secure do return 0, .Unknown
	for {
		if deadline_expired(conn.write_deadline) do return sent, .Timeout
		if sent == len(data) do return sent, nil

		// Bound each call so sustained progress cannot bypass the deadline check.
		chunk := data[sent:min(sent + 64 * mem.Kilobyte, len(data))]
		n, send_err := net.send_tcp(conn.socket, chunk)
		sent += n

		if send_err == .Interrupted do continue
		if send_err == .Would_Block {
			ready, timed_out := wait_ready(conn.socket, {.OUT}, conn.write_deadline)
			if !ready {
				if timed_out do return sent, .Timeout
				return sent, .Unknown
			}
			continue
		}
		if send_err != nil do return sent, send_err
		if n != len(chunk) do return sent, .Connection_Closed
	}
}

DEFAULT_MAX_CONNECTIONS :: 4096
DEFAULT_INITIAL_CONNECTIONS :: 64
DEFAULT_WORKERS :: 4

@(private)
ACCEPT_BATCH_LIMIT :: 32
@(private)
ACCEPT_RETRY_INTERVAL :: 100 * time.Millisecond

Server :: struct {
	tls: ^TLS_Config,
	http3: Http3_Config,
	http2: Http2_Config,
	resources: Resource_Config,
	address:              string,
	port:                 int,
	// Admission ceiling; zero selects DEFAULT_MAX_CONNECTIONS.
	max_connections:      int,
	// Startup capacity; zero selects min(64, ceiling). Grows at 80% occupancy.
	initial_connections:  int,
	// Optional thread-safe allocator for runtime bookkeeping and worker setup.
	// Keep its state alive until serve returns; callbacks must not reenter
	// this server or its async runtime. Zero selects the heap allocator.
	runtime_allocator:    mem.Allocator,
	handler:              Handler,
	// Caller-owned state, immutable until serve returns.
	handler_data:         rawptr,
	request_body_limit:   proc(request: ^Request) -> int,
	// Zero leaves synchronous handlers without a deadline. Positive budgets are cooperative.
	handler_timeout: time.Duration,
	// Zero selects four workers; serve participates as one worker.
	workers:              int,
	// Optional caller-owned shutdown and endpoint control.
	control:              ^Server_Control,
	timeouts:             Timeout_Config,
	keep_alive:           Keep_Alive_Config,
	observability:        Observability_Config,
	// Zero selects five seconds; repeated drain calls never extend the deadline.
	drain_timeout:        time.Duration,
}

Server_Runtime :: struct {
	resources: budget.Scope,
	operation_limits, connection_limits: budget.Limits,
	config:                                  Server,
	cancellation: ^Server_Cancellation,
	logger:                                  log.Logger,
	executor:                                async.Runtime,
	accept_task:                             async.Task,
	http3: Http3,
	listener:                                async.Socket,
	accept_retry:                            async.Deadline,
	drain_mutex:                             sync.Mutex,
	draining:                                bool,
	drain_deadline:                          async.Deadline,
	capacity_mutex:                          sync.Mutex,
	capacity_state:                          Connection_Capacity,
	capacity_retry_at, capacity_warning_at:  time.Tick,
	capacity_retry_pending, capacity_warned: bool,
	listener_failed:                         bool,
	active_connections:                      int,
	timeouts:                                Resolved_Timeouts,
	observability_mutex:                     sync.Mutex,
	metrics:                                 Request_Metrics,
	next_request_id:                         u64,
	keep_alive_mutex:                        sync.Mutex,
	keep_alive_idle_tasks:                   ^Connection_Task,
}

// Handler and handler_data must remain valid until serve returns.
// Returns false on startup failure or an unrecoverable listener error.
serve :: proc(config: Server) -> bool {
	if !http2_config_valid(config.http2) {log.error("Invalid HTTP2 concurrency limit"); return false}
	if !tls_config_valid(config.tls) {log.error("Invalid TLS configuration"); return false}
	if !claim_server(config.control) {
		log.error("Server control is already in use")
		return false
	}
	defer release_server(config.control)
	if !drain_duration_valid(config.drain_timeout) {
		log.error("Invalid server drain_timeout")
		return false
	}
	initial, maximum, workers, valid := server_limits(config)
	if !valid do return false
	if !keep_alive_valid(config.keep_alive) {
		log.error("Invalid keep-alive request count or idle timeout")
		return false
	}
	if !http3_phases_valid(config.http3.request_phases) {log.error("Invalid HTTP3 phase policy");return false}
	if config.http3.request_timeout<0 || config.http3.request_timeout>MAX_SERVER_TIMEOUT {log.error("Invalid HTTP3 request timeout");return false}
	if config.handler_timeout<0 || config.handler_timeout>MAX_SERVER_TIMEOUT {log.error("Invalid handler timeout");return false}
	if !timeouts_valid(config.timeouts) {
		log.error("Invalid server timeouts: durations must be between zero and MAX_SERVER_TIMEOUT")
		return false
	}

	address_text := config.address
	if address_text == "" do address_text = "127.0.0.1"

	address, address_ok := net.parse_ip4_address(address_text)
	if !address_ok {
		log.error("Could not parse server address:", address_text)

		return false
	}

	runtime, allocation_error := new(Server_Runtime)
	if allocation_error != nil {
		log.error("Could not allocate server runtime:", allocation_error)
		return false
	}
	defer free(runtime)
    cancellation,ce:=new(Server_Cancellation,rt.heap_allocator())
    if ce!=nil || cancellation==nil do return false
    cancellation.references=1
    defer release_server_cancellation(cancellation)
	runtime^ = Server_Runtime {
		config = config,
		cancellation = cancellation,
		timeouts = resolve_timeouts(config.timeouts),
		logger = context.logger,
		capacity_state = {current = initial, maximum = maximum},
	}
	if !initialize_resources(runtime) do return false
	defer budget.release_scope(&runtime.resources)
	if err := async.init(
		&runtime.executor,
		{
			workers = workers,
			task_capacity = initial + workers + 2,
			io_capacity = initial + 1,
			allocator = config.runtime_allocator,
		},
	); err.kind != .None {
		log.error("Could not initialize server runtime:", err)
		return false
	}
	defer {
		unpublish_server(config.control)
		async.destroy(&runtime.executor)
	}
	if config.http3.enabled {
		runtime.http3.config = config.http3
		runtime.http3.runtime = runtime
		if _, ok := http3_listen(&runtime.http3); !ok {
			log.error("Could not start HTTP3 listener")
			return false
		}
		runtime.http3.task = {resume=http3_resume, data=&runtime.http3, on_done=http3_retire}
		if e := async.spawn(&runtime.executor, &runtime.http3.task); e.kind != .None {
			http3_close(&runtime.http3)
			return false
		}
	}
	runtime.accept_task = {
		resume = accept_connections,
		data   = runtime,
	}
	if err := async.register(&runtime.executor, &runtime.accept_task); err.kind != .None {
		log.error("Could not register listener task:", err)
		return false
	}
	listener, listen_error := async.listen(
		&runtime.executor,
		&runtime.accept_task,
		{address, config.port},
	)
	if listen_error.kind != .None {
		log.error("Could not start server:", listen_error)
		return false
	}
	runtime.listener = listener
	endpoint, endpoint_error := async.bound_endpoint(listener)
	if endpoint_error.kind != .None {
		log.error("Could not obtain listening address:", endpoint_error)
		return false
	}
	publish_server(config.control, runtime, endpoint)
	async.wake(&runtime.executor, &runtime.accept_task)
	log.infof("listening on %s://localhost:%d", "https" if config.tls != nil else "http", endpoint.port)
	err := async.run(&runtime.executor)
	if err.kind != .None && !(err.kind == .Stopping && server_stop_requested(config.control)) {
		log.error("Server runtime failed:", err)
		return false
	}
	return !runtime.listener_failed
}

@(private)
accept_connections :: proc(data: rawptr) -> async.Resume_Result {
	runtime := cast(^Server_Runtime)data
	context.logger = runtime.logger
	if server_is_draining(runtime) do return drain_connections(runtime)
	if runtime.accept_retry.at != 0 {
		err := async.sleep_until(&runtime.executor, runtime.accept_retry)
		if err.kind == .Pending do return .Waiting
		if err.kind != .None do return .Done
		runtime.accept_retry = {}
	}
	for _ in 0 ..< ACCEPT_BATCH_LIMIT {
		if async.cancelled(&runtime.accept_task) do return .Done
		if server_is_draining(runtime) do return drain_connections(runtime)
		client, err := async.accept(runtime.listener)
		if err.kind == .Pending do return .Waiting
		if err.kind == .Cancelled || err.kind == .Closed do return .Done
		if err.kind != .None {
			log.error("Could not accept connection:", err)
			cause, _ := err.network_cause.(net.Accept_Error)
			if err.kind != .Network_Error ||
			   cause == .Invalid_Argument ||
			   cause == .Unsupported_Socket ||
			   cause == .Not_Listening {
				runtime.listener_failed = true
				shutdown_runtime(runtime)
				return .Done
			}
			runtime.accept_retry = async.deadline_after(&runtime.executor, ACCEPT_RETRY_INTERVAL)
			if async.sleep_until(&runtime.executor, runtime.accept_retry).kind == .Pending {
				return .Waiting
			}
			return .Yield
		}
		server_admit_connection(runtime, client)
	}
	return .Yield
}

@(private)
reject_connection :: proc(client: net.TCP_Socket, secure: bool) {
	defer net.close(client)
	if secure do return
	if net.set_blocking(client, false) != nil do return
	buffer: [RESPONSE_HEADER_LIMIT]u8
	headers, ready := response_headers(Response{status = .Service_Unavailable}, buffer[:])
	// Best effort only: waiting for a rejected client would stall acceptance.
	if ready do net.send_tcp(client, headers)
}

@(private)
server_admit_connection :: proc(runtime: ^Server_Runtime, client: net.TCP_Socket) {
	// Reserve admission before the drain cutoff. Only this accept task publishes
	// connections, so the drain monitor cannot overtake an accepted reservation.
	// Do not hold the mutex across allocation or application logging callbacks.
	sync.lock(&runtime.drain_mutex)
	allowed := !runtime.draining
	sync.unlock(&runtime.drain_mutex)
	if !allowed {reject_connection(client, runtime.config.tls != nil); return}
	if !server_capacity_admit(runtime) {
		reject_connection(client, runtime.config.tls != nil)
		return
	}
	task, allocation_error := new(Connection_Task)
	if allocation_error != nil {
		server_capacity_allocation_failed(runtime)
		reject_connection(client, runtime.config.tls != nil)
		return
	}
	task^ = {
		runtime = runtime,
		native_pending = true,
		phase = .Adopt,
		connection = {socket = client, _timeouts = runtime.timeouts},
	}
	if !start_connection_resources(task) {
		server_capacity_allocation_failed(runtime)
		budget.release_scope(&task.resource_connection)
		reject_connection(client, runtime.config.tls != nil)
		free(task)
		return
	}
	init_connection_arena(task)
	task.task = {
		resume  = handle_connection,
		data    = task,
		on_done = finish_connection,
		on_cancel = connection_cancel,
	}
	// Publish fully initialized storage. Adoption happens inside its first
	// resume, so shutdown can safely dispose even an unexecuted task.
	sync.atomic_add(&runtime.active_connections, 1)
	if async.spawn(&runtime.executor, &task.task).kind != .None {
		sync.atomic_sub(&runtime.active_connections, 1)
		server_capacity_allocation_failed(runtime)
		reject_connection(client, runtime.config.tls != nil)
		mem.dynamic_arena_destroy(&task.arena)
		finish_operation_resources(task)
		budget.release_scope(&task.resource_connection)
		free(task)
	}
}

// Nil Server.tls preserves HTTP. Config, store and callbacks outlive serve.
// Store replacement is thread-safe; Core pins each admitted credential generation.
TLS_Config :: struct {
	store: ^store.Store,
	client_auth: ^tls.Client_Auth_Config,
	tickets:^tls.Server_Ticket_Config,
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
	peer_identity: tls.Peer_Identity,
	resumed:bool,
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
	if !tls.server_ticket_config_valid(config.tickets) || !tls.client_auth_config_valid(config.client_auth) || config.store == nil || config.handshake_timeout < 0 ||
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
		handshake = {client_auth=config.client_auth,tickets=config.tickets},
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
		peer_identity=tls.server_async_connection_state(&state.owner).peer_identity,
  resumed=tls.server_async_connection_state(&state.owner).resumed,
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
			tls_event(task, .Handshake)
			tls_start_close(task, false)
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

// Authenticated identity only; the digest is an owned value, never a borrow of
// handshake certificate storage. Empty before successful mutual authentication.
tls_peer_identity :: proc(connection:^Connection)->tls.Peer_Identity {
 if connection==nil||connection._task==nil {return {}}
 if connection._task.tls_state==nil {return connection._peer_identity}
 return tls.server_async_connection_state(&connection._task.tls_state.owner).peer_identity
}

// All budgets are total phase deadlines; progress never extends them. Zero
// selects existing defaults. Idle is first-byte wait only: HTTP/1 currently
// closes after each response and has no keep-alive idle phase.
Timeout_Config :: struct {
	header, body, response, idle: time.Duration,
}

MAX_SERVER_TIMEOUT :: 24 * time.Hour
REQUEST_HEADER_TIMEOUT :: 5 * time.Second
REQUEST_BODY_TIMEOUT :: 5 * time.Second
RESPONSE_SEND_TIMEOUT :: 5 * time.Second

@(private)
Resolved_Timeouts :: struct {
	header, body, large_body, response, idle: time.Duration,
}

// Public validation is side-effect free and safe before creating a listener.
timeouts_valid :: proc(config: Timeout_Config) -> bool {
	for value in ([4]time.Duration{config.header, config.body, config.response, config.idle}) {
		if value < 0 || value > MAX_SERVER_TIMEOUT do return false
	}
	return true
}

@(private)
resolve_timeouts :: proc(config: Timeout_Config) -> Resolved_Timeouts {
	result := Resolved_Timeouts{
		header = REQUEST_HEADER_TIMEOUT,
		body = REQUEST_BODY_TIMEOUT,
		large_body = 30 * time.Second,
		response = RESPONSE_SEND_TIMEOUT,
	}
	if config.header > 0 do result.header = config.header
	if config.body > 0 do result.body, result.large_body = config.body, config.body
	if config.response > 0 do result.response = config.response
	result.idle = result.header
	if config.idle > 0 do result.idle = min(result.header, config.idle)
	return result
}

@(private)
body_timeout :: proc(timeouts: Resolved_Timeouts, size: int) -> time.Duration {
	if size > REQUEST_BODY_LIMIT do return timeouts.large_body
	return timeouts.body
}

DEFAULT_KEEP_ALIVE_REQUESTS :: 100
MAX_KEEP_ALIVE_REQUESTS :: 10000

// Disabled preserves connection-close behavior. Requests run strictly serially.
// Zero request count selects100; zero idle inherits Server.timeouts.idle.
Keep_Alive_Config :: struct {
	enabled: bool,
	max_requests: int,
	idle_timeout: time.Duration,
}

keep_alive_valid :: proc(config: Keep_Alive_Config) -> bool {
	return config.max_requests >= 0 && config.max_requests <= MAX_KEEP_ALIVE_REQUESTS &&
		config.idle_timeout >= 0 && config.idle_timeout <= MAX_SERVER_TIMEOUT
}

@(private)
keep_alive_request_limit :: proc(config: Keep_Alive_Config) -> int {
	if config.max_requests == 0 do return DEFAULT_KEEP_ALIVE_REQUESTS
	return config.max_requests
}

@(private)
keep_alive_idle_timeout :: proc(runtime: ^Server_Runtime) -> time.Duration {
	if runtime.config.keep_alive.idle_timeout > 0 do return runtime.config.keep_alive.idle_timeout
	return runtime.timeouts.idle
}

@(private)
request_wants_close :: proc(request: ^Request) -> bool {
	for header in request.headers {
		if !strings.equal_fold(header.name, "Connection") do continue
		remaining := strings.trim_space(header.value)
		if remaining == "" || strings.has_suffix(remaining, ",") do return true
		for token in strings.split_iterator(&remaining, ",") {
			value := strings.trim_space(token)
			// Invalid token lists conservatively disable persistence.
			if !http.header_name_valid(value) || strings.equal_fold(value, "close") do return true
		}
	}
	return false
}

@(private)
response_can_reuse :: proc(task: ^Connection_Task, status: HTTP_Status) -> bool {
	if !task.runtime.config.keep_alive.enabled || task.phase != .Dispatch do return false
	if (status != .None && status < .OK) || request_wants_close(&task.request) do return false
	if task.requests_completed + 1 >= keep_alive_request_limit(task.runtime.config.keep_alive) do return false
	if async.cancelled(&task.task) || server_is_draining(task.runtime) do return false
	return true
}

// Only idle tasks are listed. Drain wakes them once, rather than adding a timer
// poll or a per-connection thread. Runtime drain_mutex is always released before
// drain takes this list lock, so admission may check drain while holding it.
@(private)
keep_alive_remove_idle_locked :: proc(task: ^Connection_Task) {
	if !task.idle_registered do return
	if task.idle_previous != nil do task.idle_previous.idle_next = task.idle_next
	else do task.runtime.keep_alive_idle_tasks = task.idle_next
	if task.idle_next != nil do task.idle_next.idle_previous = task.idle_previous
	task.idle_previous, task.idle_next = nil,nil
	task.idle_registered = false
}

@(private)
keep_alive_leave_idle :: proc(task: ^Connection_Task) {
	if !task.idle_registered do return
	sync.lock(&task.runtime.keep_alive_mutex)
	keep_alive_remove_idle_locked(task)
	sync.unlock(&task.runtime.keep_alive_mutex)
}

@(private)
keep_alive_enter_idle :: proc(task: ^Connection_Task) -> bool {
	runtime := task.runtime
	sync.lock(&runtime.keep_alive_mutex)
	defer sync.unlock(&runtime.keep_alive_mutex)
	if server_is_draining(runtime) || async.cancelled(&task.task) do return false
	if task.idle_registered do return true
	task.idle_previous = nil
	task.idle_next = runtime.keep_alive_idle_tasks
	if task.idle_next != nil do task.idle_next.idle_previous = task
	runtime.keep_alive_idle_tasks = task
	task.idle_registered = true
	return true
}

@(private)
wake_keep_alive_connections :: proc(runtime: ^Server_Runtime) {
	sync.lock(&runtime.keep_alive_mutex)
	defer sync.unlock(&runtime.keep_alive_mutex)
	for task := runtime.keep_alive_idle_tasks; task != nil; task = task.idle_next {
		async.wake(&runtime.executor, &task.task)
	}
}

// The first byte, including saved pipelined bytes, admits one request atomically
// against drain. All locks are released before metrics or application callbacks.
@(private)
keep_alive_begin_request :: proc(task: ^Connection_Task, count: int) -> bool {
	runtime := task.runtime
	sync.lock(&runtime.keep_alive_mutex)
	sync.lock(&runtime.drain_mutex)
	admitted := !runtime.draining && !async.cancelled(&task.task)
	keep_alive_remove_idle_locked(task)
	sync.unlock(&runtime.drain_mutex)
	sync.unlock(&runtime.keep_alive_mutex)
	if !admitted do return false
	observe_start(task)
	if task.observed do task.event.bytes_received = u64(count)
	task.header_used = count
	task.header_deadline = async.deadline_after(&runtime.executor, runtime.timeouts.header)
	task.header_read_deadline = time.tick_add(time.tick_now(), runtime.timeouts.header)
	task.deadline = task.header_deadline
	task.connection.read_deadline = task.header_read_deadline
	task.connection.write_deadline = {}
	task.phase = .Headers
	return true
}

// At most one bounded header-buffer read can contain the next request. Save it
// on this worker's ordinary stack while releasing every previous arena block;
// no response/body borrow survives the completion callback and this reset.
@(private)
keep_alive_next_request :: #force_no_inline proc(task: ^Connection_Task) -> bool {
	finish_request_context(task)
	observe_finish(task)
	if server_is_draining(task.runtime) || async.cancelled(&task.task) do return false
	remaining := task.connection.read_buffer
	if len(remaining) > REQUEST_HEADER_LIMIT do return false
	saved: [REQUEST_HEADER_LIMIT]u8
	count := copy(saved[:], remaining)
	task.connection.read_buffer = nil
	task.request = {}
	task.chunked = nil
	task.output = {}
	task.header = nil
	mem.dynamic_arena_destroy(&task.arena)
	finish_operation_resources(task)
	task.observed, task.observation_finished, task.response_finished = false,false,false
	task.event = {}
	task.observed_at = {}
	if !start_operation_resources(task) {
		if count > 0 do return keep_alive_resource_reject(task, count)
		return false
	}
	init_connection_arena(task)
	task.header_used, task.body_used = 0,0
	task.output_index, task.output_offset = 0,0
	task.reuse_after_write = false
	task.finish_after_write = true
	task.header = task.initial_header[:]
	if count > len(task.header) {
		buffer, err := make([]u8,count,mem.dynamic_arena_allocator(&task.arena))
		if err != nil {
			if resource_pressure(task) do return keep_alive_resource_reject(task, count)
			return false
		}
		task.header = buffer
	}
	copy(task.header,saved[:count])
	if count > 0 do return keep_alive_begin_request(task,count)
	task.deadline = async.deadline_after(&task.runtime.executor, keep_alive_idle_timeout(task.runtime))
	task.connection.read_deadline = time.tick_add(time.tick_now(), keep_alive_idle_timeout(task.runtime))
	task.connection.write_deadline = {}
	task.phase = .Idle
	return keep_alive_enter_idle(task)
}

@(private)
keep_alive_resource_reject :: proc(task: ^Connection_Task, count: int) -> bool {
	if !keep_alive_begin_request(task, 0) do return false
	if task.observed do task.event.bytes_received = u64(count)
	return resource_reject(task)
}
