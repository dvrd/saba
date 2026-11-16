package server

import core "core"
import dev "development"
import db "shared:kakunou"
import "core:net"
import "core:time"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import application "application"
import assets "assets"
import modules "modules"
import pages "pages"
import jsx "jsx"
import s3 "s3"
import "core:crypto/tls"

// Compatibility view: valid only during a synchronous facade handler/helper.
// Do not retain this pointer. Core handlers receive the real stable connection.
Connection :: struct {
	socket: net.TCP_Socket,
	database: ^db.SQLite_DB,
	read_buffer: []u8,
	read_deadline,write_deadline:time.Tick,
	reload:^Reload_State,
	_transport:^core.Connection,
}

@(private)
connection_view :: proc(transport:^core.Connection,database:^db.SQLite_DB)->Connection {
	return {socket=transport.socket,database=database,read_buffer=transport.read_buffer,
		read_deadline=transport.read_deadline,write_deadline=transport.write_deadline,_transport=transport}
}

@(private)
connection_writeback :: proc(view:^Connection,transport:^core.Connection) {
	transport.socket=view.socket
	transport.read_buffer=view.read_buffer
	transport.read_deadline=view.read_deadline
	transport.write_deadline=view.write_deadline
}

@(private)
connection_transport :: proc(view:^Connection,local:^core.Connection)->^core.Connection {
	transport:=view._transport
	if transport==nil do transport=local
	connection_writeback(view,transport)
	return transport
}

@(private)
connection_refresh :: proc(view:^Connection,transport:^core.Connection) {
	view.socket=transport.socket
	view.read_buffer=transport.read_buffer
	view.read_deadline=transport.read_deadline
	view.write_deadline=transport.write_deadline
}

read_connection :: proc(conn:^Connection,buffer:[]u8)->(int,net.TCP_Recv_Error) {
	local:core.Connection
	io:=connection_transport(conn,&local)
	n,error:=core.read_connection(io,buffer)
	connection_refresh(conn,io)
	return n,error
}

write_connection :: proc(conn:^Connection,buffer:[]u8)->(int,net.TCP_Send_Error) {
	local:core.Connection
	io:=connection_transport(conn,&local)
	n,error:=core.write_connection(io,buffer)
	connection_refresh(conn,io)
	return n,error
}

send_response :: proc(conn:^Connection,response:Response,request_method:string="")->bool {
	prepared:=response
	injected:[]u8
	if conn.reload!=nil && dev.reload_html_response(response) {
		ok:bool
		injected,ok=dev.inject_reload_client(response.body)
		if !ok {send_empty_response(conn,.Internal_Server_Error);return false}
		if injected!=nil do prepared.body=injected
	}
	defer delete(injected)
	local:core.Connection
	io:=connection_transport(conn,&local)
	result:=core.send_response(io,prepared,request_method)
	connection_refresh(conn,io)
	return result
}
send_empty_response :: proc(conn:^Connection,status:HTTP_Status)->bool {return send_response(conn,{status=status})}
read_request_body :: proc(conn:^Connection,request:^Request,buffer:[]u8)->(HTTP_Status,bool) {
	local:core.Connection
	io:=connection_transport(conn,&local)
	status,ok:=core.read_request_body(io,request,buffer)
	connection_refresh(conn,io)
	return status,ok
}
send_bytes :: proc(conn:^Connection,data:[]u8,operation:string)->bool {
	local:core.Connection
	io:=connection_transport(conn,&local)
	ok:=core.send_bytes(io,data,operation)
	connection_refresh(conn,io)
	return ok
}

upgrade_websocket :: proc(conn:^Connection,request:^Request)->bool {
	local:core.Connection
	io:=connection_transport(conn,&local)
	ok:=dev.upgrade_websocket(io,request)
	connection_refresh(conn,io)
	return ok
}

send_websocket_frame :: proc(conn:^Connection,opcode:Opcode,payload:[]u8)->bool {
	local:core.Connection
	io:=connection_transport(conn,&local)
	ok:=dev.send_websocket_frame(io,opcode,payload)
	connection_refresh(conn,io)
	return ok
}

send_websocket_close :: proc(conn:^Connection,code:u16,reason:string)->bool {
	local:core.Connection
	io:=connection_transport(conn,&local)
	ok:=dev.send_websocket_close(io,code,reason)
	connection_refresh(conn,io)
	return ok
}

