package saba_core

import http3 "../../http/v3"
import http "../../http"
import exchange "../../http/exchange"
import rt "base:runtime"
import "core:mem"
import charged "core:mem/budget"
import budget "core:sync/budget"
import "core:net"
import "core:crypto/tls"
import "core:net/quic"
import "core:strings"
import "core:strconv"
import "core:sync"
import "core:time"
import credential_store "core:crypto/tls/credentials/store"
import async "shared:async"

// Optional UDP listener on the ordinary server runtime. Credentials are borrowed
// until serve returns. TCP and UDP endpoints are deliberately independent.
Http3_Config :: struct {
	request_phases:          Http3_Phase_Config,
	idle:                    http3.Idle_Config,
	handshake_timeout:       time.Duration,
	// Native H3 pending-handler budget, starting at first request bytes. Zero
	// selects 30s; unset phase policy closes the connection on expiry. An enabled
	// phase policy instead expires only this request.
	// With unset phase policy it also bounds CONNECT closing grace. This is not a header/body
	// receive or response-transmission phase deadline.
	request_timeout:         time.Duration,
	max_connections:         int,
	early_request_policy:    proc(_: rawptr, _: ^Request) -> bool,
	early_request_data:      rawptr,
	reset:                   ^quic.Reset_Secrets,
	enable_connect_protocol: bool,
	tickets:                 ^tls.Server_Ticket_Config,
	disable_tickets:         bool,
	ecn:                     bool,
	client_auth:             ^tls.Client_Auth_Config,
	qpack:                   http3.Qpack_Config,
	retry:                   ^quic.Retry_Tokens,
	enabled:                 bool,
	endpoint:                net.Endpoint,
	credentials:             ^credential_store.Store,
	handler:                 Handler,
	handler_data:            rawptr,
	// Legacy response representation limit; zero uses the transport finite cap.
	max_body:                int,
	max_request_body:        int,
}

Http3 :: struct {
	live:     http3.Listener,
	config:   Http3_Config,
	// Standalone users must serialize step/close on this runtime's task. serve
	// wires these internally; applications normally use Server.http3 instead.
	runtime:  ^Server_Runtime,
	task:     async.Task,
	calls:    int,
	rejected: bool,
	_pending: bool,
}

Http3_Request :: struct {
	owner:                      ^Http3,
	connection:                 Connection_Task,
	response:                   Response,
	ready, failed, initialized: bool,
	offset:                     int,
}

http3_listen :: proc(state: ^Http3) -> (port: int, ok: bool) {
	if state == nil || !state.config.enabled || state.runtime == nil || state.config.credentials == nil {
		return 0, false
	}

	if !http3_phases_valid(state.config.request_phases) || !timeout_in_range(state.config.request_timeout) {
		return 0, false
	}

	if state.config.client_auth == nil && state.runtime.config.tls != nil {
		state.config.client_auth = state.runtime.config.tls.client_auth
	}

	if state.config.disable_tickets {
		state.config.tickets = nil
	} else if state.config.tickets == nil && state.runtime.config.tls != nil {
		state.config.tickets = state.runtime.config.tls.tickets
	}

	if state.config.handler == nil {
		state.config.handler = state.runtime.config.handler
		state.config.handler_data = state.runtime.config.handler_data
	}

	if state.config.handler == nil {
		return 0, false
	}
	early_policy: http3.Early_Request_Policy

	if state.config.early_request_policy != nil {
		early_policy = http3_allow_early
	}

	state.live.config = {
		request_phases          = http3_phase_policy(state.config.request_phases, state.runtime.timeouts),
		request_timeout         = state.config.request_timeout,
		idle                    = state.config.idle,
		handshake_timeout       = state.config.handshake_timeout,
		early_request_policy    = early_policy,
		early_request_data      = state,
		reset                   = state.config.reset,
		enable_connect_protocol = state.config.enable_connect_protocol,
		tickets                 = state.config.tickets,
		ecn                     = state.config.ecn,
		client_auth             = state.config.client_auth,
		qpack                   = state.config.qpack,
		retry                   = state.config.retry,
		endpoint                = state.config.endpoint,
		credentials             = state.config.credentials,
		on_request              = http3_poll,
		on_request_user         = state,
		on_request_release      = http3_release,
		max_connections         = state.config.max_connections,
		max_request_body        = state.config.max_request_body,
	}

	port, ok = http3.listener_listen(&state.live)
	if ok {
		state.config.endpoint.port = port
	}

	return
}

