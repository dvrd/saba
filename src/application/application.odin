// Database-free composition of the lean server and selected reusable adapters.
package saba_application

import core "../core"
import assets_api "../assets"
import modules_api "../modules"
import pages_api "../pages"
import development "../development"
import rt "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import pool "shared:async/offload"

Config :: struct {
	server:               core.Server,
	modules:              []modules_api.Module_Mount,
	// Zero fields select the asset defaults for compiled module mounts.
	module_limits:        assets_api.Asset_Limits,
	assets:               []assets_api.Asset_Mount,
	asset_limits:         assets_api.Asset_Limits,
	pages:                pages_api.Page_Mount,
	// Paths owned by the application handler ahead of asset, module and page
	// mounts. An entry ending in "/" also owns descendants of that directory.
	handler_routes:       []string,
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

State :: struct {
	config:      Config,
	modules:     []modules_api.Module_Cache,
	module_pool: pool.Pool,
	assets:      []assets_api.Asset_Cache,
	pages:       pages_api.Page_Cache,
	page_lock:   sync.RW_Mutex,
	page_arena:  ^mem.Dynamic_Arena,
	reload:      development.Reload_State,
}

// Config, handler state and any borrowed inputs remain valid until return.
// Preparation precedes listening; watcher and prepared storage retire after serve.
serve :: proc(config: Config) -> (ok: bool) {
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
	defer { release_page_arena(state.page_arena) }
	// Runs before the arena release above: late generations live outside it.
	defer pages_api.release_build(&state.pages.build)

	defer assets_api.destroy_assets(&state.assets, allocator)
	if !prepare(&state, allocator) {
		return false
	}
	// Only on-demand module reads and JSX transformations use this lane.
	// Capacity includes queued, running and completed jobs awaiting delivery.
	needs_module_pool := config.development && len(state.modules) > 0
	if needs_module_pool {
		if error := pool.init(&state.module_pool, {workers = 2, capacity = 16}); error != .None {
			log.error("Could not start development module workers:", error)
			return false
		}
	}
	defer {
		if needs_module_pool {
			pool.shutdown(&state.module_pool)
			joined := pool.join(&state.module_pool)
			destroyed := pool.destroy(&state.module_pool)
			if joined != .None || destroyed != .None {
				log.errorf("Development module pool teardown failed (join %v, destroy %v)", joined, destroyed)
				ok = false
			}
		}
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

prepare :: proc(state: ^State, allocator: mem.Allocator) -> bool {
	config := &state.config
	for path in config.handler_routes {
		if !strings.has_prefix(path, "/") || strings.contains_any(path, "?#%\\") ||
		   strings.contains(path, "//") || path == "/__saba" || strings.has_prefix(path, "/__saba/") {
			log.errorf("Invalid application route reservation: %s", path)
			return false
		}
	}
	// Hash and compress the framework modules now rather than on a request.
	modules_api.prepare_builtin_modules()
	valid: bool
	state.modules, valid = modules_api.prepare_module_mounts(config.modules, config.development, allocator, config.module_limits)
	if !valid {
		log.error("Could not prepare module mounts")
		return false
	}
	build_modules := state.modules
	if config.development && len(config.pages.templates.pages) != 0 {
		build_modules, valid = modules_api.prepare_module_mounts(config.modules, false, allocator, config.module_limits)
		if !valid {
			log.error("Could not compile module mounts for the page build")
			return false
		}
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

	state.pages, valid = pages_api.prepare_pages(config.pages, config.development, allocator, build_modules)
	if !valid {
		log.error("Could not prepare pages")
	}
	return valid
}

// A reservation owns a path however the client spelled it. Asset, module and
// page mounts match the percent-decoded path, so the reservation must as well:
// otherwise /%61dmin would reach the page that /admin was reserved to guard.
handler_route_reserved :: proc(routes: []string, request: ^core.Request) -> bool {
	if len(routes) == 0 {
		return false
	}
	paths := [2]string{request.path, ""}
	count := 1
	if strings.contains(request.path, "%") {
		if decoded, ok := net.percent_decode(request.path, request.allocator); ok && decoded != request.path {
			paths[1] = decoded
			count = 2
		}
	}
	for candidate in paths[:count] {
		for path in routes {
			if candidate == path || (len(path) > 1 && strings.has_suffix(path, "/") && strings.has_prefix(candidate, path)) {
				return true
			}
		}
	}
	return false
}

start_watcher :: proc(state: ^State) -> ^thread.Thread {
	directory := state.config.hot_reload_directory
	if directory == "" {
		directory = "web"
	}
	compiled := len(state.config.pages.templates.pages) > 0
	signature, ready := development.web_signature(directory, nil, compiled)
	if !ready {
		log.errorf("Could not scan the hot reload directory %s", directory)
		return nil
	}
	state.reload = {
		directory         = directory,
		initial_signature = signature,
		logger            = context.logger,
	}
	if compiled {
		state.reload.before_reload = rebuild_pages
		state.reload.reload_data = state
	}

	return thread.create_and_start_with_poly_data(&state.reload, development.watch_web)
}

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

	if state.config.development && !core.stream_present(response.stream) && development.reload_html_response(response) {
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

builtin_response :: proc(state: ^State, request: ^core.Request) -> (core.Response, bool) {
	if state.config.development {
		response, matched := development.handle(&state.reload, request)
		if matched {
			return response, true
		}
	}

	// Saba owns GET and HEAD under /__saba/. Every other method there belongs to
	// the application handler, for framework modules and build assets alike.
	if request.path == "/__saba" || strings.has_prefix(request.path, "/__saba/") {
		if request.method != "GET" && request.method != "HEAD" {
			return {}, false
		}
		if prepared, builtin := modules_api.builtin_module(request.path); builtin {
			// Record the route for observation exactly as a matched pattern would.
			_ = core.match_route(request, request.method, request.path)
			return assets_api.prepared_representation_response(request, prepared), true
		}
		if strings.has_prefix(request.path, pages_api.BUILD_PATH) { return page_response(state, request, true) }
		return core.not_found(request), true
	}
	if handler_route_reserved(state.config.handler_routes, request) {
		return {}, false
	}
	response, matched := assets_api.serve_assets(request, state.assets, state.config.development)
	if matched {
		return response, true
	}
	if state.config.development {
		response, matched = modules_api.serve_development_modules(request, state.modules, &state.module_pool)
	} else {
		response, matched = modules_api.serve_prepared_modules(request, state.modules, false)
	}
	if matched {
		return response, true
	}

	return page_response(state, request, false)
}

// Production builds live for the server's lifetime. A development rebuild runs
// on the watcher thread and can release the old build after readers finish.
page_response :: proc(state: ^State, request: ^core.Request, asset: bool) -> (core.Response, bool) {
	reloadable := state.config.development && len(state.config.pages.templates.pages) > 0
	if reloadable { sync.rw_mutex_shared_lock(&state.page_lock) }
	defer if reloadable { sync.rw_mutex_shared_unlock(&state.page_lock) }
	response: core.Response
	matched: bool
	if asset {
		response, matched = pages_api.serve_build_asset(request, state.pages)
	} else {
		response, matched = pages_api.serve_prepared_pages(request, state.pages, state.config.development)
	}
	if reloadable && matched {
		// Prepared body storage and captured pattern names borrow this build.
		// Headers are literals, application config, or allocated per request.
		if len(response.body) > 0 {
			owned, err := slice.clone(response.body, request.allocator)
			if err != nil { core.discard_response(&response); return {status = .Internal_Server_Error}, true }
			response.body = owned
		}
		request.route, _ = strings.clone(request.route, request.allocator)
		for &param in request.path_parameters[:request.path_parameter_count] {
			param.name, _ = strings.clone(param.name, request.allocator)
		}
	}
	return response, matched
}

release_page_arena :: proc(arena: ^mem.Dynamic_Arena) {
	if arena != nil {
		mem.dynamic_arena_destroy(arena)
		free(arena, rt.heap_allocator())
	}
}

rebuild_pages :: proc(data: rawptr) -> (published: bool) {
	state := cast(^State)data
	arena := new(mem.Dynamic_Arena, rt.heap_allocator())
	mem.dynamic_arena_init(arena, rt.heap_allocator(), rt.heap_allocator())
	defer if !published { release_page_arena(arena) }
	allocator := mem.dynamic_arena_allocator(arena)
	mounts, ok := modules_api.prepare_module_mounts(state.config.modules, false, allocator, state.config.module_limits)
	if !ok {
		log.error("Page rebuild failed while compiling module mounts; the previous build stays active")
		return false
	}
	next, ready := pages_api.prepare_pages(state.config.pages, true, allocator, mounts)
	if !ready {
		log.error("Page rebuild failed; the previous build stays active")
		return false
	}
	// There is one watcher/writer. Retain the immediately preceding build even
	// without a disk archive. Copy outside the publication lock.
	previous := state.pages.build
	// A rebuild of unchanged content names the same generation and already holds it.
	if state.config.pages.templates.archive_directory == "" && previous.id != next.build.id {
		prefix := fmt.tprintf("%s%s/", pages_api.BUILD_PATH, previous.id)
		for path, rep in previous.files {
			if !strings.has_prefix(path, prefix) { continue }
			owned_path, key_err := strings.clone(path, allocator)
			if key_err != nil {
				log.error("Page rebuild could not retain the previous generation")
				return false
			}
			clone := rep
			for body in ([]^[]u8{&clone.body, &clone.gzip.body, &clone.brotli.body}) {
				if len(body^) == 0 { continue }
				owned, err := slice.clone(body^, allocator)
				if err != nil {
					log.error("Page rebuild could not retain the previous generation")
					return false
				}
				body^ = owned
			}
			next.build.files[owned_path] = clone
		}
	}
	sync.rw_mutex_lock(&state.page_lock)
	old := state.page_arena
	state.page_arena = arena
	state.pages = next
	sync.rw_mutex_unlock(&state.page_lock)
	// Readers of the old build copied what they borrowed under the lock.
	pages_api.release_build(&previous)
	release_page_arena(old)
	return true
}