read_websocket_bytes :: proc(conn:^Connection,buffer:[]u8)->bool {
	local:core.Connection
	io:=connection_transport(conn,&local)
	ok:=dev.read_websocket_bytes(io,buffer)
	connection_refresh(conn,io)
	return ok
}

Server_Control :: core.Server_Control
Server_State :: core.Server_State
Connection_Capacity :: core.Connection_Capacity
Timeout_Config :: core.Timeout_Config
Keep_Alive_Config :: core.Keep_Alive_Config
Observability_Config :: core.Observability_Config
Request_Metrics :: core.Request_Metrics
Request_Event :: core.Request_Event
Request_Outcome :: core.Request_Outcome
Request :: core.Request
Response :: core.Response
Header :: core.Header
Path_Parameter :: core.Path_Parameter
HTTP_Status :: core.HTTP_Status
Upgrade :: core.Upgrade
Upgrade_IO :: core.Upgrade_IO
Connection_Task :: core.Connection_Task
Server_Runtime :: core.Server_Runtime
DEFAULT_MAX_CONNECTIONS :: core.DEFAULT_MAX_CONNECTIONS
DEFAULT_INITIAL_CONNECTIONS :: core.DEFAULT_INITIAL_CONNECTIONS
DEFAULT_WORKERS :: core.DEFAULT_WORKERS
REQUEST_HEADER_LIMIT :: core.REQUEST_HEADER_LIMIT
REQUEST_HEADER_COUNT_LIMIT :: core.REQUEST_HEADER_COUNT_LIMIT
REQUEST_BODY_LIMIT :: core.REQUEST_BODY_LIMIT
REQUEST_HEADER_TIMEOUT :: core.REQUEST_HEADER_TIMEOUT
REQUEST_BODY_TIMEOUT :: core.REQUEST_BODY_TIMEOUT
RESPONSE_SEND_TIMEOUT :: core.RESPONSE_SEND_TIMEOUT
RESPONSE_HEADER_LIMIT :: core.RESPONSE_HEADER_LIMIT
MAX_SERVER_TIMEOUT :: core.MAX_SERVER_TIMEOUT
MAX_EVENT_ROUTE_BYTES :: core.MAX_EVENT_ROUTE_BYTES
DEFAULT_KEEP_ALIVE_REQUESTS :: core.DEFAULT_KEEP_ALIVE_REQUESTS
MAX_KEEP_ALIVE_REQUESTS :: core.MAX_KEEP_ALIVE_REQUESTS
DEFAULT_DRAIN_TIMEOUT :: core.DEFAULT_DRAIN_TIMEOUT
MAX_DRAIN_TIMEOUT :: core.MAX_DRAIN_TIMEOUT
MAX_PATH_PARAMETERS :: core.MAX_PATH_PARAMETERS
CRLF :: core.CRLF
HTTP_HEADERS_END :: core.HTTP_HEADERS_END
HTTP_VERSION :: core.HTTP_VERSION
stop_server :: core.stop_server
server_endpoint :: core.server_endpoint
server_capacity :: core.server_capacity
server_metrics :: core.server_metrics
server_state :: core.server_state
server_ready :: core.server_ready
drain_server :: core.drain_server
timeouts_valid :: core.timeouts_valid
keep_alive_valid :: core.keep_alive_valid
deadline_expired :: core.deadline_expired
wait_ready :: core.wait_ready
parse_request :: core.parse_request
read_json :: core.read_json
header_value :: core.header_value
make_response :: core.make_response
response_headers :: core.response_headers
not_found :: core.not_found
match_route :: core.match_route
path_value :: core.path_value
status_text :: core.status_text

Request_Context :: core.Request_Context
Request_Status :: core.Request_Status
retain_request_context :: core.retain_request_context
release_request_context :: core.release_request_context
request_deadline :: core.request_deadline
request_context_status :: core.request_context_status
request_cancelled :: core.request_cancelled
discard_response :: core.discard_response

Response_Stream :: core.Response_Stream
Stream_IO :: core.Stream_IO
Stream_Step :: core.Stream_Step
stream_submit :: core.stream_submit
stream_wait :: core.stream_wait
streaming_response :: core.streaming_response

