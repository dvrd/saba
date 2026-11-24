package main

import server "shared:saba"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"

State :: struct {
	control: server.Server_Control,
	mutex:   sync.Mutex,
	result:  bool,
}

state: State

routes :: proc(_: ^server.Connection, request: ^server.Request) -> server.Response {
	assert(request.request_id != 0)

	if server.match_route(request, "GET", "/large") {
		// Small enough that the body and its wire copy fit the default operation budget.
		body := make([]u8, 8 * 1024 * 1024, request.allocator)
		for &value in body {
			value = 42
		}
		return server.make_response(request, .OK, nil, body)
	}

	if server.match_route(request, "POST", "/echo") {
		return server.make_response(request, .OK, nil, request.body)
	}

	_ = server.match_route(request, request.method, "/items/:id")

	return server.make_response(request, .OK, nil, transmute([]u8)string("ok"))
}

main :: proc() {
	worker := thread.create_and_start(proc() {
		state.result = server.serve(
			{
				port = 0,
				handler = routes,
				workers = 2,
				control = &state.control,
				timeouts = {
					header = 200 * time.Millisecond,
					body = 120 * time.Millisecond,
					response = 120 * time.Millisecond,
					idle = 80 * time.Millisecond,
				},
				observability = {
					enabled = true,
					data = &state,
					on_complete = proc(data: rawptr, event: ^server.Request_Event) {
						state := cast(^State)data
						metrics, valid := server.server_metrics(&state.control)
						assert(valid)
						assert(metrics.completed >= 1)
						sync.lock(&state.mutex)
						fmt.printf(
							"event %d %s %s %d %d %d %d %v\n",
							event.request_id,
							event.method,
							event.route if event.route != "" else "-",
							int(event.status),
							i64(event.duration),
							event.bytes_received,
							event.bytes_sent,
							event.outcome,
						)
						os.flush(os.stdout)
						sync.unlock(&state.mutex)
					},
				},
			},
		)
	})
	assert(worker != nil)
	limit := time.tick_add(time.tick_now(), 5 * time.Second)

	for time.tick_diff(time.tick_now(), limit) > 0 {
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
	command: [1]u8
	os.read(os.stdin, command[:])
	metrics, valid := server.server_metrics(&state.control)
	assert(valid)
	fmt.printf(
		"metrics %d %d %d %d %d %d %d\n",
		metrics.started,
		metrics.completed,
		metrics.active,
		metrics.timeouts,
		metrics.cancelled,
		metrics.bytes_received,
		metrics.bytes_sent,
	)
	server.stop_server(&state.control)
	thread.join(worker)
	thread.destroy(worker)
	assert(state.result)
	_, valid = server.server_metrics(&state.control)
	assert(!valid)
}
