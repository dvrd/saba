package saba_application

import core "../core"
import modules "../modules"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import async "shared:async"
import pool "shared:async/offload"
import signal "shared:async/signal"
import http "shared:async/http"
import surf "shared:surf"

Module_Fixture :: struct {
	control: core.Server_Control,
	config:  Config,
	ok:      bool,
}

@(test)
development_module_route_defers_and_rejects_when_the_lane_is_full :: proc(t: ^testing.T) {
	state := State {
		config = {development = true},
		modules = []modules.Module_Cache{{mount = {directory = ".", prefix = "/js/"}}},
	}
	assert(pool.init(&state.module_pool, {workers = 1, capacity = 1}) == .None)
	defer {
		pool.shutdown(&state.module_pool)
		assert(pool.join(&state.module_pool) == .None)
		assert(pool.destroy(&state.module_pool) == .None)
	}
	// The held handle occupies the only slot even if its worker finishes first.
	work := pool.Work {
		run = proc(_: rawptr, _: pool.Work_Context) -> bool {return true},
	}
	held, submitted := pool.submit(&state.module_pool, &work)
	assert(submitted == .None)
	defer pool.release(&held)
	request := core.Request {
		method    = "GET",
		path      = "/js/view.js",
		allocator = context.temp_allocator,
	}
	response, matched := builtin_response(&state, &request)
	defer core.discard_response(&response)
	if !testing.expect(t, matched && response.deferred.poll != nil) {
		return
	}
	runtime: async.Runtime
	task: async.Task
	wake, ok := signal.create(&runtime, &task)
	assert(ok)
	defer {
		signal.detach(wake)
		signal.release(&wake)
	}
	result, step := response.deferred.poll(
		response.deferred.data,
		&core.Deferred_IO{allocator = request.allocator, wake = wake},
	)
	testing.expect_value(t, step, .Ready)
	testing.expect_value(t, result.status, .Service_Unavailable)
}

@(test)
development_module_route_serves_fresh_jsx_and_diagnostics :: proc(t: ^testing.T) {
	root, error := os.make_directory_temp("", "saba-module-*", context.temp_allocator)
	assert(error == nil)
	defer os.remove_all(root)
	source := fmt.tprintf("%s/view.jsx", root)
	assert(os.write_entire_file(source, "export default <h1>Hello</h1>;") == nil)

	fixture: Module_Fixture
	fixture.config = {
		server = {
			control = &fixture.control,
			workers = 1,
			port = 0,
			handler = proc(_: rawptr, _: ^core.Connection, _: ^core.Request) -> core.Response {
				return {status = .Accepted}
			},
		},
		modules = []modules.Module_Mount{{directory = root, prefix = "/js/"}},
		development = true,
		hot_reload_directory = root,
	}
	worker := thread.create_and_start_with_poly_data(
		&fixture,
		proc(f: ^Module_Fixture) {f.ok = serve(f.config)},
	)
	assert(worker != nil)
	defer {
		core.stop_server(&fixture.control)
		thread.join(worker)
		thread.destroy(worker)
		testing.expect(t, fixture.ok)
	}
	// A startup bound only: generous, since a loaded machine can take seconds
	// to start serve, and nothing here measures it.
	deadline := time.tick_add(time.tick_now(), 60 * time.Second)
	for !core.server_ready(&fixture.control) && time.tick_diff(time.tick_now(), deadline) > 0 {
		time.sleep(time.Millisecond)
	}
	endpoint, ready := core.server_endpoint(&fixture.control)
	if !testing.expect(t, ready) {
		return
	}
	get := proc(port: int, path: string, method: surf.Method = .GET) -> surf.Response {
		url := fmt.tprintf("http://127.0.0.1:%d%s", port, path)
		response, err := surf.execute(
			{method = method, url = url},
			{allow_http = true, timeout = 5 * time.Second},
		)
		assert(err.kind == .None)
		return response
	}
	port := int(endpoint.port)
	first := get(port, "/js/view.js")
	defer surf.response_destroy(&first)
	testing.expect_value(t, first.status, 200)
	testing.expect(t, strings.contains(string(first.body), "__saba_jsx("))
	cache, _ := surf.response_header(&first, "Cache-Control")
	testing.expect_value(t, cache, "no-store")

	head := get(port, "/js/view.js", .HEAD)
	defer surf.response_destroy(&head)
	length, _ := surf.response_header(&head, "Content-Length")
	testing.expect_value(t, head.status, 200)
	testing.expect_value(t, len(head.body), 0)
	testing.expect_value(t, length, fmt.tprintf("%d", len(first.body)))

	assert(os.write_entire_file(source, "const x = <b></p>;") == nil)
	broken := get(port, "/js/view.js")
	defer surf.response_destroy(&broken)
	testing.expect_value(t, broken.status, 500)
	testing.expect(t, strings.contains(string(broken.body), "view.jsx:1:"))
	missing := get(port, "/js/missing.js")
	defer surf.response_destroy(&missing)
	testing.expect_value(t, missing.status, 404)
	fallback := get(port, "/other")
	defer surf.response_destroy(&fallback)
	testing.expect_value(t, fallback.status, 202)
}
