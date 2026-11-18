package main

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:thread"
import "core:time"
import server "shared:saba"

State :: struct {
	assets:  [1]server.Asset_Mount,
	modules: [1]server.Module_Mount,
	control: server.Server_Control,
	config:  server.Server,
	result:  bool,
	logger:  log.Logger,
}

fixture_control: ^server.Server_Control

growth_fail_size: int
growth_fail_enabled: bool

growth_allocator :: proc(
	_: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> (
	[]u8,
	mem.Allocator_Error,
) {
	if (mode == .Alloc || mode == .Alloc_Non_Zeroed) &&
	   size == growth_fail_size &&
	   intrinsics.atomic_load(&growth_fail_enabled) {
		return nil, .Out_Of_Memory
	}
	heap := runtime.heap_allocator()
	return heap.procedure(heap.data, mode, size, alignment, old_memory, old_size, location)
}

routes :: proc(conn: ^server.Connection, request: ^server.Request) -> server.Response {
	context.allocator = request.allocator
	context.temp_allocator = request.allocator

	if request.path == "/allow-growth" {
		intrinsics.atomic_store(&growth_fail_enabled, false)
	}

	if request.path == "/capacity" {
		state, valid := server.server_capacity(fixture_control)
		assert(valid)
		body := fmt.aprintf(
			"%d,%d,%d,%d,%d,%d",
			state.current,
			state.maximum,
			state.peak,
			state.growths,
			state.rejected_capacity,
			state.growth_failures,
		)
		return server.make_response(request, .OK, nil, transmute([]u8)body)
	}

	if request.path == "/echo" {
		return server.make_response(request, .OK, nil, request.body)
	}

	if request.path == "/large" {
		body := make([]u8, 2 * 1024 * 1024, request.allocator)
		for &value, i in body {
			value = u8(i % 251)
		}
		return server.make_response(request, .OK, nil, body)
	}

	if request.path == "/html" {
		return server.make_response(
			request,
			.OK,
			{{"Content-Type", "text/html"}},
			transmute([]u8)string("<html><head></head><body>hello</body></html>"),
		)
	}

	return server.make_response(request, .OK, nil, transmute([]u8)string("ok"))
}

main :: proc() {
	context.logger = log.create_file_logger(os.stderr)
	defer log.destroy_file_logger(context.logger)
	state: State
	state.logger = context.logger
	fixture_configure(&state)
	// The server is stopped and its worker joined before main returns: nothing reads this frame afterwards.
	defer fixture_control = nil

	if os.get_env("SABA_TEST_PRESTOP", context.temp_allocator) == "1" {
		server.stop_server(&state.control)
		assert(server.serve(state.config))
		fmt.println("stopped before startup")
		return
	}

	worker := thread.create_and_start_with_poly_data(&state, proc(state: ^State) {
		context.logger = state.logger
		state.result = server.serve(state.config)
	})
	assert(worker != nil)
	deadline := time.tick_add(time.tick_now(), 5 * time.Second)

	for time.tick_diff(time.tick_now(), deadline) > 0 {
		endpoint, ready := server.server_endpoint(&state.control)

		if ready {
			intrinsics.atomic_store(
				&growth_fail_enabled,
				os.get_env("SABA_TEST_FAIL_GROWTH", context.temp_allocator) == "1",
			)
			fmt.printf("ready %d\n", endpoint.port)
			os.flush(os.stdout)
			break
		}

		time.sleep(time.Millisecond)
	}

	_, ready := server.server_endpoint(&state.control)
	assert(ready, "server did not start")
	stop: [1]u8
	os.read(os.stdin, stop[:])
	server.stop_server(&state.control)
	thread.join(worker)
	thread.destroy(worker)
	assert(state.result, "server reported failure")
	_, alive := server.server_endpoint(&state.control)
	assert(!alive, "shutdown retained runtime pointer")
	_, alive = server.server_capacity(&state.control)
	assert(!alive, "shutdown retained capacity pointer")
	fmt.println("stopped")
	os.flush(os.stdout)
	// Stay alive until the test controller verifies peer closure. Process exit
	// must not conceal a descriptor that survived server shutdown.
	os.read(os.stdin, stop[:])
}

fixture_configure :: proc(state: ^State) {
	fixture_control = &state.control
	workers, _ := strconv.parse_int(os.get_env("SABA_TEST_WORKERS", context.temp_allocator))
	capacity, _ := strconv.parse_int(os.get_env("SABA_TEST_CAPACITY", context.temp_allocator))
	initial, _ := strconv.parse_int(os.get_env("SABA_TEST_INITIAL", context.temp_allocator))
	growth_fail_size = (initial * 2 + workers + 1) * size_of(rawptr)
	web := os.get_env("SABA_TEST_WEB", context.temp_allocator)
	development := os.get_env("SABA_TEST_DEVELOPMENT", context.temp_allocator) == "1"
	state.assets[0] = {
		directory = fmt.tprintf("%s/assets", web),
	}

	state.modules[0] = {
		directory = web,
	}

	state.config = {
		port = 0,
		handler = routes,
		workers = workers,
		max_connections = capacity,
		initial_connections = initial,
		runtime_allocator = {growth_allocator, nil},
		control = &state.control,
		request_body_limit = proc(_: ^server.Request) -> int {return 16384},
		development = development,
		hot_reload_directory = web,
		assets = state.assets[:],
		modules = state.modules[:],
		pages = {
			directory = fmt.tprintf("%s/pages", web),
			shell = fmt.tprintf("%s/index.html", web),
			module_prefix = "/pages/",
		},
	}
}