http3_step :: proc(state: ^Http3) -> bool {
	if state == nil {
		return false
	}

	return http3.listener_step(&state.live)
}
http3_drain :: proc(state: ^Http3) {
	if state != nil {
		http3.listener_drain(&state.live)
	}
}
// Owner-only. Runtime integration calls this from the listener's retirement
// callback, after all running application callbacks have returned.
http3_close :: proc(state: ^Http3) {
	if state != nil {
		http3.listener_close(&state.live)
	}
}

http3_resume :: proc(data: rawptr) -> async.Resume_Result {
	state := cast(^Http3)data
	if async.cancelled(&state.task) {
		return .Done
	}
	if server_is_draining(state.runtime) {
		http3_drain(state)
	}
	// Protect admitted transport work while step may create/release a request.
	// Drain reads only this atomic snapshot, never mutable QUIC state.
	sync.atomic_store(&state._pending, true)

	if !http3_step(state) {
		state.runtime.listener_failed = true
		shutdown_runtime(state.runtime)
		return .Done
	}

	sync.atomic_store(&state._pending, http3.listener_pending(&state.live))
	if server_is_draining(state.runtime) && !sync.atomic_load(&state._pending) {
		async.wake(&state.runtime.executor, &state.runtime.accept_task)
	}
	// UDP is nonblocking. A bounded poll also observes deferred wakes and applies
	// producer backpressure; never replace an earlier stream/deferred watchdog.
	error := async.sleep_until_earlier(
		&state.runtime.executor,
		async.deadline_after(&state.runtime.executor, time.Millisecond),
	)

	return .Waiting if error.kind == .Pending else .Yield
}
http3_retire :: proc(data: rawptr) {
	state := cast(^Http3)data
	http3_close(state)
	sync.atomic_store(&state._pending, false)
}

http3_create_request :: proc(owner: ^Http3, wire: ^http3.Server_Request) -> ^Http3_Request {
	state, error := new(Http3_Request, rt.heap_allocator())
	if error != nil {
		return nil
	}
	state.owner = owner
	task := &state.connection
	task.runtime = owner.runtime
	task.connection = {
		_task          = task,
		_secure        = true,
		_peer_identity = wire.peer_identity,
		socket         = net.TCP_Socket(-1),
		_timeouts      = owner.runtime.timeouts,
	}

	if !start_connection_resources(task) {
		finish_operation_resources(task)
		budget.release_scope(&task.resource_connection)
		free(state, rt.heap_allocator())
		return nil
	}

	init_connection_arena(task)
	allocator := mem.dynamic_arena_allocator(&task.arena)
	task.request = {
		resources          = task.resource_operation,
		backing_allocator  = charged.allocator(task.resource_binding),
		allocator          = allocator,
		method             = wire.method,
		path               = wire.target,
		version            = "HTTP/3",
		protocol           = wire.protocol,
		early_data         = wire.early,
		body               = wire.body,
		content_length     = len(wire.body),
		has_content_length = true,
	}

	headers, he := make([]Header, len(wire.headers) + 1, allocator)

	if he != nil {
		state.failed = true
	} else {
		count := 0

		for field in wire.headers {
			// HTTP3 :authority is the target authority. A legacy Host field cannot
			// override it when an application reads its ordinary header view.
			if wire.authority != "" && strings.equal_fold(field.name, "host") {
				continue
			}

			headers[count] = {field.name, field.value}
			count += 1
		}

		if wire.authority != "" {
			headers[count] = {"host", wire.authority}
			count += 1
		}

		task.request.headers = headers[:count]
	}

	trailers, te := make([]Header, len(wire.trailers), allocator)

	if te != nil {
		state.failed = true
	} else {
		for field, i in wire.trailers {trailers[i] = {field.name, field.value}}; task.request.trailers = trailers
	}

	if task.request.backing_allocator.procedure == nil {
		task.request.backing_allocator = rt.heap_allocator()
	}

	if at := strings.index_byte(wire.target, '?'); at >= 0 {
		task.request.path, task.request.query = wire.target[:at], wire.target[at + 1:]
	}

	sync.lock(&owner.runtime.observability_mutex)
	owner.runtime.next_request_id += 1
	task.request.request_id = owner.runtime.next_request_id
	sync.unlock(&owner.runtime.observability_mutex)

	if !begin_request_context(task) {
		mem.dynamic_arena_destroy(&task.arena)
		finish_operation_resources(task)
		budget.release_scope(&task.resource_connection)
		free(state, rt.heap_allocator())
		return nil
	}

	sync.atomic_add(&owner.runtime.active_connections, 1)
	owner.calls += 1

	return state
}

