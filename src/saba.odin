package server

import application "application"
import assets "assets"
import core "core"
import "core:crypto/tls"
import "core:log"
import "core:mem"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"
import dev "development"
import jsx "jsx"
import modules "modules"
import pages "pages"
import s3 "s3"
import db "shared:kakunou"

// Compatibility view: valid only during a synchronous facade handler/helper.
// Do not retain this pointer. Core handlers receive the real stable connection.
Connection :: struct {
	socket:                        net.TCP_Socket,
	database:                      ^db.SQLite_DB,
	read_buffer:                   []u8,
	read_deadline, write_deadline: time.Tick,
	reload:                        ^Reload_State,
	_transport:                    ^core.Connection,
}

connection_view :: proc(transport: ^core.Connection, database: ^db.SQLite_DB) -> Connection {
	return {
		socket = transport.socket,
		database = database,
		read_buffer = transport.read_buffer,
		read_deadline = transport.read_deadline,
		write_deadline = transport.write_deadline,
		_transport = transport,
	}
}

connection_writeback :: proc(view: ^Connection, transport: ^core.Connection) {
	transport.socket = view.socket
	transport.read_buffer = view.read_buffer
	transport.read_deadline = view.read_deadline
	transport.write_deadline = view.write_deadline
}

connection_transport :: proc(view: ^Connection, local: ^core.Connection) -> ^core.Connection {
	transport := view._transport
	if transport == nil {
		transport = local
	}
	connection_writeback(view, transport)

	return transport
}

connection_refresh :: proc(view: ^Connection, transport: ^core.Connection) {
	view.socket = transport.socket
	view.read_buffer = transport.read_buffer
	view.read_deadline = transport.read_deadline
	view.write_deadline = transport.write_deadline
}

// Deprecated. read_connection, write_connection and send_response block the
// calling worker in poll() on the raw socket. Workers are shared by every
// connection, so a handler that waits here stalls the server in proportion: do
// not use them on a server with other traffic. Return a Response (optionally
// deferred or streamed) or an upgrade instead. Each call is bounded: without an
// explicit read_deadline/write_deadline the body/response timeout applies. On
// TLS connections they fail with .Invalid_Argument, because there is no raw
// plaintext socket to use.
read_connection :: proc(conn: ^Connection, buffer: []u8) -> (int, net.TCP_Recv_Error) {
	local: core.Connection
	io := connection_transport(conn, &local)
	defer connection_refresh(conn, io)

	return core.read_connection(io, buffer)
}

write_connection :: proc(conn: ^Connection, buffer: []u8) -> (int, net.TCP_Send_Error) {
	local: core.Connection
	io := connection_transport(conn, &local)
	defer connection_refresh(conn, io)

	return core.write_connection(io, buffer)
}

send_response :: proc(conn: ^Connection, response: Response, request_method: string = "") -> bool {
	prepared := response
	injected: []u8

	if conn.reload != nil && dev.reload_html_response(response) {
		ok: bool
		injected, ok = dev.inject_reload_client(response.body)

		if !ok {
			send_response(conn, {status = .Internal_Server_Error})
			return false
		}

		if injected != nil {
			prepared.body = injected
		}
	}

	defer delete(injected)
	local: core.Connection
	io := connection_transport(conn, &local)
	result := core.send_response(io, prepared, request_method)
	connection_refresh(conn, io)

	return result
}

Server_Control :: core.Server_Control
Signal_Config :: core.Signal_Config
Timeout_Config :: core.Timeout_Config
Keep_Alive_Config :: core.Keep_Alive_Config
Observability_Config :: core.Observability_Config
Request_Event :: core.Request_Event
Request :: core.Request
Response :: core.Response
Header :: core.Header
HTTP_Status :: core.HTTP_Status
Upgrade_IO :: core.Upgrade_IO
Connection_Task :: core.Connection_Task
Server_Runtime :: core.Server_Runtime
REQUEST_HEADER_LIMIT :: core.REQUEST_HEADER_LIMIT
REQUEST_BODY_LIMIT :: core.REQUEST_BODY_LIMIT
RESPONSE_HEADER_LIMIT :: core.RESPONSE_HEADER_LIMIT
stop_server :: core.stop_server
server_endpoint :: core.server_endpoint
server_capacity :: core.server_capacity
server_metrics :: core.server_metrics
server_state :: core.server_state
server_ready :: core.server_ready
drain_server :: core.drain_server
deadline_expired :: core.deadline_expired
parse_request :: core.parse_request
read_json :: core.read_json
header_value :: core.header_value
make_response :: core.make_response
response_headers :: core.response_headers
not_found :: core.not_found
match_route :: core.match_route
path_value :: core.path_value
status_text :: core.status_text


