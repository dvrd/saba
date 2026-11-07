package saba_core

import "core:mem"
import "core:strings"
import "core:sync"
import "core:time"
import async "shared:async"

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
			if !http_token(value) || strings.equal_fold(value, "close") do return true
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
	init_connection_arena(task)
	task.observed, task.observation_finished, task.response_finished = false,false,false
	task.event = {}
	task.observed_at = {}
	task.header_used, task.body_used = 0,0
	task.output_index, task.output_offset = 0,0
	task.reuse_after_write = false
	task.finish_after_write = true
	task.header = task.initial_header[:]
	if count > len(task.header) {
		buffer, err := make([]u8,count,mem.dynamic_arena_allocator(&task.arena))
		if err != nil do return false
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
