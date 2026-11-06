package server

import http "../http"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:time"

RESPONSE_HEADER_LIMIT :: 8192

// Header values and body must survive until the server finishes sending.
// Use request.allocator for dynamic response data.
Response :: struct {
	status:  HTTP_Status,
	headers: []Header,
	body:    []u8,
}

// Copies the header list out of the caller's stack into the request arena.
// Header strings and body remain borrowed: use literals or request allocations.
make_response :: proc(
	request: ^Request,
	status: HTTP_Status = .OK,
	headers: []Header = nil,
	body: []u8 = nil,
) -> Response {
	if len(headers) == 0 do return Response{status = status, body = body}

	stored_headers, err := make([]Header, len(headers), request.allocator)
	if err != nil {
		log.error("Could not allocate response headers:", err)

		return Response{status = .Internal_Server_Error}
	}

	copy(stored_headers, headers)

	return Response{status = status, headers = stored_headers, body = body}
}

http_field_value :: proc(value: string) -> bool {
	return http.header_value_valid(value)
}

response_headers :: proc(response: Response, buffer: []u8) -> (data: []u8, ok: bool) {
	status := response.status
	if status == .None do status = .OK

	text := status_text(status)

	if text == "" {
		log.error("Invalid HTTP response status:", i32(status))

		return
	}

	body_forbidden := !http.response_body_allowed(int(status))

	if body_forbidden && len(response.body) != 0 {
		log.error("HTTP response status does not allow a body:", status)

		return
	}

	for header in response.headers {
		if !http_token(header.name) || !http_field_value(header.value) {
			log.error("Invalid HTTP response header")

			return
		}

		if strings.equal_fold(header.name, "Content-Length") ||
		   strings.equal_fold(header.name, "Connection") ||
		   strings.equal_fold(header.name, "Transfer-Encoding") {
			log.error("HTTP response framing is managed by send_response:", header.name)

			return
		}
	}

	length_buffer: [32]u8
	length := fmt.bprintf(length_buffer[:], "%d", len(response.body))
	generated: [2]Header
	count := 0

	if !body_forbidden {
		generated[count] = {"Content-Length", length}
		count += 1
	}

	generated[count] = {"Connection", "Upgrade" if status == .Switching_Protocols else "close"}
	count += 1

	groups := [2][]Header{response.headers, generated[:count]}
	size := len(HTTP_VERSION) + 1 + len(text) + len(CRLF) * 2

	for headers in groups {
		for header in headers {
			size += len(header.name) + len(header.value) + 2 + len(CRLF)
		}
	}

	if size > RESPONSE_HEADER_LIMIT || size > len(buffer) {
		log.error("HTTP response headers exceed buffer limit")

		return
	}

	data = buffer[:size]
	used := copy(data, HTTP_VERSION + " ")
	used += copy(data[used:], text)
	used += copy(data[used:], CRLF)

	for headers in groups {
		for header in headers {
			used += copy(data[used:], header.name)
			used += copy(data[used:], ": ")
			used += copy(data[used:], header.value)
			used += copy(data[used:], CRLF)
		}
	}

	copy(data[used:], CRLF)
	ok = true

	return
}

send_response :: proc(conn: ^Connection, response: Response, request_method: string = "") -> bool {
	prepared := response
	injected: []u8

	defer {
		if free_err := delete(injected); free_err != nil {
			log.error("Could not free development HTML:", free_err)
		}
	}

	if conn.reload != nil && reload_html_response(response) {
		ok: bool
		injected, ok = inject_reload_client(response.body)

		if !ok {
			send_empty_response(conn, .Internal_Server_Error)

			return false
		}

		if injected != nil do prepared.body = injected
	}

	buffer: [RESPONSE_HEADER_LIMIT]u8
	headers, ok := response_headers(prepared, buffer[:])
	if !ok do return false

	duration := conn._timeouts.response
	if duration == 0 do duration = RESPONSE_SEND_TIMEOUT
	conn.write_deadline = time.tick_add(time.tick_now(), duration)

	if !send_bytes(conn, headers, "HTTP response headers") do return false

	if request_method == "HEAD" do return true
	return send_bytes(conn, prepared.body, "HTTP response body")
}

send_empty_response :: proc(conn: ^Connection, status: HTTP_Status) -> bool {
	return send_response(conn, Response{status = status})
}
