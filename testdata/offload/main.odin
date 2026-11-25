package main

import rt "base:runtime"
import "core:fmt"
import "core:mem"
import "core:net"
import charged "shared:async/mem/budget"
import owned "shared:async/mem/owned"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import budgets "shared:async/sync/budget"
import "core:thread"
import "core:time"
import pool "shared:async/offload"
import server "shared:saba/core"
import adapter "shared:saba/offload"

State :: struct {
	resources:             budgets.Scope,
	resource_mode:         string,
	file_pool:             pool.Pool,
	file_path:             string,
	control:               server.Server_Control,
	pool:                  pool.Pool,
	proceed:               sync.Sema,
	runs, drops, finished: int,
	result:                bool,
	tracker:               mem.Tracking_Allocator,
}
Job :: struct {
	binding:   charged.Binding,
	allocator: mem.Allocator,
	state:     ^State,
	bytes:     []u8,
	failed:    bool,
}
run :: proc(p: rawptr, _: pool.Work_Context) -> bool {
	job := cast(^Job)p
	sync.atomic_add(&job.state.runs, 1)
	assert(sync.sema_wait_with_timeout(&job.state.proceed, 10 * time.Second))

	return !job.failed
}
drop :: proc(p: rawptr) {
	job := cast(^Job)p
	allocator, binding := job.allocator, job.binding
	sync.atomic_add(&job.state.drops, 1)
	delete(job.bytes, allocator)
	free(job, allocator)
	charged.release(&binding)
}
build :: proc(p: rawptr, allocator: mem.Allocator) -> (server.Response, bool) {
	job := cast(^Job)p
	bytes, error := make([]u8, len(job.bytes), allocator)
	if error != nil {
		return {}, false
	}
	copy(bytes, job.bytes)

	return {status = .Created, body = bytes}, true
}
route :: proc(p: rawptr, conn: ^server.Connection, request: ^server.Request) -> server.Response {
	state := cast(^State)p

	if request.path == "/slow" {
		// An unread peer alone cannot hold backing when the kernel queues the whole body.
		assert(net.set_option(conn.socket, .Send_Buffer_Size, 4096) == .None)
	}

	if request.path == "/scopes" {
		return resource_views(state, request)
	}
	if request.path == "/stream" {
		return resource_stream(request)
	}
	if request.path == "/slow" || request.path == "/large" {
		return large_response(state, request)
	}

	if request.path == "/file-status" && state.file_path != "" {
		s := pool.stats(&state.file_pool)
		body := fmt.aprintf("%d %d %d", s.running, s.queued, s.retained, allocator = request.allocator)
		return {status = .OK, body = transmute([]u8)body}
	}

	if request.path == "/file" && state.file_path != "" {
		return file_response(state)
	}

	if request.path == "/release" {
		for _ in 0 ..< 4 {
			sync.post(&state.proceed)
		}
		return {status = .OK}
	}

	if request.path == "/status" {
		s := pool.stats(&state.pool)
		runs := sync.atomic_load(&state.runs)
		drops := sync.atomic_load(&state.drops)
		finished := sync.atomic_load(&state.finished)
		text := fmt.aprintf(
			"%d %d %d %d %d %d",
			s.running,
			s.queued,
			s.retained,
			runs,
			drops,
			finished,
			allocator = request.allocator,
		)
		return {status = .OK, body = transmute([]u8)text}
	}

	if request.path != "/work" && request.path != "/fail" {
		return {status = .OK, body = transmute([]u8)string("cheap")}
	}

	request.route = "/work"

	return work_response(state, request)
}
observe :: proc(p: rawptr, event: ^server.Request_Event) {
	if event.route == "/work" {
		sync.atomic_add(&(cast(^State)p).finished, 1)
	}
}
serve :: proc(state: ^State) {
	budget, _ := strconv.parse_int(os.get_env("SABA_OFFLOAD_BUDGET_MS", context.temp_allocator))
	state.result = server.serve(
		{
			port = 0,
			resources = resource_config(state),
			request_body_limit = resource_body_limit,
			initial_connections = 2,
			workers = 1,
			max_connections = 32,
			handler = route,
			handler_data = state,
			control = &state.control,
			handler_timeout = time.Duration(budget) * time.Millisecond,
			keep_alive = {enabled = true},
			timeouts = {response = 5 * time.Second},
			observability = {on_complete = observe, data = state},
		},
	)
}
main :: proc() {
	state: State
	mem.tracking_allocator_init(&state.tracker, rt.heap_allocator(), rt.heap_allocator())
	initialize_resource_parent(&state)
	assert(pool.init_scoped(&state.pool, {workers = 2, capacity = 4}, state.resources) == .None)
	state.file_path = os.get_env("SABA_OFFLOAD_FIFO", context.temp_allocator)

	if state.file_path != "" {
		assert(pool.init(&state.file_pool, {workers = 1, capacity = 1}) == .None)
	}

	worker := thread.create_and_start_with_poly_data(&state, serve)
	assert(worker != nil)

	for _ in 0 ..< 5000 {
		endpoint, ready := server.server_endpoint(&state.control)

		if ready {
			fmt.printf("ready %d\n", endpoint.port)
			os.flush(os.stdout)
			break
		}

		time.sleep(time.Millisecond)
	}

	_, ready := server.server_endpoint(&state.control)
	assert(ready)
	command := resource_command(&state)

	if command == 'd' {
		assert(server.drain_server(&state.control, 50 * time.Millisecond))
	} else {
		server.stop_server(&state.control)
	}

	thread.join(worker)
	thread.destroy(worker)
	assert(state.result)
	fmt.printf("retired %d\n", sync.atomic_load(&state.finished))
	os.flush(os.stdout)
	// The harness observes request retirement before blocked work can finish.
	_ = resource_command(&state)
	pool.shutdown(&state.pool)
	for _ in 0 ..< 4 {
		sync.post(&state.proceed)
	}
	assert(pool.join(&state.pool) == .None)
	assert(pool.destroy(&state.pool) == .None)

	if state.file_path != "" {
		pool.shutdown(&state.file_pool)
		assert(pool.join(&state.file_pool) == .None)
		assert(pool.destroy(&state.file_pool) == .None)
	}

	assert(state.tracker.current_memory_allocated == 0 && len(state.tracker.bad_free_array) == 0)
	view, error := budgets.snapshot(state.resources)
	assert(error == .None)
	assert(view.used == (budgets.Usage{}) && view.scope_nodes == 1)
	budgets.release_scope(&state.resources)
	mem.tracking_allocator_destroy(&state.tracker)
	fmt.printf("stopped %d %d\n", state.runs, state.drops)
	os.flush(os.stdout)
}

