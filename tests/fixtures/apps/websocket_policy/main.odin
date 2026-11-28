package main

import core "shared:saba/core"
import wsapp "shared:saba/websocket"
import codec "shared:async/websocket"
import credentials "shared:async/tls/credentials"
import store "shared:async/tls/credentials/store"
import budget "shared:async/budget"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:os"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import rt "base:runtime"

State :: struct {
	control:           core.Server_Control,
	resources:         budget.Scope,
	tracker:           mem.Tracking_Allocator,
	credentials:       ^store.Store,
	tls:               core.TLS_Config,
	secure,
	result:            bool,
	created,
	accepted,
	opened,
	closed,
	dropped,
	messages,
	queue_count,
	queue_bytes,
	out_limit,
	writable_calls,
	clean,
	unclean,
	close_timeouts:    u64,
	tls_closed,
	tls_live,
	write_waits,
	partial_writes,
	combined_timeouts: u64,
	probe_mutex:       sync.Mutex,
	diagnostic_fd:     posix.FD,
}
Session_Data :: struct {
	state:                                                ^State,
	max_message, max_output:                              int,
	slow, bytes_queue, noack, combined, combined_started: bool,
}
large: [8 * 1024 * 1024]u8
// The idle, write and close timeouts of /slow, whose sessions are about what
// an 8 MiB message costs while its reader is slow. How long that reader takes
// is the machine's business; the combined probes set short timeouts of their
// own.
PATIENT :: 2 * time.Minute
queue_a: [1024]u8
queue_c: [512]u8
oversized: [2049]u8

header :: proc(request: ^core.Request, name: string) -> string {
	for field in request.headers {
		if field.name == name {
			return field.value
		}
	}

	return ""
}
origin :: proc(data: rawptr, request: ^core.Request, value: string, present: bool) -> bool {
	return present && value == "https://allowed.invalid"
}
protocol :: proc(data: rawptr, request: ^core.Request, offered: []string) -> (string, bool) {
	for value in offered {
		if value == "chat.v2" {
			return value, true
		}
	}

