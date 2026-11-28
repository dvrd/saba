package main

import server "shared:saba"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:sync"
import "core:thread"
import "core:time"

State :: struct {
	control:        server.Server_Control,
	mutex:          sync.Mutex,
	result:         bool,
	count:          u64,
	observer_drain: bool,
}
state: State

routes :: proc(conn: ^server.Connection, request: ^server.Request) -> server.Response {
	assert(conn.write_deadline == time.Tick{}, "previous response deadline survived into next handler")
	arena := cast(^mem.Dynamic_Arena)request.allocator.data
	if request.path == "/arena" {
		assert(len(arena.out_band_allocations) == 0, "old request allocations survived")
	}

	if request.path == "/echo" || request.path == "/limited" {
		return server.make_response(request, .OK, nil, request.body)
	}

	if request.path == "/allocate" {
		body := make([]u8, 1024 * 1024, request.allocator)
		for &b in body {
			b = 42
		}
		return server.make_response(request, .OK, nil, body)
	}

	if request.path == "/slow" {
		time.sleep(70 * time.Millisecond)
	}
	if request.path == "/drain" {
		assert(server.drain_server(&state.control, 250 * time.Millisecond))
	}
	_ = server.match_route(request, request.method, "/:route")
	body := fmt.aprintf("%d", request.request_id, allocator = request.allocator)
	response := server.make_response(request, .OK, nil, transmute([]u8)body)
	if request.path == "/close" {
		response.close_connection = true
	}

	return response
}

main :: proc() {
	maximum, _ := strconv.parse_int(os.get_env("SABA_KEEP_MAX", context.temp_allocator))
	idle, _ := strconv.parse_int(os.get_env("SABA_KEEP_IDLE_MS", context.temp_allocator))
	capacity, _ := strconv.parse_int(os.get_env("SABA_KEEP_CAPACITY", context.temp_allocator))
	enabled := os.get_env("SABA_KEEP_DISABLED", context.temp_allocator) != "1"
	state.observer_drain = os.get_env("SABA_KEEP_OBSERVER_DRAIN", context.temp_allocator) == "1"
	// The header, body and response deadlines in milliseconds. A scenario
	// about one of them sets it; the others keep a default generous enough
	// that a loaded machine never trips them by accident.
	header, body, response := deadline("SABA_KEEP_HEADER_MS"), deadline("SABA_KEEP_BODY_MS"), deadline("SABA_KEEP_RESPONSE_MS")
	worker := thread.create_and_start_with_poly_data({maximum, idle, capacity, enabled, header, body, response}, proc(config: struct {
			maximum, idle, capacity: int,
			enabled:                 bool,
			header, body, response:  time.Duration,
		}) {
		state.result = server.serve({
			port = 0,
			handler = routes,
			workers = 2,
			control = &state.control,
			max_connections = config.capacity,
			timeouts = {header = config.header, body = config.body, response = config.response, idle = 100 * time.Millisecond},
			keep_alive = {enabled = config.enabled, max_requests = config.maximum, idle_timeout = time.Duration(config.idle) * time.Millisecond},
			request_body_limit = proc(request: ^server.Request) -> int {return 4 if request.path == "/limited" else 4096},
			observability = {enabled = true, data = &state, on_complete = proc(data: rawptr, event: ^server.Request_Event) {
					state := cast(^State)data
					_, valid := server.server_metrics(&state.control)
					assert(valid)
					sync.lock(&state.mutex)
					state.count += 1
					start_drain := state.observer_drain && state.count == 1
					fmt.printf("event %d %s %s %d %d %d %v\n", event.request_id, event.method, event.route if event.route != "" else "-", int(event.status), event.bytes_received, event.bytes_sent, event.outcome)
					os.flush(os.stdout)
					sync.unlock(&state.mutex)
					if start_drain {
						assert(server.drain_server(&state.control, 250 * time.Millisecond))
					}
				}},
		})
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
	command: [1]u8
	os.read(os.stdin, command[:])

	if command[0] == 'd' {
		assert(server.drain_server(&state.control, 250 * time.Millisecond))
		assert(!server.server_ready(&state.control))
		fmt.println("draining")
		os.flush(os.stdout)
	} else if command[0] != 'j' {
		server.stop_server(&state.control)
	}

	thread.join(worker)
	thread.destroy(worker)
	assert(state.result)
	_, alive := server.server_metrics(&state.control)
	assert(!alive)
	fmt.printf("stopped %d\n", state.count)
	os.flush(os.stdout)
}

// The deadline a SABA_KEEP_<NAME>_MS variable sets, or ten seconds.
deadline :: proc(variable: string) -> time.Duration {
	milliseconds, ok := strconv.parse_int(os.get_env(variable, context.temp_allocator))
	return time.Duration(milliseconds) * time.Millisecond if ok && milliseconds > 0 else 10 * time.Second
}
