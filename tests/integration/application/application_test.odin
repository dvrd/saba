package saba_application

import core "../core"
import development "../development"
import modules_api "../modules"
import "core:mem"
import "core:log"
import "core:strings"
import "core:testing"

@(test)
application_preserves_core_handler_state_and_routes :: proc(t: ^testing.T) {
	calls := 0
	state := State {
		config = {
			server = {
				handler_data = &calls,
				handler = proc(data: rawptr, _: ^core.Connection, r: ^core.Request) -> core.Response {
					(cast(^int)data)^ += 1
					assert(core.match_route(r, "POST", "/items/:id"))
					assert(core.path_value(r, "id") == "42")
					return {status = .Accepted, body = r.body}
				},
			},
		},
	}

	request := core.Request {
		method = "POST",
		path   = "/items/42",
		body   = []u8{'o', 'k'},
	}

	connection: core.Connection
	response := handle_request(&state, &connection, &request)
	testing.expect_value(t, calls, 1)
	testing.expect_value(t, response.status, .Accepted)
	testing.expect_value(t, string(response.body), "ok")
}

@(test)
application_builtin_priority_and_development_injection :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)
	state := State {
		config = {
			development = true,
			server = {handler = proc(_: rawptr, _: ^core.Connection, r: ^core.Request) -> core.Response {
					return core.make_response(
						r,
						.OK,
						{{"Content-Type", "text/html"}},
						transmute([]u8)string("<head></head>"),
					)
				}},
		},
	}

	request := core.Request {
		method    = "GET",
		path      = "/plain",
		allocator = allocator,
	}

	connection: core.Connection
	response := handle_request(&state, &connection, &request)
	testing.expect(t, strings.contains(string(response.body), development.RELOAD_CLIENT_TAG))
	request.path = modules_api.JSX_RUNTIME_URL
	runtime_response, matched := builtin_response(&state, &request)
	testing.expect(t, matched)
	testing.expect_value(t, runtime_response.status, .OK)
	testing.expect(t, len(runtime_response.body) > 0)
}

@(test)
application_serves_window_modules_as_conditional_representations :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	state: State
	request := core.Request {allocator = mem.dynamic_arena_allocator(&arena)}
	for source in ([]struct {path, body: string} {
		{modules_api.SLIDING_WINDOW_URL, modules_api.SLIDING_WINDOW},
		{modules_api.SLOT_WINDOW_URL, modules_api.SLOT_WINDOW},
		{modules_api.SCALAR_RECORDS_URL, modules_api.SCALAR_RECORDS},
	}) {
		request.path = source.path
		for method in ([]string{"GET", "HEAD"}) {
			request.method = method
			request.headers = nil
			response, matched := builtin_response(&state, &request)
			if !testing.expect(t, matched && response.status == .OK && len(response.headers) >= 3) {
				return
			}
			// The transport suppresses HEAD bodies after computing their representation length.
			testing.expect_value(t, string(response.body), source.body)
			testing.expect_value(t, response.headers[0].value, "text/javascript; charset=utf-8")
			testing.expect_value(t, response.headers[2].name, "ETag")
			request.headers = {{"If-None-Match", response.headers[2].value}}
			conditional, found := builtin_response(&state, &request)
			testing.expect(t, found)
			testing.expect_value(t, conditional.status, .Not_Modified)
			testing.expect_value(t, len(conditional.body), 0)
		}
		request.method = "POST"
		_, matched := builtin_response(&state, &request)
		testing.expect(t, !matched)
	}
}

@(test)
application_context_adapter_borrows_live_development_state :: proc(t: ^testing.T) {
	calls := 0
	state := State {
		config = {
			development = true,
			server = {handler_data = &calls},
			dispatch = proc(data: rawptr, view: ^Dispatch_Context) -> core.Response {
				assert(view.connection != nil && view.request != nil && view.reload != nil)
				(cast(^int)data)^ += 1
				return {status = .No_Content}
			},
		},
	}

	request := core.Request {
		method = "GET",
		path   = "/plain",
	}

	connection: core.Connection
	response := handle_request(&state, &connection, &request)
	testing.expect_value(t, calls, 1)
	testing.expect_value(t, response.status, .No_Content)
}

@(test)
application_rejects_missing_or_ambiguous_handlers_before_listening :: proc(t: ^testing.T) {
	context.logger = log.nil_logger() // Rejection is the intended result.
	testing.expect(t, !serve({}))
	testing.expect(t, !serve({
			server = {handler = proc(_: rawptr, _: ^core.Connection, _: ^core.Request) -> core.Response {
					return {}
				}},
			dispatch = proc(_: rawptr, _: ^Dispatch_Context) -> core.Response {return {}},
		}))
}