Deferred_Response :: core.Deferred_Response
Deferred_IO :: core.Deferred_IO
Deferred_Step :: core.Deferred_Step

Resource_Config :: core.Resource_Config
server_resources :: core.server_resources
retain_server_resources :: core.retain_server_resources
request_resources :: core.request_resources

Stream_Backing :: core.Stream_Backing

stream_submit_backing :: core.stream_submit_backing
DEFAULT_OPERATION_RESOURCES :: core.DEFAULT_OPERATION_RESOURCES
DEFAULT_CONNECTION_RESOURCES :: core.DEFAULT_CONNECTION_RESOURCES
DEFAULT_SERVER_RESOURCES :: core.DEFAULT_SERVER_RESOURCES

request_connection_resources :: core.request_connection_resources

Http2_Config :: core.Http2_Config
Http3_Config :: core.Http3_Config
Http3_Phase_Config :: core.Http3_Phase_Config
server_http3_endpoint :: core.server_http3_endpoint

// Load local defaults before constructing application configuration or workers.
// An absent file is allowed; exported variables, including empty ones, take priority.
load_environment_file :: proc(path := ".env") -> bool {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)
	data, error := os.read_entire_file(path, allocator)
	if reason, general := error.(os.General_Error); general && reason == .Not_Exist do return true
	if error != nil {log.errorf("Could not read environment file %s", path);return false}
	if len(data) > 64 * 1024 {log.errorf("Environment file exceeds 64 KiB: %s", path);return false}
	values, invalid_line := environment_parse(string(data), allocator)
	if invalid_line != 0 {
		log.errorf("Invalid environment assignment at %s:%d", path, invalid_line)
		return false
	}
	// Validate the complete file before changing the process environment.
	for key, value in values {
		_, exported := os.lookup_env(key, allocator)
		if exported do continue
		if os.set_env(key, value) !=
		   nil {log.errorf("Could not apply environment file %s", path);return false}
	}
	return true
}

@(private)
environment_key_ok :: proc(key: string) -> bool {
	if len(key) == 0 do return false
	for c, index in key {
		if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '_' do continue
		if index > 0 && c >= '0' && c <= '9' do continue
		return false
	}
	return true
}

@(private)
environment_value :: proc(raw: string, allocator: mem.Allocator) -> (string, bool) {
	value := strings.builder_make(allocator = allocator)
	line := strings.trim_left_space(raw)
	quote: byte
	kept := 0
	for index := 0; index < len(line); index += 1 {
		c := line[index]
		if c == 0 do return "", false
		if quote == 0 && c == '#' && (index == 0 || line[index - 1] == ' ' || line[index - 1] == '\t') do break
		if quote == 0 && (c == '\'' || c == '"') {quote = c;continue}
		if quote != 0 && c == quote {quote = 0;continue}
		if c == '\\' && quote != '\'' {
			index += 1
			if index >= len(line) do return "", false
			c = line[index]
			if quote == '"' {
				switch c {
				case 'n':
					c = '\n'
				case 'r':
					c = '\r'
				case 't':
					c = '\t'
				case '"', '\\', '$':
				case:
					strings.write_byte(&value, '\\')
				}
			}
		}
		strings.write_byte(&value, c)
		if quote != 0 || (c != ' ' && c != '\t') do kept = len(value.buf)
	}
	if quote != 0 do return "", false
	return strings.to_string(value)[:kept], true
}

@(private)
environment_parse :: proc(source: string, allocator: mem.Allocator) -> (map[string]string, int) {
	values := make(map[string]string, allocator)
	rest := strings.trim_prefix(source, "\xef\xbb\xbf")
	line_number := 0
	for raw in strings.split_lines_iterator(&rest) {
		line_number += 1
		line := strings.trim_space(raw)
		if line == "" || line[0] == '#' do continue
		if len(line) > 6 && line[:6] == "export" && (line[6] == ' ' || line[6] == '\t') do line = strings.trim_left_space(line[6:])
		equal := strings.index_byte(line, '=')
		key := ""
		if equal > 0 do key = strings.trim_space(line[:equal])
		value: string
		valid := environment_key_ok(key)
		if valid do value, valid = environment_value(line[equal + 1:], allocator)
		if !valid do return nil, line_number
		values[key] = value
	}
	return values, 0
}