Stream_IO :: core.Stream_IO
Stream_Step :: core.Stream_Step
stream_submit :: core.stream_submit
stream_wait :: core.stream_wait

Deferred_IO :: core.Deferred_IO
Deferred_Step :: core.Deferred_Step

Resource_Config :: core.Resource_Config


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
	if reason, general := error.(os.General_Error); general && reason == .Not_Exist {
		return true
	}

	if error != nil {
		log.errorf("Could not read environment file %s", path)
		return false
	}

	if len(data) > 64 * 1024 {
		log.errorf("Environment file exceeds 64 KiB: %s", path)
		return false
	}

	values, invalid_line := environment_parse(string(data), allocator)

	if invalid_line != 0 {
		log.errorf("Invalid environment assignment at %s:%d", path, invalid_line)
		return false
	}

	// Validate the complete file before changing the process environment.
	for key, value in values {
		_, exported := os.lookup_env(key, allocator)
		if exported {
			continue
		}

		if os.set_env(key, value) != nil {
			log.errorf("Could not apply environment file %s", path); return false
		}
	}

	return true
}

is_alpha :: proc(c: rune) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

is_digit :: proc(c: rune) -> bool {
	return c >= '0' && c <= '9'
}

environment_key_ok :: proc(key: string) -> bool {
	if len(key) == 0 {
		return false
	}

	for c, index in key {
		if is_alpha(c) || c == '_' {
			continue
		}

		if index > 0 && is_digit(c) {
			continue
		}

		return false
	}

	return true
}