http3_poll :: proc(user: rawptr, wire: ^http3.Server_Request, out: ^http3.Server_Response) -> http3.Response_Status {
	owner := cast(^Http3)user
	state := cast(^Http3_Request)wire.user_data

	if state == nil {
		state = http3_create_request(owner, wire)
		if state == nil {
			return .Failed
		}
		wire.user_data = state
	}

	task := &state.connection
	task.request.early_data = wire.early
	context.logger = owner.runtime.logger
	context.temp_allocator = mem.dynamic_arena_allocator(&task.arena)
	if request_cancelled(task.request.cancellation) || state.failed {
		return .Failed
	}

	if !state.initialized {
		state.initialized = true
		response: Response
		limit := REQUEST_BODY_LIMIT
		if owner.runtime.config.request_body_limit != nil {
			limit = owner.runtime.config.request_body_limit(&task.request)
		}

		if task.request.protocol != "" && task.request.protocol != "websocket" {
			response = {
				status = .Not_Implemented,
			}
		} else if len(task.request.body) > limit {
			response = {
				status = .Content_Too_Large,
			}
		} else {
			response = owner.config.handler(owner.config.handler_data, &task.connection, &task.request)
		}

		if deferred_present(response.deferred) {
			if !queue_deferred(task, response) {
				state.failed = true
				return .Failed
			}

			// queue_deferred uses the TCP task by default. HTTP3's real owner is the
			// listener task; replace the signal before any continuation is polled.
			if !rebind_deferred_signal(task, &owner.task) {
				return .Failed
			}
		} else {
			state.response = response
			state.ready = true
		}
	}

	if !state.ready {
		if deadline_expired(task.deferred_expires) {
			cancel_request_context(task.request.cancellation, .Deadline)
			return .Failed
		}

		response, step := task.deferred.poll(
			task.deferred.data,
			&Deferred_IO {
				resources = task.resource_operation,
				backing_allocator = task.request.backing_allocator,
				allocator = task.request.allocator,
				cancellation = task.request.cancellation,
				wake = task.deferred_signal,
			},
		)

		if step != .Ready {
			discard_response(&response)
			if step == .Failed {
				return .Failed
			}
			_ = async.sleep_until_earlier(&owner.runtime.executor, task.deferred_deadline)
			return .Pending
		}

		drop_deferred(task)
		state.response = response
		state.ready = true
	}

	response := &state.response

	if handled, status := http3_upgrade_response(owner, wire, state, out); handled {
		return status
	}

	if deferred_present(response.deferred) ||
	   response.upgrade.data != nil ||
	   response.upgrade.resume != nil ||
	   response.upgrade.drop != nil ||
	   response.status == .Switching_Protocols {
		// TCP upgrades have no HTTP3 transport. Reject explicitly and release their
		// transferred ownership through the ordinary response disposal path.
		discard_response(response)
		response^ = {
			status = .Not_Implemented,
		}
	}

	if response.status == .None {
		response.status = .OK
	}

	if owner.config.max_body > 0 && len(response.body) > owner.config.max_body {
		owner.rejected = true
		return .Failed
	}

	if stream_present(response.stream) && owner.config.max_body > 0 {
		if response.stream.max_body_bytes == 0 || response.stream.max_body_bytes > i64(owner.config.max_body) {
			response.stream.max_body_bytes = i64(owner.config.max_body)
		}
	}

	if !resource_copy_response(task, response) {
		return .Failed
	}
	out.status = int(response.status)
	extra := 0

	if task.request.method == "HEAD" && http.response_body_allowed(int(response.status)) {
		extra = 1

		for field in response.headers {
			if strings.equal_fold(field.name, "content-length") {
				extra = 0
				break
			}
		}
	}

	headers, he := make([]http3.Field, len(response.headers) + extra, task.request.allocator)
	if he != nil {
		return .Failed
	}

	for field, i in response.headers {
		name, error := strings.to_lower(field.name, task.request.allocator)
		if error != nil {
			return .Failed
		}
		headers[i] = {
			name          = name,
			value         = field.value,
			never_indexed = name == "set-cookie" || name == "authorization",
		}
	}

	if extra != 0 {
		length := i64(len(response.body))
		if stream_present(response.stream) {
			length = response.stream.content_length
		}

		if length >= 0 {
			storage, error := make([]u8, 32, task.request.allocator)
			if error != nil {
				return .Failed
			}
			headers[len(response.headers)] = {
				name  = "content-length",
				value = strconv.write_int(storage, length, 10),
			}
		} else {
			headers = headers[:len(response.headers)]
		}
	}

	out.headers = headers
	trailers, te := make([]http3.Field, len(response.trailers), task.request.allocator)

	if te != nil {
		return .Failed
	}

	for field, i in response.trailers {
		name, error := strings.to_lower(field.name, task.request.allocator)

		if error != nil {
			return .Failed
		}

		trailers[i] = {
			name  = name,
			value = field.value,
		}
	}

	out.trailers = trailers

	if stream_present(response.stream) {
		stream := response.stream
		response.stream = {}
		prepared := response^
		prepared.stream = stream
		if !queue_stream_response(task, prepared) {
			return .Failed
		}
		out.stream = {
			data = state,
			next = http3_stream_next,
			drop = http3_stream_drop,
		}

		// The stream owner already started its total lifetime and applied inherited
		// cancellation. Forward the remaining monotonic budget, never restart it.
		out.response_timeout = max(time.Nanosecond, time.tick_diff(time.tick_now(), task.streaming.expires))
	} else if http.response_body_allowed(int(response.status), task.request.method) {
		out.body = response.body
	}

	return .Ready
}

