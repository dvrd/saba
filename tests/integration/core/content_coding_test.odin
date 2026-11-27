package saba_core

import "shared:async/compress/brotli"
import incremental "shared:async/compress/step"
import "core:compress/deflate"
import "core:bytes"
import "core:fmt"
import "core:mem"
import owned "shared:async/owned"
import "core:net"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import async "shared:async"

coding_repeat :: proc(count: int, allocator: mem.Allocator) -> []u8 {
	text := "Saba keeps identity available and gzips textual responses. "
	data, err := make([]u8, count, allocator)
	if err != nil {
		return nil
	}
	for index in 0 ..< count {
		data[index] = text[index % len(text)]
	}

	return data
}

coding_field :: proc(headers: []Header, name: string) -> (string, bool) {
	for header in headers {
		if strings.equal_fold(header.name, name) {
			return header.value, true
		}
	}

	return "", false
}

coding_decode :: proc(t: ^testing.T, encoded, expected: []u8) {
	output: [dynamic]u8
	defer delete(output)
	error := deflate.decompress_gzip(&output, encoded, options = {max_output_size = len(expected)})
	testing.expect_value(t, error, nil)
	testing.expect(t, string(output[:]) == string(expected))
}

@(test)
gzip_round_trip_and_short_writes_match_limits :: proc(t: ^testing.T) {
	testing.expect(t, deflate.compress_gzip_bound(GZIP_MAX_INPUT) <= GZIP_MAX_OUTPUT)
	plain := coding_repeat(4096, context.allocator)
	defer delete(plain)
	encoder, alloc_error := new(incremental.Deflate_Encoder)
	testing.expect(t, alloc_error == nil && encoder != nil)
	defer free(encoder)
	testing.expect_value(t, incremental.deflate_encoder_init(encoder, .Gzip, GZIP_DYNAMIC_LEVEL, GZIP_MAX_OUTPUT), nil)
	defer incremental.deflate_encoder_destroy(encoder)
	encoded, encode_error := make([]u8, deflate.compress_gzip_bound(len(plain)))
	testing.expect(t, encode_error == nil)
	defer delete(encoded)
	offset, written := 0, 0

	for offset < len(plain) {
		step := min(5, len(plain) - offset)
		count := incremental.deflate_encoder_write(encoder, plain[offset:offset + step])
		testing.expect(t, count > 0 && count <= step)
		offset += count
		written += incremental.deflate_encoder_pull(encoder, encoded[written:])
	}

	for !incremental.deflate_encoder_finish(encoder) {
		count := incremental.deflate_encoder_pull(encoder, encoded[written:])
		testing.expect(t, count > 0)
		written += count
	}

	for incremental.deflate_encoder_pending(encoder) > 0 {
		written += incremental.deflate_encoder_pull(encoder, encoded[written:])
	}

	testing.expect(t, encoder.finished && !encoder.overflow && written > 0 && written < len(plain))
	testing.expect(t, written <= GZIP_MAX_OUTPUT)
	coding_decode(t, encoded[:written], plain)

	// The buffered path and the stream agree: same level, same bytes.
	whole := gzip_compress(plain, context.allocator)
	defer delete(whole)
	testing.expect(t, bytes.equal(whole, encoded[:written]))
}

