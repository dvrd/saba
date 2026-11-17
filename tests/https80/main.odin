package main

import server "../../core"
import application "../../application"
import facade "../.."
import credentials "core:crypto/tls/credentials"
import store "core:crypto/tls/credentials/store"
import signal "shared:async/signal"
import owned "core:mem/owned"
import rt "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

LARGE_BYTES :: 8 * 1024 * 1024
State :: struct {
	control:                                                      server.Server_Control,
	config:                                                       server.Server,
	tls_config:                                                   server.TLS_Config,
	credentials:                                                  ^store.Store,
	mode:                                                         string,
	result:                                                       bool,
	deferred_mutex:                                               sync.Mutex,
	deferred_wake:                                                signal.Signal,
	deferred_registered, deferred_ready:                          bool,
	handled, handshakes, successes, closed, live, waits, partial: u64,
}
fixture: ^State
large: [LARGE_BYTES]u8

route :: proc(data: rawptr, conn: ^server.Connection, request: ^server.Request) -> server.Response {
	state := cast(^State)data
	sync.atomic_add(&state.handled, 1)

	if request.path == "/deferred" {
		return {
			deferred = {data = state, poll = deferred_poll, drop = deferred_drop, timeout = 350 * time.Millisecond},
		}
	}

	if request.path == "/stream" {
		producer, error := new(Producer, rt.heap_allocator())
		assert(error == nil)
		return {status = .OK, stream = {data = producer, next = stream_next, drop = stream_drop, content_length = -1}}
	}

	if request.path == "/large" {
		requested := i32(1024)
		assert(
			posix.setsockopt(
				posix.FD(conn.socket),
				posix.SOL_SOCKET,
				.SNDBUF,
				&requested,
				posix.socklen_t(size_of(requested)),
			) ==
			.OK,
		)
		actual: i32
		actual_size := posix.socklen_t(size_of(actual))
		assert(posix.getsockopt(posix.FD(conn.socket), posix.SOL_SOCKET, .SNDBUF, &actual, &actual_size) == .OK)
		fmt.printf("LARGE socket=%d sndbuf=%d\n", conn.socket, actual)
		os.flush(os.stdout)
		return {status = .OK, body = large[:]}
	}

	if request.path == "/echo" {
		return {status = .OK, body = request.body}
	}

	return {status = .OK, body = transmute([]u8)string("https80-ok\n"), close_connection = request.path == "/close"}
}

Producer :: struct {
	sequence: int,
}

stream_next :: proc(data: rawptr, io: ^server.Stream_IO) -> server.Stream_Step {
	producer := cast(^Producer)data
	if producer.sequence == 2 do return .Done
	storage, error := make([]u8, 3, rt.heap_allocator())
	assert(error == nil)
	text := "one" if producer.sequence == 0 else "two"
	copy(storage, transmute([]u8)text)
	chunk, ownership := owned.take_slice(&storage, rt.heap_allocator())
	assert(ownership.kind == .None)
	assert(server.stream_submit(io, &chunk) == .Accepted)
	producer.sequence += 1

	return .Chunk
}
stream_drop :: proc(data: rawptr) {
	free(cast(^Producer)data, rt.heap_allocator())
}

deferred_poll :: proc(data: rawptr, io: ^server.Deferred_IO) -> (server.Response, server.Deferred_Step) {
	state := cast(^State)data
	sync.lock(&state.deferred_mutex)
	defer sync.unlock(&state.deferred_mutex)

	if state.deferred_ready {
		return {status = .OK, body = transmute([]u8)string("deferred-ready")}, .Ready
	}

	if !state.deferred_registered {
		retained, valid := signal.retain(io.wake)
		assert(valid)
		state.deferred_wake = retained
		state.deferred_registered = true
		fmt.println("DEFERRED")
		os.flush(os.stdout)
	}

	return {}, .Waiting
}
deferred_drop :: proc(data: rawptr) {
	state := cast(^State)data
	sync.lock(&state.deferred_mutex)
	defer sync.unlock(&state.deferred_mutex)
	signal.release(&state.deferred_wake)
	state.deferred_registered = false
}

facade_route :: proc(conn: ^facade.Connection, request: ^facade.Request) -> facade.Response {
	return route(fixture, nil, request)
}

tls_event :: proc(data: rawptr, event: ^server.TLS_Event) {
	state := cast(^State)data

	if event.kind == .Handshake {
		sync.atomic_add(&state.handshakes, 1)

		if event.handshake_complete {
			assert(event.negotiated_protocol == "http/1.1" || event.negotiated_protocol == "")
			sync.atomic_add(&state.successes, 1)
		}
	} else {
		assert(event.kind == .Closed)
		assert(event.stats.live_bytes == 0)
		sync.atomic_add(&state.closed, 1)
		sync.atomic_add(&state.live, u64(event.stats.live_bytes))
		sync.atomic_add(&state.waits, event.write_waits)
		sync.atomic_add(&state.partial, event.transport_partial_writes)
	}

	fmt.printf(
		"TLS %v %v %v %d %d %d %d\n",
		event.kind,
		event.handshake_complete,
		event.error.kind,
		event.stats.live_bytes,
		event.callbacks,
		event.write_waits,
		event.transport_partial_writes,
	)
	os.flush(os.stdout)
}

