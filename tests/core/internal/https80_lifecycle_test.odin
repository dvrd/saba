package saba_core

import async "shared:async"
import rt "base:runtime"
import "shared:async/tls/credentials"
import "core:encoding/hex"
import "core:fmt"
import "core:mem"
import charged "shared:async/mem/budget"
import credential_store "shared:async/tls/credentials/store"
import "core:net"
import "core:sync"
import budget "shared:async/sync/budget"
import "core:testing"
import "core:thread"
import "core:time"

HTTPS80_Lifecycle :: struct {
	runtime:                             Server_Runtime,
	connection:                          ^Connection_Task,
	initialized, done:                   bool,
	// The bridge owns a connection by task, not by thread: callbacks may run on
	// any worker, but never two at once, and events only inside one of them.
	inside:                              bool,
	resumes, cancels, closed_events:     int,
	close_done, close_callbacks_drained: bool,
}

https80_pair :: proc() -> (client, peer: net.TCP_Socket) {
	listener, error := net.listen_tcp({net.IP4_Loopback, 0})
	assert(error == nil)
	defer net.close(listener)
	endpoint, bound := net.bound_endpoint(listener)
	assert(bound == nil)
	client, error = net.dial_tcp(endpoint)
	assert(error == nil)
	peer, _, error = net.accept_tcp(listener)
	assert(error == nil)

	return
}

https80_lifecycle_event :: proc(data: rawptr, event: ^TLS_Event) {
	probe := cast(^HTTPS80_Lifecycle)data
	assert(sync.atomic_load(&probe.inside), "TLS event outside its connection task")

	if event.kind == .Closed {
		probe.closed_events += 1
		probe.close_callbacks_drained = event.stats.live_bytes == 0
	}
}

https80_lifecycle_resume :: proc(data: rawptr) -> async.Resume_Result {
	task := cast(^Connection_Task)data
	probe := cast(^HTTPS80_Lifecycle)task.runtime.config.handler_data

	https80_lifecycle_enter(probe)
	defer https80_lifecycle_leave(probe)

	probe.resumes += 1
	result := handle_connection(data)

	if task.tls_state != nil && task.tls_state.initialized {
		sync.atomic_store(&probe.initialized, true)
	}

	return result
}

https80_lifecycle_cancel :: proc(data: rawptr) -> async.Resume_Result {
	task := cast(^Connection_Task)data
	probe := cast(^HTTPS80_Lifecycle)task.runtime.config.handler_data
	https80_lifecycle_enter(probe)
	defer https80_lifecycle_leave(probe)
	probe.cancels += 1

	return connection_cancel(data)
}

https80_lifecycle_done :: proc(data: rawptr) {
	task := cast(^Connection_Task)data
	probe := cast(^HTTPS80_Lifecycle)task.runtime.config.handler_data
	https80_lifecycle_enter(probe)

	if task.tls_state != nil && task.tls_state.initialized {
		probe.close_done = task.tls_state.close_done
		assert(probe.close_done && probe.closed_events == 1)
	}

	finish_connection(data)
	probe.connection = nil
	https80_lifecycle_leave(probe)
	sync.atomic_store(&probe.done, true)
}

https80_lifecycle_enter :: proc(probe: ^HTTPS80_Lifecycle) {
	_, entered := sync.atomic_compare_exchange_strong(&probe.inside, false, true)
	assert(entered, "two callbacks of one connection task ran at once")
}

https80_lifecycle_leave :: proc(probe: ^HTTPS80_Lifecycle) {
	sync.atomic_store(&probe.inside, false)
}

https80_wait_flag :: proc(flag: ^bool) {
	deadline := time.tick_add(time.tick_now(), 5 * time.Second)

	for !sync.atomic_load(flag) {
		assert(time.tick_diff(time.tick_now(), deadline) > 0, "bounded lifecycle wait")
		thread.yield()
	}
}