@(test)
content_coding_negotiates_encodings_thresholds_and_sensitive_bodies :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)
	text := [2]Header{{"Content-Type", "text/plain; charset=utf-8"}, {"Cache-Control", "no-cache"}}
	eligible := Response {
		status  = .OK,
		headers = text[:],
	}

	testing.expect(t, !coding_eligible(eligible, GZIP_MIN_BYTES - 1))
	testing.expect(t, !coding_eligible(eligible, GZIP_MAX_INPUT + 1))
	testing.expect(t, coding_eligible(eligible, GZIP_MIN_BYTES))
	blocked := Response {
		status  = .OK,
		headers = {{"Content-Type", "text/plain"}, {"Cache-Control", "private, max-age=60"}},
	}

	testing.expect(t, !coding_eligible(blocked, 2048))
	stored := Response {
		status  = .OK,
		headers = {{"Content-Type", "text/plain"}, {"Cache-Control", "no-store"}},
	}

	testing.expect(t, !coding_eligible(stored, 2048))
	ranged := Response {
		status  = .Partial_Content,
		headers = text[:],
	}

	testing.expect(t, !coding_eligible(ranged, 2048))
	unchanged := Response {
		status  = .Not_Modified,
		headers = {{"Cache-Control", "no-cache"}, {"ETag", "\"abc\""}},
	}

	testing.expect(t, !coding_eligible(unchanged, 0))
	typed := Response {
		status  = .OK,
		headers = {{"Content-Type", "application/problem+json"}},
	}

	testing.expect(t, coding_eligible(typed, 2048))
	image := Response {
		status  = .OK,
		headers = {{"Content-Type", "image/png"}},
	}

	testing.expect(t, !coding_eligible(image, 2048))

	cases := []struct {
		name:       string,
		accept:     string,
		size:       int,
		headers:    []Header,
		gzip, vary: bool,
	} {
		{"gzip", "gzip", 2048, text[:], true, true},
		{"x-gzip", "x-gzip", 2048, text[:], true, true},
		{"star", "*", 2048, text[:], true, true},
		{"explicit", "*;q=0, gzip;q=1", 2048, text[:], true, true},
		{"tie", "gzip;q=0.5, identity;q=0.5", 2048, text[:], true, true},
		{"br-only", "deflate, compress", 2048, text[:], false, true},
		{"refused", "gzip;q=0, *", 2048, text[:], true, true},
		{"identity-higher", "identity;q=1, gzip;q=0.1", 2048, text[:], false, true},
		{"identity-zero", "identity;q=0", 2048, text[:], false, true},
		{"empty", "", 2048, text[:], false, true},
		{"malformed", "gzip;q=2", 2048, text[:], false, false},
		{"small", "gzip", 1023, text[:], false, false},
		{"missing-type", "gzip", 2048, {{"Cache-Control", "no-cache"}}, false, false},
		{"encoded", "gzip", 2048, {{"Content-Type", "text/plain"}, {"Content-Encoding", "deflate"}}, false, false},
		{"no-store", "gzip", 2048, {{"Content-Type", "text/plain"}, {"Cache-Control", "no-store"}}, false, false},
		{"range", "gzip", 2048, {{"Content-Type", "text/plain"}, {"Content-Range", "bytes 0-1/2"}}, false, false},
	}

	for item in cases {
		plain := coding_repeat(max(item.size, 1), allocator)
		request := Request {
			allocator = allocator,
			method    = "GET",
			headers   = {{"Accept-Encoding", item.accept}},
		}

		response := Response {
			status  = .OK,
			headers = item.headers,
			body    = plain[:item.size],
		}

		content_coding_prepare(&request, &response)
		coding, encoded := coding_field(response.headers, "Content-Encoding")
		vary, varied := coding_field(response.headers, "Vary")
		// A wildcard accepts Brotli too: it wins the tie, and still applies once gzip is refused.
		expected := "br" if item.name == "star" || item.name == "refused" else "gzip"
		testing.expect_value(t, encoded && strings.equal_fold(coding, expected), item.gzip)
		testing.expect_value(t, varied, item.vary)
		if item.vary {
			testing.expect(t, strings.equal_fold(vary, "Accept-Encoding"))
		}

		if item.gzip {
			if expected == "br" {
				coding_decode_brotli(t, response.body, plain[:item.size])
			} else {
				coding_decode(t, response.body, plain[:item.size])
			}
			testing.expect(t, len(response.body) < item.size)
		} else if item.size > 0 {
			testing.expect(t, string(response.body) == string(plain[:item.size]))
		}
	}

	absent := Request {
		allocator = allocator,
		method    = "GET",
	}

	plain := coding_repeat(2048, allocator)
	original := Response {
		status  = .OK,
		headers = text[:],
		body    = plain,
	}

	content_coding_prepare(&absent, &original)
	_, encoded := coding_field(original.headers, "Content-Encoding")
	_, varied := coding_field(original.headers, "Vary")
	testing.expect(t, !encoded && !varied && len(original.body) == 2048)

	not_modified := Response {
		status  = .Not_Modified,
		headers = {{"Cache-Control", "no-cache"}, {"ETag", "\"abc\""}},
	}

	gzip_request := Request {
		allocator = allocator,
		method    = "GET",
		headers   = {{"Accept-Encoding", "gzip"}},
	}

	content_coding_prepare(&gzip_request, &not_modified)
	testing.expect(t, len(not_modified.headers) == 2)
	_, encoded = coding_field(not_modified.headers, "Content-Encoding")
	testing.expect(t, !encoded)
}

