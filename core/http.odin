package saba_core

import http "../../http"
import http1 "../../http/v1"
import "core:encoding/json"
import "core:log"
import "core:mem"
import "core:strings"

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
	headers:              []Header,
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