Handler :: #type proc(conn:^Connection,request:^Request)->Response

TLS_Config :: core.TLS_Config
TLS_Event :: core.TLS_Event
TLS_Event_Kind :: core.TLS_Event_Kind

Server :: struct {
	tls: ^TLS_Config,
	http3: Http3_Config,
 http2: Http2_Config,
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
   tls=config.tls,http3=config.http3,http2=config.http2,resources=config.resources,address=config.address,port=config.port,
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

Asset_Mount :: assets.Asset_Mount
Asset_File :: assets.Asset_File
Asset_Cache :: assets.Asset_Cache
Asset_Limits :: assets.Asset_Limits
Asset_Error :: assets.Asset_Error
Asset_Error_Kind :: assets.Asset_Error_Kind
DEFAULT_ASSET_LIMITS :: assets.DEFAULT_ASSET_LIMITS
prepare_assets_bounded :: assets.prepare_assets_bounded
destroy_assets :: assets.destroy_assets
prepare_assets :: assets.prepare_assets
serve_assets :: assets.serve_assets
serve_file :: assets.serve_file
File_Stream_Config :: assets.File_Stream_Config
serve_file_stream :: assets.serve_file_stream
Module_Mount :: modules.Module_Mount
Module_Cache :: modules.Module_Cache
serve_modules :: modules.serve_modules
prepare_module_mounts :: modules.prepare_module_mounts
serve_prepared_modules :: modules.serve_prepared_modules
JSX_RUNTIME_URL :: modules.JSX_RUNTIME_URL
JSX_RUNTIME :: modules.JSX_RUNTIME
PAGE_ENTRY_URL :: modules.PAGE_ENTRY_URL
PAGE_ENTRY :: modules.PAGE_ENTRY
jsx_runtime_response :: modules.jsx_runtime_response
page_entry_response :: modules.page_entry_response
Page_Mount :: pages.Page_Mount
Page_Cache :: pages.Page_Cache
prepare_pages :: pages.prepare_pages
serve_prepared_pages :: pages.serve_prepared_pages
JSX_Error :: jsx.JSX_Error
transform_jsx :: jsx.transform_jsx
Development :: dev.Development
develop :: dev.develop
Reload_State :: dev.Reload_State
RELOAD_INTERVAL :: dev.RELOAD_INTERVAL
RELOAD_CLIENT :: dev.RELOAD_CLIENT
RELOAD_CLIENT_TAG :: dev.RELOAD_CLIENT_TAG
reload_client_response :: dev.reload_client_response
reload_html_response :: dev.reload_html_response
inject_reload_client :: dev.inject_reload_client
web_signature :: dev.web_signature
watch_web :: dev.watch_web
Opcode :: dev.Opcode
REGULAR_CLOSE :: dev.REGULAR_CLOSE
PROTOCOL_ERROR :: dev.PROTOCOL_ERROR
UNSUPPORTED_DATA :: dev.UNSUPPORTED_DATA
INVALID_PAYLOAD_DATA :: dev.INVALID_PAYLOAD_DATA
valid_close_code :: dev.valid_close_code
S3_Config :: s3.S3_Config
AWS_Credentials :: s3.AWS_Credentials
S3_Result :: s3.S3_Result
load_s3_config :: s3.load_s3_config
s3_config_error :: s3.s3_config_error
aws_credentials :: s3.aws_credentials
s3_put :: s3.s3_put
s3_put_file :: s3.s3_put_file
s3_delete :: s3.s3_delete
s3_download_url :: s3.s3_download_url

TLS_Client_Auth_Config :: tls.Client_Auth_Config
TLS_Client_Auth_Mode :: tls.Client_Auth_Mode
TLS_Peer_Identity :: tls.Peer_Identity

// The facade borrows the normal authenticated connection during its handler.
// Copying this value retains no handshake certificates or request storage.
tls_peer_identity :: proc(connection:^Connection)->TLS_Peer_Identity {
 if connection==nil||connection._transport==nil {return {}}
 return core.tls_peer_identity(connection._transport)
}

TLS_Server_Ticket_Config :: tls.Server_Ticket_Config
TLS_Server_Ticket_Keys :: tls.Server_Ticket_Keys