Coding_Probe :: struct {
	calls, releases, drops, offset: int,
	chunk:                          int,
	payload:                        []u8,
	pending:                        owned.Chunk,
}

coding_probe_release :: proc(storage: []u8, data: rawptr) {
	probe := cast(^Coding_Probe)data
	assert(len(storage) == probe.chunk)
	probe.releases += 1
	delete(storage)
}

coding_probe_next :: proc(data: rawptr, io: ^Stream_IO) -> Stream_Step {
	probe := cast(^Coding_Probe)data
	probe.calls += 1
	assert(probe.releases == probe.calls - 1, "gzip layer polled before releasing the previous chunk")
	if probe.offset >= len(probe.payload) {
		return .Done
	}
	count := min(probe.chunk, len(probe.payload) - probe.offset)
	storage, err := make([]u8, probe.chunk)
	if err != nil {
		return .Failed
	}
	copy(storage[:count], probe.payload[probe.offset:][:count])
	chunk, take_error := owned.take_custom(&storage, count, coding_probe_release, probe)
	if take_error.kind != .None {
		return .Failed
	}
	probe.pending = chunk

	if stream_submit(io, &probe.pending) != .Accepted {
		owned.destroy(&probe.pending)
		return .Failed
	}

	probe.offset += count

	return .Chunk
}

coding_probe_drop :: proc(data: rawptr) {
	probe := cast(^Coding_Probe)data
	owned.destroy(&probe.pending)
	probe.drops += 1
}

coding_drive :: proc(task: ^Connection_Task) -> (header: string, body: []u8, ok: bool) {
	header = string(task.output[0])
	parts: [dynamic]u8
	defer delete(parts)

	for _ in 0 ..< 10000 {
		if task.streaming == nil {
			return header, coding_clone(parts[:]), true
		}

		if task.phase == .Write {
			if task.streaming.pending && len(task.output[1]) > 0 {
				append(&parts, ..task.output[1])
			}
			producing, done := stream_write_complete(task)
			if !done {
				return header, nil, false
			}
			if !producing {
				return header, coding_clone(parts[:]), true
			}
			task.phase = .Produce
			continue
		}

		if produce_stream(task) != .Yield {
			return header, nil, false
		}
		task.phase = .Write
	}

	return header, nil, false
}

coding_clone :: proc(src: []u8) -> []u8 {
	dst, err := make([]u8, len(src))
	if err != nil {
		return nil
	}
	copy(dst, src)

	return dst
}