File_Job :: struct {
	state: ^State,
	path:  string,
	bytes: [64]u8,
	used:  int,
}
file_run :: proc(p: rawptr, _: pool.Work_Context) -> bool {
	job := cast(^File_Job)p
	file, error := os.open(job.path)
	if error != nil {
		return false
	}
	defer os.close(file)
	n, read_error := os.read(file, job.bytes[:])
	job.used = n

	return read_error == nil
}
file_drop :: proc(p: rawptr) {
	job := cast(^File_Job)p
	allocator := mem.tracking_allocator(&job.state.tracker)
	delete(job.path, allocator)
	free(job, allocator)
}
file_build :: proc(p: rawptr, allocator: mem.Allocator) -> (server.Response, bool) {
	job := cast(^File_Job)p
	bytes, error := make([]u8, job.used, allocator)
	if error != nil {
		return {}, false
	}
	copy(bytes, job.bytes[:job.used])

	return {status = .OK, body = bytes}, true
}
file_response :: proc(state: ^State) -> server.Response {
	allocator := mem.tracking_allocator(&state.tracker)
	job := new(File_Job, allocator)
	job.state = state
	path, error := strings.clone(state.file_path, allocator)

	if error != nil {
		free(job, allocator)
		return {status = .Internal_Server_Error}
	}

	job.path = path
	work := pool.Work{job, file_run, file_drop}
	response, ok := adapter.response_with_unmanaged_bytes(
		&state.file_pool,
		&work,
		file_build,
		unmanaged_bytes = u64(size_of(File_Job) + len(job.path)),
	)

	if !ok {
		file_drop(job)
		return {status = .Internal_Server_Error}
	}

	return response
}