https80_lifecycle_run :: proc(
	t: ^testing.T,
	zero_budget: bool,
	hello := false,
	rotate := false,
	failure: ^HTTPS80_Failure = nil,
) {
	store := https80_make_store(t)
	defer credential_store.destroy(&store)
	probe: HTTPS80_Lifecycle
	tls_config := TLS_Config {
		store             = store,
		handshake_timeout = time.Second,
		close_timeout     = 10 * time.Millisecond,
		on_event          = https80_lifecycle_event,
		data              = &probe,
	}
	probe.runtime.config = {
		tls          = &tls_config,
		handler_data = &probe,
	}
	if zero_budget {
		probe.runtime.config.resources.connection_limits = budget.Limits{0, 1, 4}
	}
	probe.runtime.timeouts = resolve_timeouts({})
	probe.runtime.logger = context.logger
	assert(initialize_resources(&probe.runtime))
	defer budget.release_scope(&probe.runtime.resources)
	assert(async.init(&probe.runtime.executor, {workers = 4, task_capacity = 1, io_capacity = 1}).kind == .None)
	defer assert(async.destroy(&probe.runtime.executor).kind == .None)
	client, peer := https80_pair()
	defer net.close(peer)
	task := new(Connection_Task, rt.heap_allocator())
	probe.connection = task
	task^ = {
		runtime = &probe.runtime,
		native_pending = true,
		phase = .Adopt,
		connection = {socket = client, _timeouts = probe.runtime.timeouts},
	}
	assert(start_connection_resources(task))
	init_connection_arena(task)
	if failure != nil {
		binding, created := charged.create(task.resource_connection, {backing = {https80_failure_allocate, failure}})
		assert(created.kind == .None)
		task.resource_transport = binding
	}
	if hello {
		hello_hex := HTTPS80_TEST_CLIENT_HELLO
		message, decoded := hex.decode(transmute([]u8)hello_hex)
		assert(decoded == nil)
		wire: [1024]u8
		wire[0], wire[1], wire[2] = 22, 3, 3
		wire[3], wire[4] = u8(len(message) >> 8), u8(len(message))
		count := 5 + copy(wire[5:], message)
		delete(message)
		sent, error := net.send_tcp(peer, wire[:count])
		assert(error == nil && sent == count)
	}
	task.task = {
		resume    = https80_lifecycle_resume,
		on_cancel = https80_lifecycle_cancel,
		on_done   = https80_lifecycle_done,
		data      = task,
	}
	probe.runtime.active_connections = 1
	assert(async.register(&probe.runtime.executor, &task.task).kind == .None)
	assert(async.wake(&probe.runtime.executor, &task.task))
	assert(async.start(&probe.runtime.executor).kind == .None)
	if !zero_budget && (failure == nil || failure.fail_at == 0) {
		https80_wait_flag(&probe.initialized)

		if hello {
			deadline := time.tick_add(time.tick_now(), 5 * time.Second)

			for {
				view, error := credential_store.stats(store)
				assert(error.kind == .None)

				if view.active_leases == 1 {
					break
				}

				assert(time.tick_diff(time.tick_now(), deadline) > 0, "credential flight lease")
				thread.yield()
			}
		}

		if rotate {
			next, created := credentials.create(
				transmute([]u8)string(HTTPS80_TEST_CERT),
				transmute([]u8)string(HTTPS80_TEST_KEY),
				{},
				context.allocator,
			)
			assert(created == .None)
			assert(credential_store.replace(store, &next).kind == .None)
			view, error := credential_store.stats(store)
			assert(error.kind == .None)
			testing.expect_value(t, view.generations, 2)
			testing.expect_value(t, view.retired_generations, 1)
			testing.expect_value(t, view.active_leases, 1)
			testing.expect_value(t, credential_store.close(store).kind, .None)
		}

		async.shutdown(&probe.runtime.executor)
	}
	https80_wait_flag(&probe.done)
	assert(async.wait_idle(&probe.runtime.executor).kind == .None)
	snapshot, result := budget.snapshot(probe.runtime.resources)
	testing.expect_value(t, result, .None)
	testing.expect_value(t, snapshot.used, budget.Usage{})
	testing.expect_value(t, snapshot.scope_nodes, u64(1))
	view, viewed := credential_store.stats(store)
	testing.expect_value(t, viewed.kind, .None)
	testing.expect_value(t, view.active_leases, 0)
	testing.expect_value(t, probe.runtime.active_connections, 0)
	if zero_budget {
		testing.expect(t, snapshot.rejected > 0)
	} else if failure == nil || failure.fail_at == 0 {
		testing.expect(t, probe.cancels > 0)
		testing.expect(t, probe.close_done && probe.close_callbacks_drained)
		testing.expect_value(t, probe.closed_events, 1)
	}
	if rotate {
		testing.expect_value(t, view.generations, 0)
	}
	if failure != nil {
		testing.expect_value(t, failure.track.current_memory_allocated, i64(0))

		if failure.fail_at > 0 {
			testing.expect_value(t, failure.failed, 1)
		}
	}
	buffer: [16]u8
	received, _ := net.recv_tcp(peer, buffer[:])
	if !hello {
		testing.expect_value(t, received, 0)
	}
}

