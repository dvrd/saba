package saba_core

import gzip "core:compress/gzip"
import "core:bytes"
import "core:mem"
import owned "core:mem/owned"
import "core:strings"
import "core:testing"
import async "shared:async"

@(private)
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

@(private)
coding_field :: proc(headers: []Header, name: string) -> (string, bool) {
	for header in headers {
		if strings.equal_fold(header.name, name) {
			return header.value, true
		}
	}

	return "", false
}

@(private)
coding_decode :: proc(t: ^testing.T, encoded, expected: []u8) {
	buffer: bytes.Buffer
	defer bytes.buffer_destroy(&buffer)
	error := gzip.load_from_bytes(encoded, &buffer, len(encoded), len(expected))
	testing.expect_value(t, error, nil)
	testing.expect(t, bytes.buffer_to_string(&buffer) == string(expected))
}

@(test)
gzip_round_trip_and_short_writes_match_limits :: proc(t: ^testing.T) {
	testing.expect(t, gzip.stream_bound(GZIP_MAX_INPUT) <= GZIP_MAX_OUTPUT)
	plain := coding_repeat(4096, context.allocator)
	defer delete(plain)
	encoder, alloc_error := new(gzip.Stream_Encoder)
	testing.expect(t, alloc_error == nil && encoder != nil)
	defer free(encoder)
	gzip.stream_reset(encoder, GZIP_MAX_OUTPUT)
	encoded, encode_error := make([]u8, gzip.stream_bound(len(plain)))
	testing.expect(t, encode_error == nil)
	defer delete(encoded)
	offset, written := 0, 0

	for offset < len(plain) {
		if len(encoder.out) - encoder.out_len < 32 {
			count := gzip.stream_pull(encoder, encoded[written:])
			testing.expect(t, count > 0)
			written += count
			continue
		}

		step := min(5, len(plain) - offset)
		count := gzip.stream_write(encoder, plain[offset:offset + step])
		testing.expect(t, count > 0 && count <= step)
		offset += count
	}

	for !encoder.finished {
		if len(encoder.out) - encoder.out_len < 32 {
			written += gzip.stream_pull(encoder, encoded[written:])
			continue
		}

		testing.expect(t, gzip.stream_finish(encoder) || encoder.overflow == false)
		if encoder.overflow {
			break
		}
	}

	for encoder.out_len != encoder.out_off {
		written += gzip.stream_pull(encoder, encoded[written:])
	}

	testing.expect(t, !encoder.overflow && written > 0 && written < len(plain))
	testing.expect(t, written <= GZIP_MAX_OUTPUT)
	coding_decode(t, encoded[:written], plain)
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
		{"br", "br, deflate", 2048, text[:], false, true},
		{"refused", "gzip;q=0, *", 2048, text[:], false, true},
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
		testing.expect_value(t, encoded && strings.equal_fold(coding, "gzip"), item.gzip)
		testing.expect_value(t, varied, item.vary)
		if item.vary {
			testing.expect(t, strings.equal_fold(vary, "Accept-Encoding"))
		}

		if item.gzip {
			coding_decode(t, response.body, plain[:item.size])
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

@(private)
Coding_Probe :: struct {
	calls, releases, drops, offset: int,
	chunk:                          int,
	payload:                        []u8,
	pending:                        owned.Chunk,
}

@(private)
coding_probe_release :: proc(storage: []u8, data: rawptr) {
	probe := cast(^Coding_Probe)data
	assert(len(storage) == probe.chunk)
	probe.releases += 1
	delete(storage)
}

@(private)
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

@(private)
coding_probe_drop :: proc(data: rawptr) {
	probe := cast(^Coding_Probe)data
	owned.destroy(&probe.pending)
	probe.drops += 1
}

@(private)
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

@(private)
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