http3_stream_next :: proc(data: rawptr, dst: []u8) -> (int, http3.Stream_Status) {
	state := cast(^Http3_Request)data
	if len(dst) == 0 {
		return 0, .Pending
	}
	task := &state.connection
	context.logger = task.runtime.logger
	context.temp_allocator = mem.dynamic_arena_allocator(&task.arena)
	stream := task.streaming
	if stream == nil || state.failed {
		return 0, .Failed
	}

	if !stream.pending && !stream.terminal {
		result := produce_stream(task)

		if result == .Done {
			state.failed = true
			return 0, .Failed
		}

		if !stream.pending && !stream.terminal {
			return 0, .Pending
		}
	}

	if stream.terminal {
		task.response_finished = true
		return 0, .Done
	}

	body, ok := exchange.body(&stream.exchange)
	if !ok {
		return 0, .Failed
	}
	n := copy(dst, body[state.offset:])
	state.offset += n

	if state.offset == len(body) {
		state.offset = 0
		// Destroy the accepted chunk before the next producer callback. The wire
		// owns its bounded copy and never borrows producer storage across calls.
		stream.pending = false
		if !exchange.release_body(&stream.exchange) {
			return 0, .Failed
		}
	}

	return n, .Chunk
}
http3_stream_drop :: proc(data: rawptr) {
	state := cast(^Http3_Request)data
	drop_response_stream(&state.connection)
}
http3_release :: proc(user: rawptr, wire: ^http3.Server_Request) {
	state := cast(^Http3_Request)wire.user_data
	wire.user_data = nil
	if state == nil {
		return
	}
	task := &state.connection
	task.response_finished = wire.completed
	discard_response(&state.response)
	drop_deferred(task)
	drop_response_stream(task)
	finish_request_context(task)
	release_task_storage(task)
	sync.atomic_sub(&task.runtime.active_connections, 1)
	drain_connection_finished(task.runtime)
	free(state, rt.heap_allocator())
}

http3_allow_early :: proc(data: rawptr, wire: ^http3.Server_Request) -> bool {
	owner := cast(^Http3)data

	if owner.config.early_request_policy == nil {
		return false
	}

	state := cast(^Http3_Request)wire.user_data

	if state == nil {
		state = http3_create_request(owner, wire)

		if state == nil {
			return false
		}

		wire.user_data = state
	}

	return owner.config.early_request_policy(owner.config.early_request_data, &state.connection.request)
}

// Opt into Server.timeouts for native per-stream phases. CONNECT acceptance
// and closing are explicit; accepted tunnels have no request lifetime cap.
Http3_Phase_Config :: struct {
	enabled:                       bool,
	connect_accept, connect_close: time.Duration,
}

http3_phases_valid :: proc(config: Http3_Phase_Config) -> bool {
	if !config.enabled {
		return true
	}

	return(
		config.connect_accept > 0 &&
		config.connect_accept <= MAX_SERVER_TIMEOUT &&
		config.connect_close > 0 &&
		config.connect_close <= MAX_SERVER_TIMEOUT \
	)
}

http3_phase_policy :: proc(config: Http3_Phase_Config, timeouts: Resolved_Timeouts) -> http3.Request_Phase_Policy {
	if !config.enabled {
		return {}
	}

	return {
		enabled = true,
		header = timeouts.header,
		body = timeouts.body,
		large_body = timeouts.large_body,
		large_body_threshold = REQUEST_BODY_LIMIT,
		response = timeouts.response,
		connect_accept = config.connect_accept,
		connect_close = config.connect_close,
	}
}

