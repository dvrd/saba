package saba_core

import "core:log"
import http "shared:async/http"
import http1 "shared:async/http/v1"
import "core:strings"
import "core:encoding/json"
import "core:mem"
import budget "shared:async/sync/budget"

// Only the generic read_json uses these; a program that never instantiates
// it would otherwise fail -vet on unused imports.
_ :: json
_ :: log

REQUEST_HEADER_LIMIT :: 8192
REQUEST_HEADER_COUNT_LIMIT :: 128
REQUEST_BODY_LIMIT :: 4096

// Decode shared wire semantics, then attach Saba-owned routing/body state.
// The transport's smaller head limit remains independent of the codec limit.
parse_request :: proc(raw: string, storage: []Header) -> (Request, HTTP_Status) {
	length := http1.request_head_length(raw)
	if length > REQUEST_HEADER_LIMIT || (length < 0 && len(raw) >= REQUEST_HEADER_LIMIT) {
		return {}, .Request_Header_Fields_Too_Large
	}

	head, status := http1.request_head_decode_framed(raw, storage[:min(len(storage), REQUEST_HEADER_COUNT_LIMIT)])

	return Request {
			method = head.method,
			path = head.path,
			query = head.query,
			version = head.version,
			headers = head.headers,
			content_length = head.content_length,
			has_content_length = head.has_content_length,
			chunked = head.chunked,
			_expect_continue = head.expect_continue,
		},
		status
}

CRLF :: http1.CRLF
HTTP_HEADERS_END :: http1.HTTP_HEADERS_END
HTTP_VERSION :: http1.HTTP_VERSION
HTTP_VERSION_1_0 :: http1.HTTP_VERSION_1_0

// Request fields borrow the connection's buffers and remain valid during routing.
Header :: http.Header

MAX_PATH_PARAMETERS :: 8

Path_Parameter :: struct {
	name:  string,
	value: string,
}

Request :: struct {
	early_data:           bool,
	// Borrowed during owner calls; retain scope/create Binding before escape.
	resources:            budget.Scope,
	backing_allocator:    mem.Allocator,
	allocator:            mem.Allocator,
	// Borrowed until handler return; retain explicitly for independently owned work.
	cancellation:         Request_Context,
	// Generated ID is zero when observability is disabled. Route is a matched
	// bounded template; never assign a raw user path or query here.
	request_id:           u64,
	route:                string,
	_observe:             bool,
	// The peer holds its body back until "100 Continue" (HTTP/1.1 only).
	_expect_continue:     bool,
	method:               string,
	path:                 string,
	query:                string,
	version:              string,
	// Negotiated Extended CONNECT protocol; empty for ordinary HTTP requests.
	protocol:             string,
	headers:              []Header,
	trailers:             []Header,
	body:                 []u8,
	content_length:       int,
	has_content_length:   bool,
	// Transfer-Encoding was chunked; content_length is decoded length at dispatch.
	chunked:              bool,
	path_parameters:      [MAX_PATH_PARAMETERS]Path_Parameter,
	path_parameter_count: int,
}

header_value :: proc(request: ^Request, name: string) -> string {
	for header in request.headers {
		if strings.equal_fold(header.name, name) {
			return header.value
		}
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

	// HTTP/2 and HTTP/3 delimit a body by the end of its stream.
	framed := request.version == "HTTP/2" || request.version == "HTTP/3"
	if !framed && !request.has_content_length && !request.chunked {
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

Chunk_Request :: struct {
	decoder: http1.Chunk_Decoder,
	input:   [2048]u8,
}

chunk_error_status :: proc(error: http.Error) -> HTTP_Status {
	#partial switch error.kind {
	case .Body_Oversized, .Header_Oversized, .Header_Limit:
		return .Content_Too_Large
	case:
		return .Bad_Request
	}
}

route_parameter_name :: proc(name: string) -> bool {
	if name == "" {
		return false
	}

	for index in 0 ..< len(name) {
		c := name[index]
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

match_route :: proc(request: ^Request, method, pattern: string) -> bool {
	request.path_parameters = {}
	request.path_parameter_count = 0

	if request.method != method {
		return false
	}
	if !strings.has_prefix(pattern, "/") {
		return false
	}
	if !strings.has_prefix(request.path, "/") {
		return false
	}
	if strings.has_suffix(pattern, "/") != strings.has_suffix(request.path, "/") {
		return false
	}

	parameters: [MAX_PATH_PARAMETERS]Path_Parameter
	count := 0
	pattern_remaining := pattern[1:]
	path_remaining := request.path[1:]

	for {
		pattern_segment, has_pattern := strings.split_iterator(&pattern_remaining, "/")
		path_segment, has_path := strings.split_iterator(&path_remaining, "/")

		if !has_pattern || !has_path {
			if has_pattern != has_path {
				return false
			}

			// Publish captures only after the whole route matches.
			request.path_parameters = parameters
			request.path_parameter_count = count
			if request._observe && len(pattern) <= MAX_EVENT_ROUTE_BYTES {
				request.route = pattern
			}

			return true
		}

		if strings.has_prefix(pattern_segment, ":") {
			name := pattern_segment[1:]
			if !route_parameter_name(name) || path_segment == "" {
				return false
			}
			if count == len(parameters) {
				return false
			}

			for parameter in parameters[:count] {
				if parameter.name == name {
					return false
				}
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
		if parameter.name == name {
			return parameter.value
		}
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