@(test)
content_coding_head_has_no_body_and_stream_keeps_backpressure :: proc(t: ^testing.T) {
	runtime := Server_Runtime {
		timeouts = resolve_timeouts({}),
	}

	assert(async.init(&runtime.executor, {workers = 1, task_capacity = 1, io_capacity = 1}).kind == .None)
	defer async.destroy(&runtime.executor)
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)
	plain := coding_repeat(1200, allocator)
	headers := [2]Header{{"Content-Type", "text/plain"}, {"Cache-Control", "no-cache"}}

	head_task := Connection_Task {
		runtime = &runtime,
		phase = .Dispatch,
		request = Request{allocator = allocator, method = "HEAD", headers = {{"Accept-Encoding", "gzip"}}},
	}

	init_connection_arena(&head_task)
	defer mem.dynamic_arena_destroy(&head_task.arena)
	head_probe := Coding_Probe {
		chunk   = 400,
		payload = plain,
	}

	head := Response {
		headers = headers[:],
		stream = {
			data = &head_probe,
			next = coding_probe_next,
			drop = coding_probe_drop,
			content_length = 1200,
			max_chunk_bytes = 512,
		},
	}

	testing.expect(t, queue_response(&head_task, head))
	testing.expect(t, head_task.output[1] == nil)
	head_text := string(head_task.output[0])
	testing.expect(t, strings.contains(head_text, "Content-Encoding: gzip\r\n"))
	testing.expect(t, strings.contains(head_text, "Vary: Accept-Encoding\r\n"))
	testing.expect(t, !strings.contains(head_text, "Content-Length:"))
	testing.expect(t, !strings.contains(head_text, "Transfer-Encoding:"))
	producing, done := stream_write_complete(&head_task)
	testing.expect(t, done && !producing)
	testing.expect_value(t, head_probe.calls, 0)
	testing.expect_value(t, head_probe.drops, 1)

	body_task := Connection_Task {
		runtime = &runtime,
		phase = .Dispatch,
		request = Request{allocator = allocator, method = "GET", headers = {{"Accept-Encoding", "deflate"}}},
	}

	init_connection_arena(&body_task)
	defer mem.dynamic_arena_destroy(&body_task.arena)
	raw_probe := Coding_Probe {
		chunk   = 400,
		payload = plain,
	}

	unsupported := Response {
		headers = headers[:],
		stream = {
			data = &raw_probe,
			next = coding_probe_next,
			drop = coding_probe_drop,
			content_length = 1200,
			max_chunk_bytes = 512,
		},
	}

	testing.expect(t, queue_response(&body_task, unsupported))
	defer drop_response_stream(&body_task)
	unsupported_text := string(body_task.output[0])
	testing.expect(t, strings.contains(unsupported_text, "Content-Length: 1200\r\n"))
	testing.expect(t, strings.contains(unsupported_text, "Vary: Accept-Encoding\r\n"))
	testing.expect(t, !strings.contains(unsupported_text, "Content-Encoding:"))
	testing.expect(t, body_task.streaming.producer.next == coding_probe_next)

	gzip_task := Connection_Task {
		runtime = &runtime,
		phase = .Dispatch,
		request = Request{allocator = allocator, method = "GET", headers = {{"Accept-Encoding", "gzip, identity"}}},
	}

	init_connection_arena(&gzip_task)
	defer mem.dynamic_arena_destroy(&gzip_task.arena)
	probe := Coding_Probe {
		chunk   = 400,
		payload = plain,
	}

	stream := Response {
		headers = headers[:],
		stream = {
			data = &probe,
			next = coding_probe_next,
			drop = coding_probe_drop,
			content_length = 1200,
			max_chunk_bytes = 512,
		},
	}

	testing.expect(t, queue_response(&gzip_task, stream))
	defer drop_response_stream(&gzip_task)
	header, body, ok := coding_drive(&gzip_task)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(header, "Content-Encoding: gzip\r\n"))
	testing.expect(t, strings.contains(header, "Transfer-Encoding: chunked\r\n"))
	testing.expect(t, !strings.contains(header, "Content-Length:"))
	coding_decode(t, body, plain)
	delete(body)
	testing.expect_value(t, probe.calls, 4)
	testing.expect_value(t, probe.releases, 3)
	testing.expect_value(t, probe.drops, 1)

	buffered := Connection_Task {
		runtime = &runtime,
		phase = .Dispatch,
		request = Request{allocator = allocator, method = "HEAD", headers = {{"Accept-Encoding", "gzip"}}},
	}

	init_connection_arena(&buffered)
	defer mem.dynamic_arena_destroy(&buffered.arena)
	fixed := Response {
		headers = headers[:],
		body    = plain,
	}

	testing.expect(t, queue_response(&buffered, fixed))
	testing.expect(t, buffered.output[1] == nil)
	fixed_text := string(buffered.output[0])
	testing.expect(t, strings.contains(fixed_text, "Content-Encoding: gzip\r\n"))
	testing.expect(t, strings.contains(fixed_text, "Content-Length:"))
	testing.expect(t, !strings.contains(fixed_text, "Transfer-Encoding:"))
}