resource_body_limit :: proc(_: ^server.Request) -> int {
	return 24 * mem.Megabyte
}
initialize_resource_parent :: proc(state: ^State) {
	state.resource_mode = os.get_env("SABA_RESOURCE_MODE", context.temp_allocator)
	limits := budgets.Limits{256 * mem.Megabyte, 128, 128}
	if state.resource_mode == "bytes" {
		limits.bytes = 3 * mem.Megabyte
	}
	if state.resource_mode == "streams" {
		limits.streams = 1
	}
	if state.resource_mode == "mixed" {
		limits = {20 * mem.Megabyte, 2, 2}
	}
	owner, error := budgets.create_root(limits)
	assert(error == .None)
	state.resources = owner
}
resource_command :: proc(state: ^State) -> u8 {
	for {
		command: [1]u8
		_, error := os.read(os.stdin, command[:])
		assert(error == nil)
		if command[0] != 'p' {
			return command[0]
		}
		view, result := budgets.snapshot(state.resources)
		assert(result == .None)
		capacity, _ := server.server_capacity(&state.control)
		fmt.printf(
			"usage %d %d %d %d %d %d %d %d %d %d %d %d\n",
			view.used.bytes,
			view.used.streams,
			view.used.jobs,
			view.used.queued,
			view.used.running,
			view.used.held,
			view.rejected,
			view.peak.bytes,
			view.scope_nodes,
			capacity.current,
			capacity.growths,
			view.limits.bytes,
		)
		os.flush(os.stdout)
	}
}
large_response :: proc(state: ^State, request: ^server.Request) -> server.Response {
	size := mem.Megabyte

	if state.resource_mode == "mixed" {
		if request.path == "/slow" {
			size *= 4
		} else {
			size *= 3
		}
	}

	body, error := make([]u8, size, request.allocator)
	if error != nil {
		return {status = .Internal_Server_Error}
	}

	return {status = .OK, body = body}
}
work_response :: proc(state: ^State, request: ^server.Request) -> server.Response {
	backing := mem.tracking_allocator(&state.tracker)
	binding, error := charged.create(request.resources, {backing = backing, metadata_allocator = backing})
	if error.kind != .None {
		return {status = .Internal_Server_Error}
	}
	allocator := charged.allocator(binding)
	job, je := new(Job, allocator)

	if je != nil {
		charged.release(&binding)
		return {status = .Service_Unavailable}
	}

	job.binding, job.allocator, job.state = binding, allocator, state
	job.failed = request.path == "/fail"
	bytes, be := make([]u8, len(request.body), allocator)

	if be != nil {
		drop(job)
		return {status = .Service_Unavailable}
	}

	job.bytes = bytes
	copy(job.bytes, request.body)
	work := pool.Work{job, run, drop}
	response, ok := adapter.response(&state.pool, &work, build)

	if !ok {
		drop(job)
		return {status = .Internal_Server_Error}
	}

	return response
}
Resource_Producer :: struct {
	allocator: mem.Allocator,
	sequence:  int,
}
resource_stream :: proc(request: ^server.Request) -> server.Response {
	producer, error := new(Resource_Producer, request.backing_allocator)
	if error != nil {
		return {status = .Service_Unavailable}
	}
	producer.allocator = request.backing_allocator

	return {
		stream = {
			data = producer,
			next = resource_next,
			drop = resource_drop,
			content_length = 16 * mem.Megabyte,
			max_body_bytes = 32 * mem.Megabyte,
		},
	}
}
resource_next :: proc(p: rawptr, io: ^server.Stream_IO) -> server.Stream_Step {
	producer := cast(^Resource_Producer)p
	if producer.sequence == 256 {
		return .Done
	}
	chunk, error := owned.allocate(64 * mem.Kilobyte, io.backing_allocator)
	if error.kind != .None {
		return .Failed
	}

	if server.stream_submit(io, &chunk) != .Accepted {
		owned.destroy(&chunk)
		return .Failed
	}

	producer.sequence += 1

	return .Chunk
}
resource_drop :: proc(p: rawptr) {
	producer := cast(^Resource_Producer)p
	free(producer, producer.allocator)
}

resource_config :: proc(state: ^State) -> server.Resource_Config {
	config := server.Resource_Config {
		parent = state.resources,
	}

	if state.resource_mode == "operation" {
		config.operation_limits = budgets.Limits{512 * mem.Kilobyte, 1, 1}
	}

	if state.resource_mode == "connection" {
		config.connection_limits = budgets.Limits{512 * mem.Kilobyte, 1, 4}
	}

	return config
}
resource_views :: proc(state: ^State, request: ^server.Request) -> server.Response {
	op, oe := budgets.snapshot(request.resources)
	assert(oe == .None)
	connection, ce := budgets.snapshot(server.request_connection_resources(request.cancellation))
	assert(ce == .None)
	global, ge := budgets.snapshot(state.resources)
	assert(ge == .None)
	body := fmt.aprintf(
		"%d %d %d %d %d %d",
		op.limits.bytes,
		connection.limits.bytes,
		global.limits.bytes,
		op.used.bytes,
		connection.used.bytes,
		global.used.bytes,
		allocator = request.allocator,
	)

	return {status = .OK, body = transmute([]u8)body}
}
