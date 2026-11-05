package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:thread"
import "core:time"
import server "shared:saba"

State :: struct {
	control: server.Server_Control,
	config:  server.Server,
	result:  bool,
}

routes :: proc(conn: ^server.Connection, request: ^server.Request) -> server.Response {
	if request.path == "/echo" {
		return server.make_response(request, .OK, nil, request.body)
	}
	if request.path == "/large" {
		body := make([]u8, 2 * 1024 * 1024, request.allocator)
		for &value, i in body do value = u8(i % 251)
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
	state: State
	workers, _ := strconv.parse_int(os.get_env("SABA_TEST_WORKERS", context.temp_allocator))
	capacity, _ := strconv.parse_int(os.get_env("SABA_TEST_CAPACITY", context.temp_allocator))
	web := os.get_env("SABA_TEST_WEB", context.temp_allocator)
	development := os.get_env("SABA_TEST_DEVELOPMENT", context.temp_allocator) == "1"
	assets := []server.Asset_Mount{{directory = fmt.tprintf("%s/assets", web)}}
	modules := []server.Module_Mount{{directory = web}}
	state.config = {
		port = 0,
		handler = routes,
		workers = workers,
		max_connections = capacity,
		control = &state.control,
		request_body_limit = proc(_: ^server.Request) -> int {return 16384},
		development = development,
		hot_reload_directory = web,
		assets = assets,
		modules = modules,
		pages = {
			directory = fmt.tprintf("%s/pages", web),
			shell = fmt.tprintf("%s/index.html", web),
			module_prefix = "/pages/",
		},
	}
	if os.get_env("SABA_TEST_PRESTOP", context.temp_allocator) == "1" {
		server.stop_server(&state.control)
		assert(server.serve(state.config))
		fmt.println("stopped before startup")
		return
	}
	worker := thread.create_and_start_with_poly_data(
		&state,
		proc(state: ^State) {state.result = server.serve(state.config)},
	)
	assert(worker != nil)
	deadline := time.tick_add(time.tick_now(), 5 * time.Second)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		endpoint, ready := server.server_endpoint(&state.control)
		if ready {
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
	fmt.println("stopped")
	os.flush(os.stdout)
	// Stay alive until the test controller verifies peer closure. Process exit
	// must not conceal a descriptor that survived server shutdown.
	os.read(os.stdin, stop[:])
}