coding_decode_brotli :: proc(t: ^testing.T, encoded, expected: []u8) {
	output: [dynamic]u8
	defer delete(output)
	error := brotli.decompress(&output, encoded, expected_output_size = len(expected))
	testing.expect_value(t, error, nil)
	testing.expect(t, string(output[:]) == string(expected))
}

@(test)
content_coding_negotiation_table_prefers_brotli_by_q_value :: proc(t: ^testing.T) {
	both := bit_set[Content_Coding]{.Gzip, .Brotli}
	cases := []struct {
		accept:    string,
		available: bit_set[Content_Coding],
		expected:  Content_Coding,
	} {
		{"br", both, .Brotli},
		{"gzip", both, .Gzip},
		{"br, gzip", both, .Brotli},
		{"gzip, br", both, .Brotli},
		{"gzip, deflate, br", both, .Brotli},
		{"BR, GZIP", both, .Brotli},
		{"x-gzip, br;q=0.4", both, .Gzip},
		{"br;q=0.5, gzip;q=1", both, .Gzip},
		{"br;q=1, gzip;q=0.5", both, .Brotli},
		{"br;q=0.8, gzip;q=0.8", both, .Brotli},
		{"br;q=0, gzip", both, .Gzip},
		{"gzip;q=0, br", both, .Brotli},
		{"br;q=0, gzip;q=0", both, .Identity},
		{"*", both, .Brotli},
		{"*;q=0.5, gzip;q=0.9", both, .Gzip},
		{"*;q=0, gzip", both, .Gzip},
		{"*;q=0, br;q=0.1, gzip;q=0.1", both, .Brotli},
		{"identity;q=1, br;q=0.5", both, .Identity},
		{"identity;q=0.5, br;q=0.5", both, .Brotli},
		{"identity;q=0", both, .Identity},
		{"deflate", both, .Identity},
		{"", both, .Identity},
		{"br;q=2", both, .Identity},
		{"br, gzip", {.Gzip}, .Gzip},
		{"br, gzip", {.Brotli}, .Brotli},
		{"br", {.Gzip}, .Identity},
		{"br, gzip", {}, .Identity},
	}

	for item in cases {
		headers := []Header{{"Accept-Encoding", item.accept}}
		testing.expect_value(t, negotiate_coding(parse_accept_encoding(headers), item.available), item.expected)
	}

	// No header at all stays identity.
	testing.expect_value(t, negotiate_coding(parse_accept_encoding(nil)), Content_Coding.Identity)
	// Several header lines combine; the first mention of a coding wins.
	lines := []Header{{"Accept-Encoding", "gzip"}, {"Accept-Encoding", "br"}}
	testing.expect_value(t, negotiate_coding(parse_accept_encoding(lines)), Content_Coding.Brotli)
}

@(test)
content_coding_brotli_round_trips_and_keeps_representation_metadata :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)
	plain := coding_repeat(4096, allocator)
	headers := []Header{{"Content-Type", "text/html"}, {"ETag", "\"v1\""}, {"Cache-Control", "no-cache"}}

	for item in ([]struct {
			accept:   string,
			coding:   string,
			weak:     bool,
		} {
			{"br", "br", true},
			{"gzip, br", "br", true},
			{"gzip", "gzip", true},
			{"gzip;q=1, br;q=0.5", "gzip", true},
			{"deflate", "", false},
		}) {
		request := Request {
			allocator = allocator,
			method    = "GET",
			headers   = {{"Accept-Encoding", item.accept}},
		}

		response := Response {
			status  = .OK,
			headers = headers,
			body    = plain,
		}

		content_coding_prepare(&request, &response)
		coding, encoded := coding_field(response.headers, "Content-Encoding")
		vary, varied := coding_field(response.headers, "Vary")
		tag, _ := coding_field(response.headers, "ETag")
		testing.expect_value(t, encoded, item.coding != "")
		testing.expect_value(t, coding, item.coding)
		testing.expect(t, varied && strings.equal_fold(vary, "Accept-Encoding"))
		testing.expect_value(t, tag, "W/\"v1\"" if item.weak else "\"v1\"")

		switch item.coding {
		case "br":
			testing.expect(t, len(response.body) < len(plain))
			coding_decode_brotli(t, response.body, plain)
		case "gzip":
			coding_decode(t, response.body, plain)
		case:
			testing.expect(t, string(response.body) == string(plain))
		}
	}

	// Weak validators and small or incompressible bodies are left alone.
	request := Request {
		allocator = allocator,
		method    = "GET",
		headers   = {{"Accept-Encoding", "br"}},
	}

	weak := Response {
		status  = .OK,
		headers = {{"Content-Type", "text/html"}, {"ETag", "W/\"v1\""}},
		body    = plain,
	}

	content_coding_prepare(&request, &weak)
	tag, _ := coding_field(weak.headers, "ETag")
	testing.expect_value(t, tag, "W/\"v1\"")
	noise, noise_error := make([]u8, 2048, allocator)
	testing.expect_value(t, noise_error, nil)
	state := u32(2463534242)

	for &value in noise {
		state ~= state << 13
		state ~= state >> 17
		state ~= state << 5
		value = u8(state)
	}

	random := Response {
		status  = .OK,
		headers = {{"Content-Type", "text/plain"}},
		body    = noise,
	}

	content_coding_prepare(&request, &random)
	_, encoded := coding_field(random.headers, "Content-Encoding")
	testing.expect(t, !encoded && raw_data(random.body) == raw_data(noise))
}