@(test)
https80_runtime_shutdown_drives_pinned_tls_close_before_task_free :: proc(t: ^testing.T) {
	https80_lifecycle_run(t, false)
}

@(test)
https80_connection_budget_rejection_releases_every_scope_without_plaintext_response :: proc(t: ^testing.T) {
	https80_lifecycle_run(t, true)
}

// Captured Go ClientHello from Core's independent handshake corpus.
HTTPS80_TEST_CLIENT_HELLO :: string(
	"010001000303a462d796cd04d37658e30441315b1236e24b0264360b0a9c1e3a8cad5170c04e20d9274cd1cb7dc6cbaaba224b0cd21bea2dcc7417309282c7ab68c4e0ad1e4c610006130113021303010000b100000014001200000f666978747572652e696e76616c6964000b00020100ff010001000017000000120000000500050100000000000a00040002001d000d0010000e08040403080708050806050306030032001a00180804040308070805080604010501060105030603020102030010000e000c02683208687474702f312e31002b0003020304003300260024001d0020b7c6a858c346498540c820dbacb8fa485f036f3da825e71c7e2e029756767e5c",
)

HTTPS80_Failure :: struct {
	track:                  mem.Tracking_Allocator,
	calls, fail_at, failed: int,
}

https80_failure_allocate :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> (
	[]u8,
	mem.Allocator_Error,
) {
	state := cast(^HTTPS80_Failure)data
	if mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed {
		state.calls += 1

		if state.calls == state.fail_at {
			state.failed += 1
			return nil, .Out_Of_Memory
		}
	}
	backing := mem.tracking_allocator(&state.track)
	return backing.procedure(backing.data, mode, size, alignment, old_memory, old_size, location)
}

@(test)
https80_rotation_pins_admitted_generation_until_cancelled_handshake_closes :: proc(t: ^testing.T) {
	https80_lifecycle_run(t, false, hello = true, rotate = true)
}

@(test)
https80_each_tls_backing_allocation_failure_retires_callbacks_and_scope_charges :: proc(t: ^testing.T) {
	baseline: HTTPS80_Failure
	mem.tracking_allocator_init(&baseline.track, rt.heap_allocator(), rt.heap_allocator())
	https80_lifecycle_run(t, false, hello = true, failure = &baseline)
	mem.tracking_allocator_destroy(&baseline.track)
	testing.expect(t, baseline.calls > 1)
	fmt.printf("HTTPS80 backing allocation failure cells=%d\n", baseline.calls)

	for fail_at in 1 ..= baseline.calls {
		state := HTTPS80_Failure {
			fail_at = fail_at,
		}

		mem.tracking_allocator_init(&state.track, rt.heap_allocator(), rt.heap_allocator())
		https80_lifecycle_run(t, false, hello = true, failure = &state)
		mem.tracking_allocator_destroy(&state.track)
	}
}
