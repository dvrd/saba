package server

import "core:log"
import http "../http"
import http1 "../http/v1"
import "core:strings"
import "core:time"

REQUEST_HEADER_LIMIT :: 8192
REQUEST_HEADER_COUNT_LIMIT :: 128
REQUEST_BODY_LIMIT :: 4096

http_token :: proc(value: string) -> bool {
	return http.header_name_valid(value)
}

// Decode shared wire semantics, then attach Saba-owned routing/body state.
// The transport's smaller head limit remains independent of the codec limit.
parse_request :: proc(raw: string, storage: []Header) -> (Request, HTTP_Status) {
	end := strings.index(raw, HTTP_HEADERS_END)
	if (end >= 0 && end + len(HTTP_HEADERS_END) > REQUEST_HEADER_LIMIT) ||
				(end < 0 && len(raw) >= REQUEST_HEADER_LIMIT) {
		return {}, .Request_Header_Fields_Too_Large
	}
	head, status := http1.request_head_decode(raw, storage[:min(len(storage), REQUEST_HEADER_COUNT_LIMIT)])
	return Request{
		method = head.method,
		path = head.path,
		query = head.query,
		version = head.version,
		headers = head.headers,
		content_length = head.content_length,
		has_content_length = head.has_content_length,
	}, status
}

// A read failure may have no HTTP status when the connection itself failed.
read_request_body :: proc(
	conn: ^Connection,
	request: ^Request,
	buffer: []u8,
) -> (
	HTTP_Status,
	bool,
) {
	if request.content_length > len(buffer) {
		return .Content_Too_Large, false
	}

	request.body = buffer[:request.content_length]
	previous_deadline := conn.read_deadline
	timeouts := conn._timeouts
	if timeouts.body == 0 do timeouts = resolve_timeouts({})
	conn.read_deadline = time.tick_add(time.tick_now(), body_timeout(timeouts, request.content_length))
	defer conn.read_deadline = previous_deadline
	used := 0

	for used < len(request.body) {
		n, err := read_connection(conn, request.body[used:])

		if err == .Timeout {
			log.error("Request body timed out | socket:", conn.socket)
			return .Request_Timeout, false
		}

		if err != nil {
			log.error("Could not read request body:", err, "| socket:", conn.socket)

			return .None, false
		}

		if n == 0 {
			return .Bad_Request, false
		}

		used += n
	}

	if deadline_expired(conn.read_deadline) {
		return .Request_Timeout, false
	}

	return .None, true
}
