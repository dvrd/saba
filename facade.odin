package server

import core "core"
import assets_api "assets"
import modules_api "modules"
import pages_api "pages"
import dev "development"
import db "shared:kakunou"
import "core:log"
import "core:mem"
import "core:sync"
import "core:thread"
import "core:time"

Handler :: #type proc(conn:^Connection,request:^Request)->Response

Server :: struct {
	resources: Resource_Config,
	address: string,
	port: int,
	max_connections, initial_connections: int,
	runtime_allocator: mem.Allocator,
	database: ^db.SQLite_DB,
	handler: Handler,
	request_body_limit: proc(request:^Request)->int,
	modules: []Module_Mount,
	assets: []Asset_Mount,
	asset_limits: Asset_Limits,
	pages: Page_Mount,
	development: bool,
	hot_reload_directory: string,
	workers: int,
	control: ^Server_Control,
	timeouts: Timeout_Config,
	handler_timeout:time.Duration,
	keep_alive: Keep_Alive_Config,
	observability: Observability_Config,
	drain_timeout: time.Duration,
}

@(private)
Application :: struct {
	config: Server,
	modules: []Module_Cache,
	assets: []Asset_Cache,
	pages: Page_Cache,
	reload: Reload_State,
}

// Optional adapters are prepared by the facade and owned until core.serve
// returns. Applications importing core directly prepare only their chosen ones.
serve :: proc(config:Server)->bool {
	if config.handler==nil {log.error("Server handler is required");return false}
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator:=mem.dynamic_arena_allocator(&arena)
	application:=Application{config=config}
	valid:bool
	application.modules,valid=modules_api.prepare_module_mounts(config.modules,config.development,allocator)
	if !valid do return false
	application.pages,valid=pages_api.prepare_pages(config.pages,config.development,allocator)
	if !valid do return false
	asset_error: assets_api.Asset_Error
	application.assets,asset_error=assets_api.prepare_assets_bounded(config.assets,config.asset_limits,allocator)
	if asset_error.kind!=.None {log.errorf("Asset preload failed: %v mount=%d limit=%d observed=%d",asset_error.kind,asset_error.mount_index,asset_error.limit,asset_error.observed);return false}
	defer assets_api.destroy_assets(&application.assets,allocator)
	watcher:^thread.Thread
	defer {
		sync.atomic_store(&application.reload.stopped,true)
		if watcher!=nil {thread.join(watcher);thread.destroy(watcher)}
	}
	if config.development {
		directory:=config.hot_reload_directory
		if directory=="" do directory="web"
		signature,ready:=dev.web_signature(directory)
		if !ready do return false
		application.reload={directory=directory,initial_signature=signature,logger=context.logger}
		watcher=thread.create_and_start_with_poly_data(&application.reload,dev.watch_web)
		if watcher==nil do return false
	}
	return core.serve({resources=config.resources,
		address=config.address,port=config.port,max_connections=config.max_connections,
		initial_connections=config.initial_connections,runtime_allocator=config.runtime_allocator,
		handler=facade_dispatch,handler_data=&application,request_body_limit=config.request_body_limit,
		workers=config.workers,control=config.control,timeouts=config.timeouts,handler_timeout=config.handler_timeout,keep_alive=config.keep_alive,
		observability=config.observability,drain_timeout=config.drain_timeout})
}

@(private)
facade_dispatch :: proc(data:rawptr,transport:^core.Connection,request:^Request)->Response {
	application:=cast(^Application)data
	response:Response
	matched:=false
	if application.config.development {
		response,matched=dev.handle(&application.reload,request)
	}
	if !matched && (match_route(request,"GET",modules_api.JSX_RUNTIME_URL) || match_route(request,"HEAD",modules_api.JSX_RUNTIME_URL)) {
		response,matched=modules_api.jsx_runtime_response(request),true
	}
	if !matched && (match_route(request,"GET",modules_api.PAGE_ENTRY_URL) || match_route(request,"HEAD",modules_api.PAGE_ENTRY_URL)) {
		response,matched=modules_api.page_entry_response(request),true
	}
	if !matched {response,matched=assets_api.serve_assets(request,application.assets,application.config.development)}
	if !matched {response,matched=modules_api.serve_prepared_modules(request,application.modules,application.config.development)}
	if !matched {response,matched=pages_api.serve_prepared_pages(request,application.pages,application.config.development)}
	if !matched {
		// A stack view avoids allocating request-arena/heap storage merely to
		// call an existing synchronous handler. It must not escape that call.
		view:=connection_view(transport,application.config.database)
		if application.config.development do view.reload=&application.reload
		response=application.config.handler(&view,request)
		connection_writeback(&view,transport)
	}
	if application.config.development && !core.streaming_response(response) && dev.reload_html_response(response) {
		body,ok:=dev.inject_reload_client(response.body,request.allocator)
		if !ok {
			response.status=.Internal_Server_Error
			response.headers=nil
			response.body=nil
			return response // Preserve any transferred upgrade for core rejection/drop.
		}
		if body!=nil do response.body=body
	}
	return response
}
