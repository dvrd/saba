package saba_core

import http "../../http"
import http1 "../../http/v1"
import "core:time"

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