environment_value :: proc(raw: string, allocator: mem.Allocator) -> (string, bool) {
	value := strings.builder_make(allocator = allocator)
	line := strings.trim_left_space(raw)
	quote: byte
	kept := 0

	for index := 0; index < len(line); index += 1 {
		c := line[index]
		if c == 0 {
			return "", false
		}
		if quote == 0 &&
		   c == '#' &&
		   (index == 0 || line[index - 1] == ' ' || line[index - 1] == '\t') {
			break
		}

		if quote == 0 && (c == '\'' || c == '"') {
			quote = c
			continue
		}

		if quote != 0 && c == quote {
			quote = 0
			continue
		}

		if c == '\\' && quote != '\'' {
			index += 1
			if index >= len(line) {
				return "", false
			}
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
		if quote != 0 || (c != ' ' && c != '\t') {
			kept = len(value.buf)
		}
	}

	if quote != 0 {
		return "", false
	}

	return strings.to_string(value)[:kept], true
}

environment_parse :: proc(source: string, allocator: mem.Allocator) -> (map[string]string, int) {
	values := make(map[string]string, allocator)
	rest := strings.trim_prefix(source, "\xef\xbb\xbf")
	line_number := 0

	for raw in strings.split_lines_iterator(&rest) {
		line_number += 1
		line := strings.trim_space(raw)
		if line == "" || line[0] == '#' do continue

		if len(line) > 6 && line[:6] == "export" && (line[6] == ' ' || line[6] == '\t') {
			line = strings.trim_left_space(line[6:])
		}

		equal := strings.index_byte(line, '=')
		key := ""
		if equal > 0 {
			key = strings.trim_space(line[:equal])
		}

		if !environment_key_ok(key) {
			return nil, line_number
		}

		value, valid := environment_value(line[equal + 1:], allocator)
		if !valid {
			return nil, line_number
		}

		values[key] = value
	}

	return values, 0
}

Handler :: #type proc(conn: ^Connection, request: ^Request) -> Response

TLS_Config :: core.TLS_Config

Server :: struct {
	tls:                                  ^TLS_Config,
	http3:                                Http3_Config,
	http2:                                Http2_Config,
	resources:                            Resource_Config,
	address:                              string,
	port:                                 int,
	max_connections, initial_connections: int,
	runtime_allocator:                    mem.Allocator,
	database:                             ^db.SQLite_DB,
	handler:                              Handler,
	request_body_limit:                   proc(request: ^Request) -> int,
	modules:                              []Module_Mount,
	assets:                               []Asset_Mount,
	asset_limits:                         Asset_Limits,
	// Size limits for module mounts; zero selects the module defaults.
	module_limits:                        Asset_Limits,
	pages:                                Page_Mount,
	handler_routes:                       []string,
	development:                          bool,
	hot_reload_directory:                 string,
	// Zero selects one worker per logical core, at least four. Handlers run on
	// these workers and are never preempted: a handler that blocks (a slow
	// query, a sleep, the deprecated blocking helpers above) holds its worker,
	// and when all are held the server stops accepting, reading and timing out
	// connections. Return a deferred response for work that waits.
	workers:                              int,
	// SIGTERM and SIGINT drain the server gracefully by default: the listener
	// closes, admitted requests finish (bounded by drain_timeout, five seconds
	// when zero) and serve returns; a second signal terminates the process.
	// The handlers are installed only while serve runs and only for signals
	// still at their default disposition. Set signals.disabled to keep signal
	// handling entirely in the application; it must then forward the signal to
	// a thread before calling drain_server, which is not async-signal-safe.
	signals:                              Signal_Config,
	control:                              ^Server_Control,
	timeouts:                             Timeout_Config,
	handler_timeout:                      time.Duration,
	keep_alive:                           Keep_Alive_Config,
	observability:                        Observability_Config,
	drain_timeout:                        time.Duration,
}

// The generic composition owns preparation, routing and development lifecycle.
// This facade adds only the historical database-aware handler view.
serve :: proc(config: Server) -> bool {
	if config.handler == nil {
		log.error("Server handler is required")
		return false
	}

	snapshot := config

	return application.serve(
		{
			server = {
				tls = config.tls,
				http3 = config.http3,
				http2 = config.http2,
				resources = config.resources,
				address = config.address,
				port = config.port,
				max_connections = config.max_connections,
				initial_connections = config.initial_connections,
				runtime_allocator = config.runtime_allocator,
				handler_data = &snapshot,
				request_body_limit = config.request_body_limit,
				workers = config.workers,
				signals = config.signals,
				control = config.control,
				timeouts = config.timeouts,
				handler_timeout = config.handler_timeout,
				keep_alive = config.keep_alive,
				observability = config.observability,
				drain_timeout = config.drain_timeout,
			},
			modules = config.modules,
			assets = config.assets,
			asset_limits = config.asset_limits,
			module_limits = config.module_limits,
			pages = config.pages,
			handler_routes = config.handler_routes,
			development = config.development,
			hot_reload_directory = config.hot_reload_directory,
			dispatch = legacy_dispatch,
		},
	)
}

legacy_dispatch :: proc(data: rawptr, input: ^application.Dispatch_Context) -> core.Response {
	config := cast(^Server)data
	view := connection_view(input.connection, config.database)
	view.reload = input.reload
	response := config.handler(&view, input.request)
	connection_writeback(&view, input.connection)

	return response
}

Asset_Mount :: assets.Asset_Mount
Asset_Limits :: assets.Asset_Limits
prepare_assets :: assets.prepare_assets
serve_assets :: assets.serve_assets
serve_file :: assets.serve_file
File_Stream_Config :: assets.File_Stream_Config
serve_file_stream :: assets.serve_file_stream
Module_Mount :: modules.Module_Mount
serve_modules :: modules.serve_modules
prepare_module_mounts :: modules.prepare_module_mounts
serve_prepared_modules :: modules.serve_prepared_modules
JSX_RUNTIME_URL :: modules.JSX_RUNTIME_URL
JSX_RUNTIME :: modules.JSX_RUNTIME
PAGE_ENTRY_URL :: modules.PAGE_ENTRY_URL
PAGE_ENTRY :: modules.PAGE_ENTRY
SLIDING_WINDOW_URL :: modules.SLIDING_WINDOW_URL
SLIDING_WINDOW :: modules.SLIDING_WINDOW
SLOT_WINDOW_URL :: modules.SLOT_WINDOW_URL
SLOT_WINDOW :: modules.SLOT_WINDOW
READS_URL :: modules.READS_URL
READS :: modules.READS
MUTATIONS_URL :: modules.MUTATIONS_URL
EDITOR_URL :: modules.EDITOR_URL
Page_Mount :: pages.Page_Mount
Template_Build :: pages.Template_Build
Compiled_Page :: pages.Compiled_Page
Template_Variant :: pages.Template_Variant
prepare_pages :: pages.prepare_pages
serve_prepared_pages :: pages.serve_prepared_pages
transform_jsx :: jsx.transform_jsx
Development :: dev.Development
develop :: dev.develop
Reload_State :: dev.Reload_State
RELOAD_CLIENT :: dev.RELOAD_CLIENT
RELOAD_CLIENT_TAG :: dev.RELOAD_CLIENT_TAG
reload_html_response :: dev.reload_html_response
inject_reload_client :: dev.inject_reload_client
Opcode :: dev.Opcode
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

TLS_Peer_Identity :: tls.Peer_Identity

// The facade borrows the normal authenticated connection during its handler.
// Copying this value retains no handshake certificates or request storage.
tls_peer_identity :: proc(connection: ^Connection) -> TLS_Peer_Identity {
	if connection == nil || connection._transport == nil {
		return {}
	}

	return core.tls_peer_identity(connection._transport)
}
