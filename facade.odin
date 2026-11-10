package server

import core "core"
import application "application"
import db "shared:kakunou"
import "core:log"
import "core:mem"
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


// The generic composition owns preparation, routing and development lifecycle.
// This facade adds only the historical database-aware handler view.
serve :: proc(config:Server)->bool {
 if config.handler==nil {log.error("Server handler is required");return false}
 snapshot:=config
 return application.serve({
  server={
   resources=config.resources,address=config.address,port=config.port,
   max_connections=config.max_connections,initial_connections=config.initial_connections,
   runtime_allocator=config.runtime_allocator,handler_data=&snapshot,
   request_body_limit=config.request_body_limit,workers=config.workers,
   control=config.control,timeouts=config.timeouts,handler_timeout=config.handler_timeout,
   keep_alive=config.keep_alive,observability=config.observability,
   drain_timeout=config.drain_timeout,
  },
  modules=config.modules,assets=config.assets,asset_limits=config.asset_limits,
  pages=config.pages,development=config.development,
  hot_reload_directory=config.hot_reload_directory,dispatch=legacy_dispatch,
 })
}

@(private)
legacy_dispatch :: proc(data:rawptr,input:^application.Dispatch_Context)->core.Response {
 config:=cast(^Server)data
 view:=connection_view(input.connection,config.database)
 view.reload=input.reload
 response:=config.handler(&view,input.request)
 connection_writeback(&view,input.connection)
 return response
}