serve :: proc(state: ^State) {
	context.logger = log.nil_logger()

	if state.mode == "application" || state.mode == "development" {
		state.result = application.serve(
			{
				server = state.config,
				development = state.mode == "development",
				hot_reload_directory = os.get_env("HTTPS80_WEB", context.temp_allocator),
			},
		)
	} else if state.mode == "facade" {
		state.result = facade.serve(
			{
				port = 0,
				workers = 1,
				handler = facade_route,
				control = &state.control,
				tls = &state.tls_config,
				keep_alive = {enabled = true},
				timeouts = {header = time.Second, body = time.Second, response = 10 * time.Second},
				drain_timeout = 500 * time.Millisecond,
			},
		)
	} else {
		state.result = server.serve(state.config)
	}

	fmt.printf("FINISHED %v\n", state.result)
	os.flush(os.stdout)
}

load_credentials :: proc(state: ^State) {
	cert, ce := os.read_entire_file(os.args[2], context.allocator)
	assert(ce == nil)
	defer delete(cert)
	key, ke := os.read_entire_file(os.args[3], context.allocator)
	assert(ke == nil)
	defer delete(key)
	credential, error := credentials.create(cert, key, {}, context.allocator)
	assert(error == .None)
	credentials_store, store_error := store.create({}, context.allocator)
	assert(store_error.kind == .None)
	state.credentials = credentials_store
	assert(store.replace(state.credentials, &credential).kind == .None)
}

metrics :: proc(state: ^State) {
	capacity, valid := server.server_capacity(&state.control)
	requests, _ := server.server_metrics(&state.control)
	stats, _ := store.stats(state.credentials)
	// Variadic formatting borrows its arguments; snapshot atomics into private
	// storage so it cannot retain a view of concurrently updated counters.
	handled: u64 = sync.atomic_load(&state.handled)
	handshakes: u64 = sync.atomic_load(&state.handshakes)
	closed: u64 = sync.atomic_load(&state.closed)
	waits: u64 = sync.atomic_load(&state.waits)
	partial: u64 = sync.atomic_load(&state.partial)
	fmt.printf(
		"METRICS %d %v %d %d %d %d %d %d %d %d\n",
		capacity.active,
		valid,
		handled,
		handshakes,
		closed,
		waits,
		partial,
		stats.active_leases,
		requests.started,
		requests.completed,
	)
	os.flush(os.stdout)
}

main :: proc() {
	assert(len(os.args) == 4)
	context.logger = log.nil_logger()
	state := State {
		mode = os.args[1],
	}

	fixture = &state
	for &value, index in large do value = u8(index % 251)
	load_credentials(&state)
	defer store.destroy(&state.credentials)
	state.tls_config = {
		store             = state.credentials,
		handshake_timeout = 400 * time.Millisecond,
		close_timeout     = 200 * time.Millisecond,
		on_event          = tls_event,
		data              = &state,
	}

	state.config = {
		port = 0,
		workers = 1,
		handler = route,
		handler_data = &state,
		control = &state.control,
		tls = &state.tls_config,
		keep_alive = {enabled = true},
		observability = {enabled = true},
		timeouts = {header = time.Second, body = time.Second, response = 10 * time.Second},
		drain_timeout = 500 * time.Millisecond,
	}

	if state.mode == "plain" {
		state.config.tls = nil
	}

	worker := thread.create_and_start_with_poly_data(&state, serve)
	assert(worker != nil)
	limit := time.tick_add(time.tick_now(), 5 * time.Second)

	for !server.server_ready(&state.control) && time.tick_diff(time.tick_now(), limit) > 0 {
		time.sleep(time.Millisecond)
	}

	endpoint, ready := server.server_endpoint(&state.control)
	assert(ready)
	fmt.printf("READY %d\n", endpoint.port)
	os.flush(os.stdout)
	joined := false

	for {
		command: [1]u8
		n, error := os.read(os.stdin, command[:])

		if error != nil || n == 0 {
			break
		}

		switch command[0] {
		case 'm':
			metrics(&state)
		case 'r':
			sync.lock(&state.deferred_mutex)
			state.deferred_ready = true
			assert(signal.wake(state.deferred_wake))
			sync.unlock(&state.deferred_mutex)
			fmt.println("RELEASED")
			os.flush(os.stdout)
		case 'd':
			assert(server.drain_server(&state.control))
			fmt.println("DRAIN")
			os.flush(os.stdout)
		case 's':
			server.stop_server(&state.control)
		case 'j':
			thread.join(worker)
			joined = true
			assert(state.result)
			stats, _ := store.stats(state.credentials)
			assert(stats.active_leases == 0)
			assert(store.close(state.credentials).kind == .None)
			stats, _ = store.stats(state.credentials)
			assert(stats.generations == 0)
			fmt.printf(
				"JOINED %v %d %d %d %d %d %d %d %d\n",
				state.result,
				sync.atomic_load(&state.handled),
				sync.atomic_load(&state.handshakes),
				sync.atomic_load(&state.successes),
				sync.atomic_load(&state.closed),
				sync.atomic_load(&state.live),
				sync.atomic_load(&state.waits),
				sync.atomic_load(&state.partial),
				stats.active_leases,
			)
			os.flush(os.stdout)
		case 'q':
			assert(joined); thread.destroy(worker); return
		}
	}

	server.stop_server(&state.control)

	if !joined {
		thread.join(worker)
	}

	thread.destroy(worker)
}
