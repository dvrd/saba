package saba_core

import http "../../http"
import http1 "../../http/v1"
import "core:log"
import "core:time"

RESPONSE_HEADER_LIMIT :: 8192

// Header values and body must survive until the server finishes sending.
// Use request.allocator for dynamic response data.
Response :: struct {
	status:  HTTP_Status,
	headers: []Header,
	body:    []u8,
	// Force close even when bounded keep-alive is enabled.
	close_connection: bool,
	// Owned optional HTTP/1 upgrade continuation, transferred on handler return.
	upgrade: Upgrade,
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

response_headers :: proc(response: Response, buffer: []u8, keep_alive: bool = false) -> (data: []u8, ok: bool) {
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

	profile:http1.Response_Profile=.Close
	if status==.Switching_Protocols {profile=.Upgrade} else if keep_alive {profile=.Keep_Alive}
	written,error:=http1.response_head_encode_profile(buffer,{status=int(status),headers=response.headers,content_length=i64(len(response.body))},profile,max_bytes=RESPONSE_HEADER_LIMIT)
	if error.kind!=.None {
		log.error("Invalid HTTP response headers:",error.kind)
		return
	}
	return buffer[:written],true
}

send_response :: proc(conn: ^Connection, response: Response, request_method: string = "") -> bool {
	prepared := response
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

// Disposes transferred continuations when a late response cannot be queued.
// Body/header borrows remain owned by their request arena.
discard_response :: proc(response:^Response) {
    if response==nil do return
    old:=response^;response^={}
    if old.upgrade.drop!=nil do old.upgrade.drop(old.upgrade.data)
}
