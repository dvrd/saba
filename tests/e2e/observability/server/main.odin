// A server that prints one line per completed request. Each of its four
// timeouts is a minute unless the test names it, in milliseconds:
// SABA_OBSERVE_HEADER_MS, SABA_OBSERVE_BODY_MS, SABA_OBSERVE_RESPONSE_MS and
// SABA_OBSERVE_IDLE_MS. On stdin, m prints a "snapshot" of the metrics and
// any other byte prints the "metrics" line and stops the server.
package main

import server "shared:saba"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:sync"
import "core:thread"
import "core:time"

State :: struct {
	control: server.Server_Control,
	mutex:   sync.Mutex,
	result:  bool,
}

state: State

timeout :: proc(name: string) -> time.Duration {
	milliseconds, _ := strconv.parse_int(os.get_env(name, context.temp_allocator))
	if milliseconds <= 0 {
		return time.Minute
	}
	return time.Duration(milliseconds) * time.Millisecond
}

report :: proc(label: string) {
	metrics, valid := server.server_metrics(&state.control)
	assert(valid)
	sync.lock(&state.mutex)
	fmt.printf(
		"%s %d %d %d %d %d %d %d\n",
		label,
		metrics.started,
		metrics.completed,
		metrics.active,
		metrics.timeouts,
		metrics.cancelled,
		metrics.bytes_received,
		metrics.bytes_sent,
	)
	os.flush(os.stdout)
	sync.unlock(&state.mutex)
}

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
					header = timeout("SABA_OBSERVE_HEADER_MS"),
					body = timeout("SABA_OBSERVE_BODY_MS"),
					response = timeout("SABA_OBSERVE_RESPONSE_MS"),
					idle = timeout("SABA_OBSERVE_IDLE_MS"),
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
	// Polled until the listener is published or serve returns, with no bound of
	// its own: the test's ready timeout reports a server that never starts.
	for !thread.is_done(worker) {
		endpoint, ready := server.server_endpoint(&state.control)

		if ready {
			fmt.printf("READY %d\n", endpoint.port)
			os.flush(os.stdout)
			break
		}

		time.sleep(time.Millisecond)
	}

	_, ready := server.server_endpoint(&state.control)
	assert(ready)
	for {
		command: [1]u8
		n, error := os.read(os.stdin, command[:])
		if n != 1 || error != nil || command[0] != 'm' {
			break
		}
		report("snapshot")
	}
	report("metrics")
	server.stop_server(&state.control)
	thread.join(worker)
	thread.destroy(worker)
	assert(state.result)
	_, valid := server.server_metrics(&state.control)
	assert(!valid)
}