@(test)
content_coding_streams_brotli_with_bounded_memory :: proc(t: ^testing.T) {
	runtime := Server_Runtime {
		timeouts = resolve_timeouts({}),
	}

	assert(async.init(&runtime.executor, {workers = 1, task_capacity = 1, io_capacity = 1}).kind == .None)
	defer async.destroy(&runtime.executor)
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)
	plain := coding_repeat(70000, allocator)
	headers := [2]Header{{"Content-Type", "text/plain"}, {"Cache-Control", "no-cache"}}

	task := Connection_Task {
		runtime = &runtime,
		phase = .Dispatch,
		request = Request{allocator = allocator, method = "GET", headers = {{"Accept-Encoding", "br, gzip"}}},
	}

	init_connection_arena(&task)
	defer mem.dynamic_arena_destroy(&task.arena)
	probe := Coding_Probe {
		chunk   = 3000,
		payload = plain,
	}

	stream := Response {
		headers = headers[:],
		stream = {
			data = &probe,
			next = coding_probe_next,
			drop = coding_probe_drop,
			content_length = i64(len(plain)),
			max_chunk_bytes = 4096,
		},
	}

	testing.expect(t, queue_response(&task, stream))
	defer drop_response_stream(&task)
	header, body, ok := coding_drive(&task)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(header, "Content-Encoding: br\r\n"))
	testing.expect(t, strings.contains(header, "Vary: Accept-Encoding\r\n"))
	testing.expect(t, strings.contains(header, "Transfer-Encoding: chunked\r\n"))
	testing.expect(t, !strings.contains(header, "Content-Length:"))
	testing.expect(t, len(body) < len(plain) / 4)
	coding_decode_brotli(t, body, plain)
	delete(body)
	testing.expect_value(t, probe.drops, 1)

	head_task := Connection_Task {
		runtime = &runtime,
		phase = .Dispatch,
		request = Request{allocator = allocator, method = "HEAD", headers = {{"Accept-Encoding", "br"}}},
	}

	init_connection_arena(&head_task)
	defer mem.dynamic_arena_destroy(&head_task.arena)
	head_probe := Coding_Probe {
		chunk   = 3000,
		payload = plain,
	}

	head := stream
	head.stream.data = &head_probe
	testing.expect(t, queue_response(&head_task, head))
	head_text := string(head_task.output[0])
	testing.expect(t, strings.contains(head_text, "Content-Encoding: br\r\n"))
	testing.expect(t, !strings.contains(head_text, "Content-Length:"))
	producing, done := stream_write_complete(&head_task)
	testing.expect(t, done && !producing)
	testing.expect_value(t, head_probe.calls, 0)
}

Loopback_Coding :: struct {
	config:  Server,
	control: Server_Control,
	ok:      bool,
}

