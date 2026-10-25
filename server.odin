package server

import "core:log"
import "core:mem"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"

REQUEST_HEADER_TIMEOUT :: 5 * time.Second
RESPONSE_SEND_TIMEOUT :: 5 * time.Second

Handler :: #type proc(conn: ^Connection, request: ^Request) -> Response

Connection_Task :: struct {
	socket:  net.TCP_Socket,
	runtime: ^Server_Runtime,
}

handle_connection :: proc(task: Connection_Task) {
	context.logger = task.runtime.logger
	defer {
		sync.atomic_sub(&task.runtime.active_connections, 1)
		sync.wait_group_done(&task.runtime.workers)
	}

	conn := Connection {
		socket   = task.socket,
		database = task.runtime.config.database,
	}
	if task.runtime.config.development do conn.reload = &task.runtime.reload
	defer net.close(conn.socket)
	conn.read_deadline = time.tick_add(time.tick_now(), REQUEST_HEADER_TIMEOUT)

	buffer: [REQUEST_HEADER_LIMIT]u8
	used := 0

	for !strings.contains(string(buffer[:used]), HTTP_HEADERS_END) {
		if used == len(buffer) {
			send_headers_too_large(&conn)
			return
		}

		n, err := read_connection(&conn, buffer[used:])
		if err == .Timeout {
			send_request_timeout(&conn)
			return
		}

		if err != nil {
			log.error(
				"Could not receive request:",
				err,
				"| socket:",
				conn.socket,
				"| bytes received:",
				used,
			)
			return
		}

		if n == 0 {
			if used > 0 {
				log.error(
					"Client disconnected before completing request headers | socket:",
					conn.socket,
					"| bytes received:",
					used,
				)
			}
			return
		}

		used += n
	}

	if deadline_expired(conn.read_deadline) {
		send_request_timeout(&conn)
		return
	}

	conn.read_deadline = {}

	header_storage: [REQUEST_HEADER_COUNT_LIMIT]Header
	request, status := parse_request(string(buffer[:used]), header_storage[:])

	if status != .None {
		send_empty_response(&conn, status)

		return
	}

	body_start := strings.index(string(buffer[:used]), HTTP_HEADERS_END) + len(HTTP_HEADERS_END)
	conn.read_buffer = buffer[body_start:used]
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	request.allocator = mem.dynamic_arena_allocator(&arena)
	previous_temp_allocator := context.temp_allocator
	context.temp_allocator = request.allocator
	defer context.temp_allocator = previous_temp_allocator

	body_storage: [REQUEST_BODY_LIMIT]u8
	body_buffer := body_storage[:]
	limit := REQUEST_BODY_LIMIT
	if task.runtime.config.request_body_limit != nil do limit = task.runtime.config.request_body_limit(&request)
	if limit < 0 || request.content_length > limit {
		send_empty_response(&conn, .Content_Too_Large)
		return
	}
	if request.content_length > len(body_buffer) {
		body_buffer = make([]u8, request.content_length, request.allocator)
	}

	body_status, body_ok := read_request_body(&conn, &request, body_buffer)
	if !body_ok {
		if body_status != .None do send_empty_response(&conn, body_status)

		return
	}

	conn.write_deadline = time.tick_add(time.tick_now(), RESPONSE_SEND_TIMEOUT)
	if conn.reload != nil && handle_reload_upgrade(&conn, &request) do return

	response: Response
	if conn.reload != nil && match_route(&request, "GET", "/__reload/client.js") {
		response = reload_client_response(&request)
	} else if match_route(&request, "GET", JSX_RUNTIME_URL) {
		response = jsx_runtime_response(&request)
	} else if match_route(&request, "GET", PAGE_ENTRY_URL) {
		response = page_entry_response(&request)
	} else if asset_response, matched := serve_assets(
		&request,
		task.runtime.assets,
		task.runtime.config.development,
	); matched {
		response = asset_response
	} else if module_response, matched := serve_prepared_modules(
		&request,
		task.runtime.modules,
		task.runtime.config.development,
	); matched {
		response = module_response
	} else if page_response, matched := serve_prepared_pages(
		&request,
		task.runtime.pages,
		task.runtime.config.development,
	); matched {
		response = page_response
	} else {
		response = task.runtime.config.handler(&conn, &request)
	}

	send_response(&conn, response)
}

send_request_timeout :: proc(conn: ^Connection) {
	log.error("Request headers timed out | socket:", conn.socket)
	send_empty_response(conn, .Request_Timeout)
}

send_headers_too_large :: proc(conn: ^Connection) {
	log.error("Request headers exceed buffer | socket:", conn.socket)
	send_empty_response(conn, .Request_Header_Fields_Too_Large)
}

send_bytes :: proc(conn: ^Connection, data: []u8, operation: string) -> bool {
	sent, err := write_connection(conn, data)

	if err != nil {
		log.error(
			"Failed to send",
			operation,
			"| error:",
			err,
			"| socket:",
			conn.socket,
			"| bytes sent:",
			sent,
			"| expected:",
			len(data),
		)
		return false
	}

	return true
}
