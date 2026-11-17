package saba_core

import "core:mem"
import "core:testing"
import "core:time"

@(test)
blocking_chunk_reader_preserves_buffered_next_request_and_deadline :: proc(t: ^testing.T) {
	wire := transmute([]u8)string("2\r\nab\r\n2\r\ncd\r\n0\r\nX-Check: ok\r\n\r\nGET /next HTTP/1.1\r\n")
	deadline := time.tick_add(time.tick_now(), time.Minute)
	connection := Connection {
		read_buffer   = wire,
		read_deadline = deadline,
	}

	request := Request {
		chunked = true,
	}

	buffer: [4]u8
	status, ok := read_request_body(&connection, &request, buffer[:])
	testing.expect(t, ok)
	testing.expect_value(t, status, .None)
	testing.expect_value(t, string(request.body), "abcd")
	testing.expect_value(t, request.content_length, 4)
	testing.expect(t, !request.has_content_length && request.chunked)
	testing.expect_value(t, string(connection.read_buffer), "GET /next HTTP/1.1\r\n")
	testing.expect_value(t, connection.read_deadline, deadline)
}

@(test)
blocking_chunk_reader_rejects_size_and_framing_without_exposing_body :: proc(t: ^testing.T) {
	for sample in ([]struct {
			wire:   string,
			status: HTTP_Status,
		} {
			{"5\r\n", .Content_Too_Large},
			{"2\r\nabXX", .Bad_Request},
			{"0\r\nAuthorization: bad\r\n\r\n", .Bad_Request},
		}) {
		connection := Connection {
			read_buffer = transmute([]u8)sample.wire,
		}
		request := Request {
			chunked = true,
		}
		buffer: [4]u8
		status, ok := read_request_body(&connection, &request, buffer[:])
		testing.expect(t, !ok)
		testing.expect_value(t, status, sample.status)
		testing.expect_value(t, len(request.body), 0)
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
