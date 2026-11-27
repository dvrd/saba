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
	control:  server.Server_Control,
	config:   server.Server,
	released: bool,
	result:   bool,
}
fixture: ^State

routes :: proc(_: ^server.Connection, request: ^server.Request) -> server.Response {
	if request.path == "/hold" {
		fmt.println("holding")
		os.flush(os.stdout)
		// Intentional test-only cooperative limitation: a real application must
		// offload blocking work. The control thread can release this callback.
		for !intrinsics.atomic_load(&fixture.released) {
			time.sleep(time.Millisecond)
		}
	}

	if request.path == "/echo" {
		return {status = .OK, body = request.body}
	}

	if request.path == "/large" {
		body := make([]u8, 8 * 1024 * 1024, request.allocator)
		return {status = .OK, body = body}
	}

	return {status = .OK, body = transmute([]u8)string("done")}
}

main :: proc() {
	context.logger = log.nil_logger()
	state: State
	fixture = &state
	// The server is stopped and its worker joined before main returns: nothing reads this frame afterwards.
	defer fixture = nil
	workers, _ := strconv.parse_int(os.get_env("DRAIN_WORKERS", context.temp_allocator))
	milliseconds, _ := strconv.parse_int(os.get_env("DRAIN_MS", context.temp_allocator))
	state.config = {
		port          = 0,
		workers       = workers,
		handler       = routes,
		control       = &state.control,
		drain_timeout = time.Duration(milliseconds) * time.Millisecond,
	}

	web := os.get_env("DRAIN_WEB", context.temp_allocator)

	if web != "" {
		state.config.development = true
		state.config.hot_reload_directory = web
	}

	if os.get_env("DRAIN_PRESTART", context.temp_allocator) == "1" {
		for _ in 0 ..< 2 {
			assert(server.drain_server(&state.control))
			assert(server.serve(state.config))
			assert(server.server_state(&state.control) == .Stopped)
		}

		fmt.println("prestart drained")
		return
	}

	worker := thread.create_and_start_with_poly_data(&state, proc(state: ^State) {
		context.logger = log.nil_logger()
		state.result = server.serve(state.config)
		fmt.printf("finished %v\n", state.result)
		os.flush(os.stdout)
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
	joined := false

	for {
		command: [1]u8
		n, error := os.read(os.stdin, command[:])

		if error != nil || n == 0 {
			server.stop_server(&state.control)
			break
		}

		switch command[0] {
		case 'd':
			assert(server.drain_server(&state.control))
			fmt.printf("drain %v %v\n", server.server_state(&state.control), server.server_ready(&state.control))
		case 'f':
			assert(server.drain_server(&state.control, 100 * time.Millisecond))
			fmt.printf("drain %v %v\n", server.server_state(&state.control), server.server_ready(&state.control))
		case 's':
			server.stop_server(&state.control)
		case 'r':
			intrinsics.atomic_store(&state.released, true)
		case 'c':
			capacity, valid := server.server_capacity(&state.control)
			fmt.printf("capacity %d %v\n", capacity.active, valid)
		case 'j':
			thread.join(worker)
			assert(state.result)
			assert(server.server_state(&state.control) == .Stopped)
			assert(!server.server_ready(&state.control))
			fmt.println("joined")
			joined = true
		case 'q':
			assert(joined)
			thread.destroy(worker)
			return
		}

		os.flush(os.stdout)
	}

	intrinsics.atomic_store(&state.released, true)

	if !joined {
		thread.join(worker)
	}

	thread.destroy(worker)
}