Http3_Upgrade_IO :: struct {
	state:    ^Http3_Request,
	endpoint: ^http3.Connect_Stream,
}
http3_upgrade_response :: proc(
	owner: ^Http3,
	wire: ^http3.Server_Request,
	state: ^Http3_Request,
	out: ^http3.Server_Response,
) -> (
	bool,
	http3.Response_Status,
) {
	response := &state.response
	if response.upgrade.resume == nil && response.upgrade.drop == nil && response.upgrade.data == nil {
		return false, .Pending
	}
	if wire.connect == nil || wire.protocol != "websocket" || response.upgrade.resume == nil {
		return false, .Pending
	}
	if response.status != .OK || stream_present(response.stream) || len(response.body) > 0 {
		discard_response(response)
		out.status = 500
		return true, .Ready
	}
	task := &state.connection
	if !resource_copy_response(task, response) {
		return true, .Failed
	}
	fields, error := make([]http3.Field, len(response.headers), task.request.allocator)

	if error != nil {
		return true, .Failed
	}
	for header, i in response.headers {
		name, e := strings.to_lower(header.name, task.request.allocator)

		if e != nil {
			return true, .Failed
		}

		fields[i] = {
			name  = name,
			value = header.value,
		}
	}
	task.upgrade = response.upgrade
	response.upgrade = {}
	out.status = 200
	out.headers = fields
	out.duplex = {
		data   = state,
		resume = http3_upgrade_resume,
		drop   = http3_upgrade_drop,
	}
	return true, .Ready
}
http3_upgrade_resume :: proc(data: rawptr, endpoint: ^http3.Connect_Stream) -> http3.Duplex_Status {
	state := cast(^Http3_Request)data
	task := &state.connection

	if endpoint.cancelled {
		cancel_request_context(task.request.cancellation, .Peer_Closed)
	}

	if task.upgrade.resume == nil {
		return .Done
	}

	transport := Http3_Upgrade_IO{state, endpoint}
	io := Upgrade_IO {
		runtime      = &state.owner.runtime.executor,
		connection   = &task.connection,
		stream_data  = &transport,
		stream_read  = http3_upgrade_read,
		stream_write = http3_upgrade_write,
		stream_wait  = http3_upgrade_wait,
	}

	result := task.upgrade.resume(task.upgrade.data, &io)

	return .Done if result == .Done else .Pending
}
http3_upgrade_drop :: proc(data: rawptr) {
	drop_upgrade(&(cast(^Http3_Request)data).connection)
}
http3_upgrade_expired :: proc(io: ^Http3_Upgrade_IO, deadline: async.Deadline) -> bool {
	return deadline.epoch != 0 && async.deadline_after(&io.state.owner.runtime.executor, 0).at >= deadline.at
}
http3_upgrade_error :: proc(status: http3.Connect_IO_Status) -> async.Error {
	switch status {
	case .None:
		return {}; case .Pending:
		return {kind = .Pending}; case .End:
		return {kind = .Peer_Closed}; case .Cancelled:
		return {kind = .Cancelled}; case .Failed:
		return {kind = .Closed}
	}

	return {kind = .Closed}
}
http3_upgrade_read :: proc(data: rawptr, dst: []u8, deadline: async.Deadline) -> (int, async.Error) {
	io := cast(^Http3_Upgrade_IO)data

	if http3_upgrade_expired(io, deadline) {
		return 0, {kind = .Timeout}
	}

	n, status := http3.connect_read(io.endpoint, dst)

	return n, http3_upgrade_error(status)
}
http3_upgrade_write :: proc(data: rawptr, src: []u8, deadline: async.Deadline) -> (int, async.Error) {
	io := cast(^Http3_Upgrade_IO)data

	if http3_upgrade_expired(io, deadline) {
		return 0, {kind = .Timeout}
	}

	n, status := http3.connect_write(io.endpoint, src)

	return n, http3_upgrade_error(status)
}
http3_upgrade_wait :: proc(data: rawptr, read, write: bool, deadline: async.Deadline) -> async.Error {
	io := cast(^Http3_Upgrade_IO)data

	if io.endpoint.cancelled {
		return {kind = .Cancelled}
	}

	if http3_upgrade_expired(io, deadline) {
		return {kind = .Timeout}
	}

	if read && (io.endpoint.input_n > 0 || io.endpoint.remote_fin) {
		return {}
	}

	if write && io.endpoint.output_n < len(io.endpoint.output) - 4 {
		return {}
	}

	if deadline.epoch != 0 {
		return async.sleep_until_earlier(&io.state.owner.runtime.executor, deadline)
	}

	return {kind = .Pending}
}
