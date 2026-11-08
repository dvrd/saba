package main

import rt "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import pool "shared:async/offload"
import server "shared:saba/core"
import adapter "shared:saba/offload"

State :: struct {
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
	state:  ^State,
	bytes:  []u8,
	failed: bool,
}
run :: proc(p: rawptr, _: pool.Work_Context) -> bool {
	job := cast(^Job)p
	sync.atomic_add(&job.state.runs, 1)
	assert(sync.sema_wait_with_timeout(&job.state.proceed, 10 * time.Second))
	return !job.failed
}
drop :: proc(p: rawptr) {
	job := cast(^Job)p
	allocator := mem.tracking_allocator(&job.state.tracker)
	sync.atomic_add(&job.state.drops, 1)
	delete(job.bytes, allocator); free(job, allocator)
}
build :: proc(p: rawptr, allocator: mem.Allocator) -> (server.Response, bool) {
	job := cast(^Job)p
	bytes, error := make([]u8, len(job.bytes), allocator)
	if error != nil do return {}, false
	copy(bytes, job.bytes)
	return {status = .Created, body = bytes}, true
}
route :: proc(p: rawptr, _: ^server.Connection, request: ^server.Request) -> server.Response {
	state := cast(^State)p
	if request.path == "/file-status" && state.file_path != "" {
		s := pool.stats(&state.file_pool)
		body := fmt.aprintf(
			"%d %d %d",
			s.running,
			s.queued,
			s.retained,
			allocator = request.allocator,
		)
		return {status = .OK, body = transmute([]u8)body}
	}
	if request.path == "/file" && state.file_path != "" do return file_response(state)
	if request.path == "/release" {
		for _ in 0 ..< 4 do sync.post(&state.proceed)
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
	allocator := mem.tracking_allocator(&state.tracker)
	job := new(Job, allocator)
	job.state, job.failed = state, request.path == "/fail"
	job.bytes = make([]u8, len(request.body), allocator); copy(job.bytes, request.body)
	work := pool.Work{job, run, drop}
	response, ok := adapter.response(&state.pool, &work, build)
	if !ok {
		drop(job); return {status = .Internal_Server_Error}
	}
	return response
}
observe :: proc(p: rawptr, event: ^server.Request_Event) {
	if event.route == "/work" do sync.atomic_add(&(cast(^State)p).finished, 1)
}
serve :: proc(state: ^State) {
	budget, _ := strconv.parse_int(os.get_env("SABA_OFFLOAD_BUDGET_MS", context.temp_allocator))
	state.result = server.serve(
		{
			port = 0,
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
	assert(pool.init(&state.pool, {workers = 2, capacity = 4}) == .None)
	state.file_path = os.get_env("SABA_OFFLOAD_FIFO", context.temp_allocator)
	if state.file_path != "" {
		assert(pool.init(&state.file_pool, {workers = 1, capacity = 1}) == .None)
	}
	worker := thread.create_and_start_with_poly_data(&state, serve); assert(worker != nil)
	for _ in 0 ..< 5000 {
		endpoint, ready := server.server_endpoint(&state.control)
		if ready {
			fmt.printf("ready %d\n", endpoint.port); os.flush(os.stdout); break
		}
		time.sleep(time.Millisecond)
	}
	_, ready := server.server_endpoint(&state.control); assert(ready)
	command: [1]u8; os.read(os.stdin, command[:])
	if command[0] == 'd' {
		assert(server.drain_server(&state.control, 50 * time.Millisecond))
	} else {
		server.stop_server(&state.control)
	}
	thread.join(worker); thread.destroy(worker); assert(state.result)
	fmt.printf("retired %d\n", sync.atomic_load(&state.finished)); os.flush(os.stdout)
	// The harness observes request retirement before blocked work can finish.
	os.read(os.stdin, command[:])
	pool.shutdown(&state.pool)
	for _ in 0 ..< 4 do sync.post(&state.proceed)
	assert(pool.join(&state.pool) == .None); assert(pool.destroy(&state.pool) == .None)
	if state.file_path != "" {
		pool.shutdown(&state.file_pool)
		assert(pool.join(&state.file_pool) == .None)
		assert(pool.destroy(&state.file_pool) == .None)
	}
	assert(state.tracker.current_memory_allocated == 0 && len(state.tracker.bad_free_array) == 0)
	mem.tracking_allocator_destroy(&state.tracker)
	fmt.printf("stopped %d %d\n", state.runs, state.drops); os.flush(os.stdout)
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
	if error != nil do return false
	defer os.close(file)
	n, read_error := os.read(file, job.bytes[:])
	job.used = n
	return read_error == nil
}
file_drop :: proc(p: rawptr) {
	job := cast(^File_Job)p
	allocator := mem.tracking_allocator(&job.state.tracker)
	delete(job.path, allocator); free(job, allocator)
}
file_build :: proc(p: rawptr, allocator: mem.Allocator) -> (server.Response, bool) {
	job := cast(^File_Job)p
	bytes, error := make([]u8, job.used, allocator)
	if error != nil do return {}, false
	copy(bytes, job.bytes[:job.used])
	return {status = .OK, body = bytes}, true
}
file_response :: proc(state: ^State) -> server.Response {
	allocator := mem.tracking_allocator(&state.tracker)
	job := new(File_Job, allocator); job.state = state
	path, error := strings.clone(state.file_path, allocator)
	if error != nil {
		free(job, allocator); return {status = .Internal_Server_Error}
	}
	job.path = path
	work := pool.Work{job, file_run, file_drop}
	response, ok := adapter.response(&state.file_pool, &work, file_build)
	if !ok {
		file_drop(job); return {status = .Internal_Server_Error}
	}
	return response
}