loopback_coding_handler :: proc(data: rawptr, _: ^Connection, request: ^Request) -> Response {
	text := (cast(^[]u8)data)^

	return make_response(
		request,
		.OK,
		{{"Content-Type", "text/html; charset=utf-8"}, {"ETag", "\"page-1\""}, {"Cache-Control", "no-cache"}},
		text,
	)
}

// Sends one request on a fresh connection and returns the whole response.
loopback_coding_exchange :: proc(endpoint: net.Endpoint, accept: string) -> []u8 {
	client, dial_error := net.dial_tcp(endpoint)
	assert(dial_error == nil)
	defer net.close(client)
	_ = net.set_option(client, .Receive_Timeout, 5 * time.Second)
	request := fmt.tprintf("GET /page HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nAccept-Encoding: %s\r\n\r\n", accept)
	_, send_error := net.send_tcp(client, transmute([]u8)request)
	assert(send_error == nil)
	received: [dynamic]u8
	chunk: [4096]u8

	for {
		count, receive_error := net.recv_tcp(client, chunk[:])

		if count > 0 {
			append(&received, ..chunk[:count])
		}

		if count == 0 || receive_error != nil {
			break
		}
	}

	return received[:]
}

@(test)
loopback_request_with_accept_encoding_br_gets_a_brotli_body :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 20 * time.Second)
	plain := coding_repeat(6000, context.allocator)
	defer delete(plain)
	handled := plain
	fixture: Loopback_Coding
	fixture.config = {
		address      = "127.0.0.1",
		handler      = loopback_coding_handler,
		handler_data = &handled,
		control      = &fixture.control,
		workers      = 2,
	}

	worker := thread.create_and_start_with_poly_data(&fixture, proc(f: ^Loopback_Coding) {f.ok = serve(f.config)})
	assert(worker != nil)
	defer thread.destroy(worker)
	joined := false

	defer if !joined {
		stop_server(&fixture.control)
		thread.join(worker)
	}

	// A startup bound only: generous, since a loaded machine can take seconds
	// to start serve, and nothing here measures it.
	until := time.tick_add(time.tick_now(), 60 * time.Second)

	for !server_ready(&fixture.control) && time.tick_diff(time.tick_now(), until) > 0 {
		thread.yield()
	}

	endpoint, ready := server_endpoint(&fixture.control)

	if !testing.expect(t, ready && endpoint.port > 0) {
		return
	}

	for item in ([]struct {
			accept: string,
			coding: string,
		}{{"br", "br"}, {"gzip, br", "br"}, {"gzip", "gzip"}, {"identity", ""}}) {
		wire := loopback_coding_exchange(endpoint, item.accept)
		defer delete(wire)
		split := strings.index(string(wire), "\r\n\r\n")

		if !testing.expect(t, split > 0) {
			continue
		}

		head := string(wire[:split])
		body := wire[split + 4:]
		testing.expect(t, strings.has_prefix(head, "HTTP/1.1 200"))
		testing.expect(t, strings.contains(head, "Vary: Accept-Encoding\r\n"))

		if item.coding == "" {
			testing.expect(t, !strings.contains(head, "Content-Encoding:"))
			testing.expect(t, strings.contains(head, "ETag: \"page-1\"\r\n"))
			testing.expect(t, string(body) == string(plain))
			continue
		}

		testing.expect(t, strings.contains(head, fmt.tprintf("Content-Encoding: %s\r\n", item.coding)))
		testing.expect(t, strings.contains(head, "ETag: W/\"page-1\"\r\n"))
		testing.expect(t, strings.contains(head, fmt.tprintf("Content-Length: %d\r\n", len(body))))
		testing.expect(t, len(body) < len(plain) / 4)

		if item.coding == "br" {
			coding_decode_brotli(t, body, plain)
		} else {
			coding_decode(t, body, plain)
		}
	}

	stop_server(&fixture.control)
	thread.join(worker)
	joined = true
	testing.expect(t, fixture.ok)
}

