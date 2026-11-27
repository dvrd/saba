package saba_core

import "core:mem"
import "core:testing"

// A head of `size` bytes: one padded field, ending in the blank line.
request_head_of_size :: proc(size: int) -> []u8 {
	head := make([]u8, size)
	for &c in head {
		c = 'x'
	}
	copy(head, "GET / HTTP/1.1\r\nHost: example.com\r\nX: ")
	copy(head[size - 4:], "\r\n\r\n")

	return head
}

// The transport's head buffer stops growing at the limit, so a head that
// fills it exactly is the largest one a peer can send and must be served.
@(test)
request_head_of_exactly_the_limit_is_accepted :: proc(t: ^testing.T) {
	headers: [REQUEST_HEADER_COUNT_LIMIT]Header
	exact := request_head_of_size(REQUEST_HEADER_LIMIT)
	defer delete(exact)
	request, status := parse_request(string(exact), headers[:])
	testing.expect_value(t, status, HTTP_Status.None)
	testing.expect_value(t, request.path, "/")

	over := request_head_of_size(REQUEST_HEADER_LIMIT + 1)
	defer delete(over)
	_, status = parse_request(string(over), headers[:])
	testing.expect_value(t, status, HTTP_Status.Request_Header_Fields_Too_Large)
}

// Media type matching ignores case, parameters and the spaces around them.
@(test)
json_media_type_ignores_parameters_and_surrounding_space :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	for sample in ([]struct {
			content_type: string,
			status:       HTTP_Status,
		} {
			{"application/json", .None},
			{"Application/JSON; charset=utf-8", .None},
			{"application/json ; charset=utf-8", .None},
			{"application/json-seq", .Unsupported_Media_Type},
			{"text/plain", .Unsupported_Media_Type},
			{"", .Unsupported_Media_Type},
		}) {
		request := Request {
			allocator          = mem.dynamic_arena_allocator(&arena),
			version            = "HTTP/1.1",
			has_content_length = true,
			headers            = {{"Content-Type", sample.content_type}},
			body               = transmute([]u8)string(`{"n":7}`),
		}
		value: struct {
			n: int,
		}
		testing.expectf(
			t,
			read_json(&request, &value) == sample.status,
			"Content-Type %q: want %v",
			sample.content_type,
			sample.status,
		)
	}
}