	return "", false
}
opened :: proc(data: rawptr, io: ^wsapp.IO) {
	owner := cast(^Session_Data)data
	assert(wsapp.subprotocol(io) == "chat.v2")
	sync.atomic_add(&owner.state.opened, 1)

	if owner.combined {
		assert(wsapp.send(io, .Text, transmute([]u8)string("A")) == .Accepted)
		assert(wsapp.send(io, .Text, transmute([]u8)string("B")) == .Accepted)
		assert(wsapp.send(io, .Text, transmute([]u8)string("C")) == .Backpressure)
	}
}
message :: proc(data: rawptr, io: ^wsapp.IO, opcode: codec.Opcode, payload: []u8) {
	owner := cast(^Session_Data)data
	sync.atomic_add(&owner.state.messages, 1)
	text := cast(string)payload

	if text == "queue-count" {
		storage: [7]u8
		copy(storage[:], transmute([]u8)string("count-1"))
		assert(wsapp.send(io, .Text, storage[:]) == .Accepted)
		storage[6] = '2'
		assert(wsapp.send(io, .Text, storage[:]) == .Accepted)
		storage[6] = '3'
		assert(wsapp.send(io, .Text, storage[:]) == .Backpressure)
		// send must own copies before the callback's mutable storage changes.
		for &value in storage {
			value = 0xff
		}
		sync.atomic_add(&owner.state.queue_count, 1)
		return
	}

	if text == "queue-bytes" {
		assert(owner.bytes_queue)
		assert(wsapp.send(io, .Binary, queue_a[:]) == .Accepted)
		assert(wsapp.send(io, .Binary, oversized[:513]) == .Backpressure)
		assert(wsapp.send(io, .Binary, queue_c[:]) == .Accepted)
		sync.atomic_add(&owner.state.queue_bytes, 1)
		return
	}

	if text == "oversized-output" {
		assert(wsapp.send(io, .Binary, oversized[:]) == .Limit_Exceeded)
		assert(wsapp.send(io, .Text, transmute([]u8)string("output-rejected")) == .Accepted)
		sync.atomic_add(&owner.state.out_limit, 1)
		return
	}

	if text == "application-noack" {
		owner.noack = true
		assert(wsapp.close(io, 1000, "no-ack").kind == .None)
		return
	}

	if text == "application-close" {
		assert(wsapp.send(io, .Text, transmute([]u8)string("before-close-1")) == .Accepted)
		assert(wsapp.send(io, .Text, transmute([]u8)string("before-close-2")) == .Accepted)
		assert(wsapp.close(io, 1000, "app-done").kind == .None)
		return
	}

	if text == "slow" || text == "peer-close-discard" {
		assert(owner.slow)
		assert(wsapp.send(io, .Binary, large[:]) == .Accepted)

		if text == "peer-close-discard" {
			assert(wsapp.send(io, .Text, transmute([]u8)string("forbidden-tail")) == .Accepted)
		}

		return
	}

	assert(wsapp.send(io, opcode, payload) == .Accepted)
}
writable :: proc(data: rawptr, io: ^wsapp.IO) {
	owner := cast(^Session_Data)data
	stats := wsapp.stats(io)
	assert(stats.queued_messages < 2 && stats.queued_bytes < owner.max_output)
	sync.atomic_add(&owner.state.writable_calls, 1)

	if owner.combined && !owner.combined_started {
		owner.combined_started = true
		assert(wsapp.send(io, .Binary, large[:]) == .Accepted)
		fmt.println("COMBINED")
		os.flush(os.stdout)
	}
}
closed :: proc(data: rawptr, event: ^wsapp.Close_Event) {
	owner := cast(^Session_Data)data
	assert(event.stats.peak_output_bytes <= owner.max_output)
	assert(event.stats.message_capacity <= owner.max_message)
	assert(event.stats.peak_message_bytes <= owner.max_message)
	assert(event.stats.peak_output_messages <= 2)
	assert(event.stats.queued_bytes == 0 && event.stats.queued_messages == 0)

	if event.reason == .Peer_Close && event.transport.kind == .None {
		assert(event.clean)
	}

	if event.reason == .Shutdown ||
	   event.reason == .Owner_Stopped ||
	   event.reason == .Not_Opened ||
	   event.reason == .Peer_EOF ||
	   event.reason == .IO_Error ||
	   event.reason == .Protocol_Error ||
	   event.reason == .Timeout {
		assert(!event.clean)
	}

	if owner.combined {
		assert(!event.clean && event.transport.kind == .Timeout)
		sync.atomic_add(&owner.state.combined_timeouts, 1)
		sync.lock(&owner.state.probe_mutex)
		owner.state.diagnostic_fd = -1
		sync.unlock(&owner.state.probe_mutex)
	}

	if owner.noack {
		assert(!event.clean && event.transport.kind == .Timeout)
		sync.atomic_add(&owner.state.close_timeouts, 1)
	}

	if event.clean {
		sync.atomic_add(&owner.state.clean, 1)
	} else {
		sync.atomic_add(&owner.state.unclean, 1)
	}

	sync.atomic_add(&owner.state.closed, 1)
}
drop :: proc(data: rawptr) {
	owner := cast(^Session_Data)data
	state := owner.state
	sync.atomic_add(&state.dropped, 1)
	free(owner, mem.tracking_allocator(&state.tracker))
}
route :: proc(data: rawptr, conn: ^core.Connection, request: ^core.Request) -> core.Response {
	state := cast(^State)data

	if request.path == "/fast" {
		return {status = .OK, body = transmute([]u8)string("websocket79-ok\n")}
	}

	if request.path != "/ws" &&
	   request.path != "/queue-bytes" &&
	   request.path != "/slow" &&
	   request.path != "/surf" &&
	   request.path != "/combined-frame" &&
	   request.path != "/combined-fragment" {
		return {status = .Not_Found}
	}

	if request.path != "/surf" && header(request, "X-Test-Auth") != "allow" {
		return {status = .Forbidden}
	}

	owner, error := new(Session_Data, mem.tracking_allocator(&state.tracker))
	assert(error == nil)
	owner.state = state
	owner.max_message = 2048
	owner.max_output = 4096
	owner.combined = request.path == "/combined-frame" || request.path == "/combined-fragment"
	owner.slow = request.path == "/slow" || owner.combined
	owner.bytes_queue = request.path == "/queue-bytes"
	sync.atomic_add(&state.created, 1)
	config := wsapp.Config {
		max_frame_bytes    = 1024,
		max_message_bytes  = 2048,
		max_output_bytes   = 4096,
		output_capacity    = 2,
		max_fragments      = 4,
		idle_timeout       = 20 * time.Second,
		frame_timeout      = 3 * time.Second,
		write_timeout      = 30 * time.Second,
		close_timeout      = 200 * time.Millisecond,
		check_origin       = origin,
		select_subprotocol = protocol,
		policy_data        = state,
	}

	if owner.bytes_queue {
		config.max_output_bytes = 1536
		owner.max_output = 1536
	}

	if owner.slow {
		config.max_frame_bytes = 65536
		config.max_message_bytes = len(large)
		config.max_output_bytes = len(large) + 64
		config.idle_timeout = PATIENT
		config.write_timeout = PATIENT
		config.close_timeout = PATIENT
		owner.max_output = len(large) + 64
		owner.max_message = len(large)
		assert(net.set_option(conn.socket, .Send_Buffer_Size, i32(1024)) == nil)
		actual: i32
		length := posix.socklen_t(size_of(actual))
		assert(posix.getsockopt(posix.FD(conn.socket), posix.SOL_SOCKET, .SNDBUF, &actual, &length) == .OK)
		assert(actual <= 4096)
		fmt.printf("SNDBUF %d\n", actual)
		os.flush(os.stdout)

		if owner.combined {
			config.frame_timeout = time.Second
			config.message_timeout = time.Second
			config.idle_timeout = 10 * time.Second
			config.write_timeout = 5 * time.Second
			sync.lock(&state.probe_mutex)
			state.diagnostic_fd = posix.FD(conn.socket)
			sync.unlock(&state.probe_mutex)
		}
	}

	response, upgrade_error := wsapp.upgrade(
		request,
		config,
		{data = owner, on_open = opened, on_message = message, on_writable = writable, on_close = closed, drop = drop},
	)

	if upgrade_error.kind != .None {
		drop(owner)
		return {status = upgrade_error.status}
	}

	sync.atomic_add(&state.accepted, 1)

	return response
}
tls_event :: proc(data: rawptr, event: ^core.TLS_Event) {
	state := cast(^State)data

	if event.kind == .Closed {
		assert(event.stats.live_bytes == 0)
		sync.atomic_add(&state.tls_closed, 1)
		sync.atomic_add(&state.tls_live, u64(event.stats.live_bytes))
		sync.atomic_add(&state.write_waits, event.write_waits)
		sync.atomic_add(&state.partial_writes, event.transport_partial_writes)
	}
}
serve :: proc(state: ^State) {
	context.logger = log.nil_logger()
	context.allocator = mem.tracking_allocator(&state.tracker)
	config := core.Server {
		port = 0,
		workers = 1,
		initial_connections = 2,
		max_connections = 64,
		runtime_allocator = context.allocator,
		handler = route,
		handler_data = state,
		control = &state.control,
		resources = {parent = state.resources},
		keep_alive = {enabled = true},
		timeouts = {header = 3 * time.Second, body = 3 * time.Second, response = 30 * time.Second},
	}

	if state.secure {
		config.tls = &state.tls
	}

	state.result = core.serve(config)
	fmt.printf("FINISHED %v\n", state.result)
	os.flush(os.stdout)
}
metrics :: proc(state: ^State) {
	capacity, valid := core.server_capacity(&state.control)
	view, error := budget.snapshot(state.resources)
	assert(error == .None)
	created := sync.atomic_load(&state.created)
	open := sync.atomic_load(&state.opened)
	close := sync.atomic_load(&state.closed)
	dropped := sync.atomic_load(&state.dropped)
	messages := sync.atomic_load(&state.messages)
	count := sync.atomic_load(&state.queue_count)
	bytes := sync.atomic_load(&state.queue_bytes)
	limit := sync.atomic_load(&state.out_limit)
	waits := sync.atomic_load(&state.write_waits)
	partial := sync.atomic_load(&state.partial_writes)
	writable := sync.atomic_load(&state.writable_calls)
	clean := sync.atomic_load(&state.clean)
	unclean := sync.atomic_load(&state.unclean)
	close_timeouts := sync.atomic_load(&state.close_timeouts)
	combined := sync.atomic_load(&state.combined_timeouts)
	fmt.printf(
		"METRICS %d %v %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",
		capacity.active,
		valid,
		created,
		open,
		close,
		dropped,
		messages,
		count,
		bytes,
		limit,
		view.used.bytes,
		view.scope_nodes,
		waits,
		partial,
		writable,
		clean,
		unclean,
		close_timeouts,
		combined,
	)
	os.flush(os.stdout)
}
// Read-only kernel readiness observation; never consumes the session stream.
// This fixture runs one combined probe at a time and clears its copied fd on close.
pressure :: proc(state: ^State) {
	valid := false
	ready := true
	sync.lock(&state.probe_mutex)

	if state.diagnostic_fd >= 0 {
		fd := posix.pollfd {
			fd     = state.diagnostic_fd,
			events = {.OUT},
		}

		result := posix.poll(&fd, 1, 0)
		valid = result >= 0 && .NVAL not_in fd.revents && .ERR not_in fd.revents && .HUP not_in fd.revents
		ready = .OUT in fd.revents
	}

	sync.unlock(&state.probe_mutex)
	fmt.printf("PRESSURE %v %v\n", valid, ready)
	os.flush(os.stdout)
}
main :: proc() {
	assert(len(os.args) == 4)
	state := State {
		secure        = os.args[1] == "wss",
		diagnostic_fd = -1,
	}

	context.logger = log.nil_logger()
	mem.tracking_allocator_init(&state.tracker, rt.heap_allocator(), rt.heap_allocator())
	defer mem.tracking_allocator_destroy(&state.tracker)
	resources, error := budget.create_root({bytes = 256 * 1024 * 1024, streams = 128, jobs = 128})
	assert(error == .None)
	state.resources = resources
	defer budget.release_scope(&state.resources)
	for &value, index in large {
		value = u8(index % 251)
	}
	for &value in queue_a {
		value = 'A'
	}
	for &value in queue_c {
		value = 'C'
	}
	cert, ce := os.read_entire_file(os.args[2], rt.heap_allocator())
	assert(ce == nil)
	defer delete(cert, rt.heap_allocator())
	key, ke := os.read_entire_file(os.args[3], rt.heap_allocator())
	assert(ke == nil)
	defer delete(key, rt.heap_allocator())
	credential, credential_error := credentials.create(cert, key, {}, rt.heap_allocator())
	assert(credential_error == .None)
	credentials_store, store_error := store.create({}, rt.heap_allocator())
	assert(store_error.kind == .None)
	state.credentials = credentials_store
	defer store.destroy(&state.credentials)
	assert(store.replace(state.credentials, &credential).kind == .None)
	state.tls = {
		store             = state.credentials,
		handshake_timeout = 3 * time.Second,
		close_timeout     = 200 * time.Millisecond,
		on_event          = tls_event,
		data              = &state,
	}

	worker := thread.create_and_start_with_poly_data(&state, serve)
	assert(worker != nil)
	// Polled until the listener is published or serve returns, with no bound of
	// its own: the test's ready timeout reports a server that never starts.
	for !core.server_ready(&state.control) && !thread.is_done(worker) {
		time.sleep(time.Millisecond)
	}

	endpoint, ready := core.server_endpoint(&state.control)
	assert(ready)
	fmt.printf("READY %d\n", endpoint.port)
	os.flush(os.stdout)
	joined := false

	for {
		command: [1]u8
		n, read_error := os.read(os.stdin, command[:])

		if read_error != nil || n == 0 {
			break
		}

		switch command[0] {
		case 'm':
			metrics(&state)
		case 'b':
			pressure(&state)
		case 's':
			core.stop_server(&state.control)
		case 'j':
			thread.join(worker)
			joined = true
			assert(state.result)
			assert(state.created == state.dropped && state.accepted == state.closed && state.opened <= state.closed)
			view, snapshot_error := budget.snapshot(state.resources)
			assert(snapshot_error == .None)
			assert(view.used == (budget.Usage{}) && view.scope_nodes == 1)
			stats, _ := store.stats(state.credentials)
			assert(stats.active_leases == 0)
			assert(state.tracker.current_memory_allocated == 0 && len(state.tracker.bad_free_array) == 0)
			fmt.printf(
				"JOINED %d %d %d %d %d %d %d %d %d %d\n",
				state.created,
				state.opened,
				state.closed,
				state.dropped,
				view.used.bytes,
				view.scope_nodes,
				state.tracker.current_memory_allocated,
				state.tls_live,
				state.write_waits,
				state.partial_writes,
			); os.flush(os.stdout)
		case 'q':
			assert(joined); thread.destroy(worker); return
		}
	}

	core.stop_server(&state.control)

	if !joined {
		thread.join(worker)
	}

	thread.destroy(worker)
}
