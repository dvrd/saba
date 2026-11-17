package saba_core

import "core:log"
import http "../../http"
import http1 "../../http/v1"
import "core:strings"
import "core:time"
import "core:encoding/json"
import "core:mem"
import budget "core:sync/budget"

REQUEST_HEADER_LIMIT :: 8192
REQUEST_HEADER_COUNT_LIMIT :: 128
REQUEST_BODY_LIMIT :: 4096

// Decode shared wire semantics, then attach Saba-owned routing/body state.
// The transport's smaller head limit remains independent of the codec limit.
parse_request :: proc(raw: string, storage: []Header) -> (Request, HTTP_Status) {
	end := strings.index(raw, HTTP_HEADERS_END)
	if (end >= 0 && end + len(HTTP_HEADERS_END) > REQUEST_HEADER_LIMIT) ||
				(end < 0 && len(raw) >= REQUEST_HEADER_LIMIT) {
		return {}, .Request_Header_Fields_Too_Large
	}
	head, status := http1.request_head_decode_framed(raw, storage[:min(len(storage), REQUEST_HEADER_COUNT_LIMIT)])
	return Request{
		method = head.method,
		path = head.path,
		query = head.query,
		version = head.version,
		headers = head.headers,
		content_length = head.content_length,
		has_content_length = head.has_content_length,
		chunked = head.chunked,
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
	if request.chunked do return read_chunked_body(conn,request,buffer)
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

CRLF :: http1.CRLF
HTTP_HEADERS_END :: http1.HTTP_HEADERS_END
HTTP_VERSION :: http1.HTTP_VERSION

// Request fields borrow the connection's buffers and remain valid during routing.
Header :: http.Header

MAX_PATH_PARAMETERS :: 8

Path_Parameter :: struct {
	name:  string,
	value: string,
}

Request :: struct {
 early_data:bool,
	// Borrowed during owner calls; retain scope/create Binding before escape.
	resources: budget.Scope,
	backing_allocator: mem.Allocator,
	allocator:            mem.Allocator,
	// Borrowed until handler return; retain explicitly for independently owned work.
	cancellation: Request_Context,
	// Generated ID is zero when observability is disabled. Route is a matched
	// bounded template; never assign a raw user path or query here.
	request_id:           u64,
	route:                string,
	_observe:             bool,
	method:               string,
	path:                 string,
	query:                string,
	version:              string,
	// Negotiated Extended CONNECT protocol; empty for ordinary HTTP requests.
	protocol: string,
	headers:              []Header,
 trailers:[]Header,
	body:                 []u8,
	content_length:       int,
	has_content_length:   bool,
	// Transfer-Encoding was chunked; content_length is decoded length at dispatch.
	chunked: bool,
	path_parameters:      [MAX_PATH_PARAMETERS]Path_Parameter,
	path_parameter_count: int,
}

header_value :: proc(request: ^Request, name: string) -> string {
	for header in request.headers {
		if strings.equal_fold(header.name, name) do return header.value
	}

	return ""
}

// Returns .None on success. The handler chooses the HTTP response on failure.
read_json :: proc(request: ^Request, input: ^$T) -> HTTP_Status {
	content_type := header_value(request, "Content-Type")

	if separator := strings.index(content_type, ";"); separator >= 0 {
		content_type = content_type[:separator]
	}

	if !strings.equal_fold(strings.trim_space(content_type), "application/json") {
		return .Unsupported_Media_Type
	}

	if !request.has_content_length && !request.chunked {
		return .Length_Required
	}

	err := json.unmarshal(request.body, input, allocator = request.allocator)

	if err == .Out_Of_Memory {
		log.error("Could not allocate JSON request data:", err)

		return .Internal_Server_Error
	}

	if err != nil {
		return .Bad_Request
	}

	return .None
}

@(private)
Chunk_Request :: struct {
	decoder: http1.Chunk_Decoder,
	input:   [2048]u8,
}

@(private)
chunk_error_status :: proc(error: http.Error) -> HTTP_Status {
	#partial switch error.kind {
	case .Body_Oversized, .Header_Oversized, .Header_Limit:
		return .Content_Too_Large
	case:
		return .Bad_Request
	}
}

@(private)
read_chunked_body :: proc(
	conn: ^Connection,
	request: ^Request,
	buffer: []u8,
) -> (
	HTTP_Status,
	bool,
) {
	decoder: http1.Chunk_Decoder
	if http1.chunk_decoder_init(&decoder, u64(len(buffer))).kind != .None do return .Content_Too_Large, false
	previous := conn.read_deadline
	timeouts := conn._timeouts
	if timeouts.body == 0 do timeouts = resolve_timeouts({})
	conn.read_deadline = time.tick_add(time.tick_now(), body_timeout(timeouts, 0))
	defer conn.read_deadline = previous
	scratch: [2048]u8
	used := 0
	for {
		if deadline_expired(conn.read_deadline) do return .Request_Timeout, false
		input := conn.read_buffer
		buffered := len(input) > 0
		if !buffered {
			want := http1.chunk_decoder_read_limit(&decoder, len(scratch))
			n, error := read_connection(conn, scratch[:want])
			if error == .Timeout do return .Request_Timeout, false
			if error != nil do return .None, false
			if n == 0 do return .Bad_Request, false
			input = scratch[:n]
		}
		consumed, written, done, error := http1.chunk_decoder_feed(&decoder, input, buffer[used:])
		if buffered do conn.read_buffer = conn.read_buffer[consumed:]
		used += written
		if error.kind != .None do return chunk_error_status(error), false
		if done {
			if deadline_expired(conn.read_deadline) do return .Request_Timeout, false
			request.body = buffer[:used]; request.content_length = used
			return .None, true
		}
	}
}

route_parameter_name :: proc(name: string) -> bool {
	if name == "" do return false

	for index in 0 ..< len(name) {
		c := name[index]
		if is_alpha(c) || c == '_' do continue
		if index > 0 && is_digit(c) do continue

		return false
	}

	return true
}

match_route :: proc(request: ^Request, method, pattern: string) -> bool {
	request.path_parameters = {}
	request.path_parameter_count = 0

	if request.method != method do return false
	if !strings.has_prefix(pattern, "/") do return false
	if !strings.has_prefix(request.path, "/") do return false
	if strings.has_suffix(pattern, "/") != strings.has_suffix(request.path, "/") do return false

	parameters: [MAX_PATH_PARAMETERS]Path_Parameter
	count := 0
	pattern_remaining := pattern[1:]
	path_remaining := request.path[1:]

	for {
		pattern_segment, has_pattern := strings.split_iterator(&pattern_remaining, "/")
		path_segment, has_path := strings.split_iterator(&path_remaining, "/")

		if !has_pattern || !has_path {
			if has_pattern != has_path do return false

			// Publish captures only after the whole route matches.
			request.path_parameters = parameters
			request.path_parameter_count = count
			if request._observe && len(pattern) <= MAX_EVENT_ROUTE_BYTES do request.route = pattern

			return true
		}

		if strings.has_prefix(pattern_segment, ":") {
			name := pattern_segment[1:]
			if !route_parameter_name(name) || path_segment == "" do return false
			if count == len(parameters) do return false

			for parameter in parameters[:count] {
				if parameter.name == name do return false
			}

			parameters[count] = {name, path_segment}
			count += 1
		} else if pattern_segment != path_segment {
			return false
		}
	}
}

path_value :: proc(request: ^Request, name: string) -> string {
	for parameter in request.path_parameters[:request.path_parameter_count] {
		if parameter.name == name do return parameter.value
	}

	return ""
}

not_found :: proc(request: ^Request) -> Response {
	return make_response(
		request,
		.Not_Found,
		[]Header{{"Content-Type", "text/html; charset=utf-8"}},
		transmute([]u8)string("Not Found"),
	)
}

// Keep existing Saba names while sharing the protocol status vocabulary.
HTTP_Status :: http.HTTP_Status
status_text :: http.status_text
