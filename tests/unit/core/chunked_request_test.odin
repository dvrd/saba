package saba_core

import http "shared:async/http"
import "core:mem"
import "core:testing"

@(test)
chunk_decode_errors_map_to_the_request_status :: proc(t: ^testing.T) {
	for sample in ([]struct {
			kind:   http.Error_Kind,
			status: HTTP_Status,
		} {
			{.Body_Oversized, .Content_Too_Large},
			{.Header_Oversized, .Content_Too_Large},
			{.Header_Limit, .Content_Too_Large},
			{.Invalid_Chunk, .Bad_Request},
		}) {
		testing.expect_value(t, chunk_error_status({kind = sample.kind}), sample.status)
	}
}

@(test)
chunked_json_uses_complete_decoded_body :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	request := Request {
		allocator = mem.dynamic_arena_allocator(&arena),
		chunked   = true,
		headers   = {{"Content-Type", "application/json"}},
		body      = transmute([]u8)string(`{"n":7}`),
	}

	value: struct {
		n: int,
	}

	testing.expect_value(t, read_json(&request, &value), .None)
	testing.expect_value(t, value.n, 7)
}

@(test)
json_without_a_length_needs_one_only_on_http1 :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	for version in ([]string{"HTTP/1.1", "HTTP/1.0", "HTTP/2", "HTTP/3"}) {
		request := Request {
			allocator = mem.dynamic_arena_allocator(&arena),
			version   = version,
			headers   = {{"Content-Type", "application/json"}},
			body      = transmute([]u8)string(`{"n":7}`),
		}
		value: struct {
			n: int,
		}
		expected: HTTP_Status = .None if version == "HTTP/2" || version == "HTTP/3" else .Length_Required
		testing.expect_value(t, read_json(&request, &value), expected)
	}
}