@(test)
coded_response_drops_the_handler_content_length :: proc(t: ^testing.T) {
	allocator := context.temp_allocator
	plain := coding_repeat(2000, allocator)
	handler_headers := []Header{{"Content-Type", "text/plain"}, {"Content-Length", "2000"}}
	buffer: [512]u8

	for accept in ([]string{"", "gzip", "br"}) {
		request := Request {
			allocator = allocator,
			method    = "GET",
		}
		if accept != "" {
			request.headers = {{"Accept-Encoding", accept}}
		}
		response := Response {
			status  = .OK,
			headers = handler_headers,
			body    = plain,
		}

		content_coding_prepare(&request, &response)
		_, encoded := coding_field(response.headers, "Content-Encoding")
		_, stated := coding_field(response.headers, "Content-Length")
		testing.expect_value(t, encoded, accept != "")
		testing.expect_value(t, stated, accept == "")
		_, valid := response_headers(response, buffer[:], true)
		testing.expectf(t, valid, "head for Accept-Encoding %q", accept)
	}

	testing.expect_value(t, len(handler_headers), 2)
	testing.expect_value(t, handler_headers[1].name, "Content-Length")
}

// Bytes that neither gzip nor brotli can shrink, so the coded stream grows with its input.
coding_noise :: proc(count: int, allocator: mem.Allocator) -> []u8 {
	data, err := make([]u8, count, allocator)
	if err != nil {
		return nil
	}
	state := u32(0x9e3779b9)
	for &value in data {
		state ~= state << 13
		state ~= state >> 17
		state ~= state << 5
		value = u8(state)
	}

	return data
}

@(test)
coded_stream_past_its_output_ceiling_fails_instead_of_growing :: proc(t: ^testing.T) {
	runtime := Server_Runtime {
		timeouts = resolve_timeouts({}),
	}

	assert(async.init(&runtime.executor, {workers = 1, task_capacity = 1, io_capacity = 1}).kind == .None)
	defer async.destroy(&runtime.executor)
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)
	plain := coding_noise(512 * 1024, allocator)
	CEILING :: 8 * 1024

	for accept in ([]string{"gzip", "br"}) {
		task := Connection_Task {
			runtime = &runtime,
			phase = .Dispatch,
			request = Request{allocator = allocator, method = "GET", headers = {{"Accept-Encoding", accept}}},
		}

		init_connection_arena(&task)
		probe := Coding_Probe {
			chunk   = 4096,
			payload = plain,
		}
		headers := [1]Header{{"Content-Type", "application/json"}}
		response := Response {
			headers = headers[:],
			stream = {
				data = &probe,
				next = coding_probe_next,
				drop = coding_probe_drop,
				content_length = i64(len(plain)),
				max_chunk_bytes = 4096,
			},
		}

		testing.expect(t, queue_response(&task, response))
		state := cast(^Coding_Stream)task.streaming.producer.data
		testing.expectf(t, task.streaming.producer.next == coding_next, "%s: stream is coded", accept)

		// The encoder is built with the response ceiling. Lower it to one this
		// input passes; the stream must then fail rather than keep emitting.
		if state.coding == .Gzip {
			testing.expect_value(t, state.encoder.gzip.max_output, i64(GZIP_MAX_OUTPUT))
			reset := incremental.deflate_encoder_reset(&state.encoder.gzip, .Gzip, GZIP_DYNAMIC_LEVEL, CEILING)
			testing.expect_value(t, reset, nil)
		} else {
			testing.expect_value(t, state.encoder.brotli.max_output, GZIP_MAX_OUTPUT)
			brotli.stream_reset(&state.encoder.brotli, CEILING)
		}

		_, body, ok := coding_drive(&task)
		testing.expectf(t, !ok && body == nil, "%s: a stream past its ceiling must fail", accept)
		testing.expectf(t, state.failed, "%s: the coding layer records the failure", accept)
		// Each encoder buffers at most a block or two, so it fails long before the input ends.
		testing.expectf(t, probe.offset < len(plain) / 2, "%s: read %d of %d bytes before failing", accept, probe.offset, len(plain))
		drop_response_stream(&task)
		testing.expect_value(t, probe.drops, 1)
		mem.dynamic_arena_destroy(&task.arena)
	}
}
