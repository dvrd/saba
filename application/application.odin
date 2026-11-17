// Database-free composition of the lean server and selected reusable adapters.
package saba_application

import core "../core"
import assets_api "../assets"
import modules_api "../modules"
import pages_api "../pages"
import development "../development"
import "core:log"
import "core:mem"
import "core:sync"
import "core:thread"

Config :: struct {
	server:               core.Server,
	modules:              []modules_api.Module_Mount,
	assets:               []assets_api.Asset_Mount,
	asset_limits:         assets_api.Asset_Limits,
	pages:                pages_api.Page_Mount,
	development:          bool,
	hot_reload_directory: string,
	// Optional handler adapter; mutually exclusive with server.handler.
	// Uses server.handler_data and receives only call-scoped borrows.
	dispatch:             proc(data: rawptr, view: ^Dispatch_Context) -> core.Response,
}

Dispatch_Context :: struct {
	connection: ^core.Connection,
	request:    ^core.Request,
	// Nil outside development. Borrow only until the handler returns.
	reload:     ^development.Reload_State,
}

@(private)
State :: struct {
	config:  Config,
	modules: []modules_api.Module_Cache,
	assets:  []assets_api.Asset_Cache,
	pages:   pages_api.Page_Cache,
	reload:  development.Reload_State,
}

// Config, handler state and any borrowed inputs remain valid until return.
// Preparation precedes listening; watcher and prepared storage retire after serve.
serve :: proc(config: Config) -> bool {
	if (config.server.handler == nil) == (config.dispatch == nil) {
		log.error("Exactly one application handler is required")
		return false
	}

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)
	state := State {
		config = config,
	}

	defer assets_api.destroy_assets(&state.assets, allocator)
	if !prepare(&state, allocator) {
		return false
	}
	watcher: ^thread.Thread
	defer {
		sync.atomic_store(&state.reload.stopped, true)

		if watcher != nil {
			thread.join(watcher)
			thread.destroy(watcher)
		}
	}

	if config.development {
		watcher = start_watcher(&state)
		if watcher == nil {
			return false
		}
	}

	server := config.server
	server.handler, server.handler_data = handle_request, &state

	return core.serve(server)
}

@(private)
prepare :: proc(state: ^State, allocator: mem.Allocator) -> bool {
	config := &state.config
	valid: bool
	state.modules, valid = modules_api.prepare_module_mounts(config.modules, config.development, allocator)
	if !valid {
		return false
	}
	state.pages, valid = pages_api.prepare_pages(config.pages, config.development, allocator)
	if !valid {
		return false
	}
	error: assets_api.Asset_Error
	state.assets, error = assets_api.prepare_assets_bounded(config.assets, config.asset_limits, allocator)

	if error.kind != .None {
		log.errorf(
			"Asset preload failed: %v mount=%d limit=%d observed=%d",
			error.kind,
			error.mount_index,
			error.limit,
			error.observed,
		)
		return false
	}

	return true
}

@(private)
start_watcher :: proc(state: ^State) -> ^thread.Thread {
	directory := state.config.hot_reload_directory
	if directory == "" {
		directory = "web"
	}
	signature, ready := development.web_signature(directory)
	if !ready {
		return nil
	}
	state.reload = {
		directory         = directory,
		initial_signature = signature,
		logger            = context.logger,
	}

	return thread.create_and_start_with_poly_data(&state.reload, development.watch_web)
}

@(private)
handle_request :: proc(data: rawptr, connection: ^core.Connection, request: ^core.Request) -> core.Response {
	state := cast(^State)data
	response, matched := builtin_response(state, request)

	if !matched {
		if state.config.dispatch != nil {
			view := Dispatch_Context {
				connection = connection,
				request    = request,
			}

			if state.config.development {
				view.reload = &state.reload
			}
			response = state.config.dispatch(state.config.server.handler_data, &view)
		} else {
			response = state.config.server.handler(state.config.server.handler_data, connection, request)
		}
	}

	if state.config.development && !core.streaming_response(response) && development.reload_html_response(response) {
		body, ok := development.inject_reload_client(response.body, request.allocator)

		if !ok {
			response.status = .Internal_Server_Error
			response.headers, response.body = nil, nil
			return response // Preserve transferred owners for the core's rejection disposal.
		}

		if body != nil {
			response.body = body
		}
	}

	return response
}

@(private)
builtin_response :: proc(state: ^State, request: ^core.Request) -> (core.Response, bool) {
	if state.config.development {
		response, matched := development.handle(&state.reload, request)
		if matched {
			return response, true
		}
	}

	if core.match_route(request, "GET", modules_api.JSX_RUNTIME_URL) ||
	   core.match_route(request, "HEAD", modules_api.JSX_RUNTIME_URL) {
		return modules_api.jsx_runtime_response(request), true
	}

	if core.match_route(request, "GET", modules_api.PAGE_ENTRY_URL) ||
	   core.match_route(request, "HEAD", modules_api.PAGE_ENTRY_URL) {
		return modules_api.page_entry_response(request), true
	}

	response, matched := assets_api.serve_assets(request, state.assets, state.config.development)
	if matched {
		return response, true
	}
	response, matched = modules_api.serve_prepared_modules(request, state.modules, state.config.development)
	if matched {
		return response, true
	}

	return pages_api.serve_prepared_pages(request, state.pages, state.config.development)
}
