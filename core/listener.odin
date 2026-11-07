package saba_core

import "core:log"
import "core:mem"
import "core:net"
import "core:sync"
import "core:time"

import async "shared:async"

DEFAULT_MAX_CONNECTIONS :: 4096
DEFAULT_INITIAL_CONNECTIONS :: 64
DEFAULT_WORKERS :: 4

@(private)
ACCEPT_BATCH_LIMIT :: 32
@(private)
ACCEPT_RETRY_INTERVAL :: 100 * time.Millisecond

Server :: struct {
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
	config:                                  Server,
	logger:                                  log.Logger,
	executor:                                async.Runtime,
	accept_task:                             async.Task,
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
	if !claim_server(config.control) {
		log.error("Server control is already in use"); return false
	}
	defer release_server(config.control)
	if !drain_duration_valid(config.drain_timeout) {
		log.error("Invalid server drain_timeout"); return false
	}
	initial, maximum, workers, valid := server_limits(config)
	if !valid do return false
	if !keep_alive_valid(config.keep_alive) {
		log.error("Invalid keep-alive request count or idle timeout")
		return false
	}
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
		log.error("Could not allocate server runtime:", allocation_error); return false
	}
	defer free(runtime)
	runtime^ = Server_Runtime {
		config = config,
		timeouts = resolve_timeouts(config.timeouts),
		logger = context.logger,
		capacity_state = {current = initial, maximum = maximum},
	}
	if err := async.init(
		&runtime.executor,
		{
			workers = workers,
			task_capacity = initial + workers + 1,
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
	runtime.accept_task = {
		resume = accept_connections,
		data   = runtime,
	}
	if err := async.register(&runtime.executor, &runtime.accept_task); err.kind != .None {
		log.error("Could not register listener task:", err); return false
	}
	listener, listen_error := async.listen(
		&runtime.executor,
		&runtime.accept_task,
		{address, config.port},
	)
	if listen_error.kind != .None {
		log.error("Could not start server:", listen_error); return false
	}
	runtime.listener = listener
	endpoint, endpoint_error := async.bound_endpoint(listener)
	if endpoint_error.kind != .None {
		log.error("Could not obtain listening address:", endpoint_error); return false
	}
	publish_server(config.control, runtime, endpoint)
	async.wake(&runtime.executor, &runtime.accept_task)
	log.infof("listening on http://localhost:%d", endpoint.port)
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
				async.shutdown(&runtime.executor)
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
reject_connection :: proc(client: net.TCP_Socket) {
	defer net.close(client)
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
	if !allowed {reject_connection(client); return}
	if !server_capacity_admit(runtime) {
		reject_connection(client); return
	}
	task, allocation_error := new(Connection_Task)
	if allocation_error != nil {
		server_capacity_allocation_failed(runtime)
		reject_connection(client); return
	}
	task^ = {
		runtime = runtime,
		native_pending = true,
		phase = .Adopt,
		connection = {socket = client, _timeouts = runtime.timeouts},
	}
	init_connection_arena(task)
	task.task = {
		resume  = handle_connection,
		data    = task,
		on_done = finish_connection,
	}
	// Publish fully initialized storage. Adoption happens inside its first
	// resume, so shutdown can safely dispose even an unexecuted task.
	sync.atomic_add(&runtime.active_connections, 1)
	if async.spawn(&runtime.executor, &task.task).kind != .None {
		sync.atomic_sub(&runtime.active_connections, 1)
		server_capacity_allocation_failed(runtime)
		reject_connection(client)
		mem.dynamic_arena_destroy(&task.arena)
		free(task)
	}
}
