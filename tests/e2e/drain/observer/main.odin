package main

import server "shared:saba"
import "base:intrinsics"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:thread"
import "core:time"

State :: struct {
	control: server.Server_Control,
	config:  server.Server,
	calls:   int,
	result:  bool,
}

completed :: proc(data: rawptr, event: ^server.Request_Event) {
	state := cast(^State)data
	metrics, valid := server.server_metrics(&state.control)
	assert(valid && metrics.completed == 1 && metrics.active == 0)
	assert(event.status == .OK && event.outcome == .Completed && event.request_id > 0)
	assert(server.server_state(&state.control) == .Ready)
	assert(server.drain_server(&state.control, time.Second))
	assert(!server.server_ready(&state.control))
	intrinsics.atomic_add(&state.calls, 1)
}
main :: proc() {
	context.logger = log.nil_logger()
	state: State
	workers, _ := strconv.parse_int(os.get_env("DRAIN_WORKERS", context.temp_allocator))
	state.config = {
		port = 0,
		workers = workers,
		control = &state.control,
		observability = {on_complete = completed, data = &state},
		handler = proc(_: ^server.Connection, request: ^server.Request) -> server.Response {
			assert(server.match_route(request, "GET", "/ok"))
			return {status = .OK, body = transmute([]u8)string("ok")}
		},
	}

	worker := thread.create_and_start_with_poly_data(&state, proc(state: ^State) {
		context.logger = log.nil_logger()
		state.result = server.serve(state.config)
	})
	assert(worker != nil)
	limit := time.tick_add(time.tick_now(), 5 * time.Second)
	for !server.server_ready(&state.control) && time.tick_diff(time.tick_now(), limit) > 0 {
		time.sleep(time.Millisecond)
	}
	endpoint, ready := server.server_endpoint(&state.control)
	assert(ready)
	fmt.printf("READY %d\n", endpoint.port)
	os.flush(os.stdout)
	thread.join(worker)
	thread.destroy(worker)
	assert(state.result && intrinsics.atomic_load(&state.calls) == 1)
	assert(server.server_state(&state.control) == .Stopped)
	fmt.println("observer drain completed once")
	os.flush(os.stdout)
	command: [1]u8
	os.read(os.stdin, command[:])
}
