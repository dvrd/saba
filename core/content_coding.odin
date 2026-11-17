package saba_core

import exchange "../../http/exchange"
import rt "base:runtime"
import "core:compress/brotli"
import gzip "core:compress/gzip"
import "core:mem"
import owned "core:mem/owned"
import "core:strings"

// Identity is always acceptable. Gzip (x-gzip is an alias) and Brotli (br) are the
// other codings; the higher q-value wins and Brotli wins a tie.
// Absent or malformed Accept-Encoding stays identity and does not add Vary.
// The size limits below apply to every coding.
GZIP_MIN_BYTES :: 1024
GZIP_MAX_INPUT :: 1 << 20
GZIP_MAX_OUTPUT :: (1 << 20) + (1 << 18)
// Dynamic responses trade ratio for speed; prepared assets use brotli.Level(11).
BROTLI_DYNAMIC_LEVEL :: brotli.Level(4)
BROTLI_PREPARED_LEVEL :: brotli.Level(11)

Content_Coding :: enum {
	Identity,
	Gzip,
	Brotli,
}

content_coding_token :: proc(coding: Content_Coding) -> string {
	switch coding {
	case .Gzip:
		return "gzip"
	case .Brotli:
		return "br"
	case .Identity:
	}

	return "identity"
}

// Encodes `src` once, smaller than the input or not at all; nil otherwise. The
// result lives in `allocator`; scratch space is heap-owned and released.
encode_smaller :: proc(coding: Content_Coding, src: []u8, level: brotli.Level, allocator: mem.Allocator) -> []u8 {
	if allocator.procedure == nil || len(src) == 0 || len(src) > GZIP_MAX_INPUT {
		return nil
	}

	scratch := rt.heap_allocator()
	encoded: []u8
	error: bool

	switch coding {
	case .Brotli:
		result, brotli_error := brotli.encode(src, level, scratch)
		encoded, error = result, brotli_error != nil
	case .Gzip:
		result, gzip_error := gzip.encode(src, .Best, scratch)
		encoded, error = result, gzip_error != nil
	case .Identity:
		return nil
	}

	defer delete(encoded, scratch)

	if error || len(encoded) == 0 || len(encoded) >= len(src) || len(encoded) > GZIP_MAX_OUTPUT {
		return nil
	}

	exact, exact_error := make([]u8, len(encoded), allocator)

	if exact_error != nil {
		return nil
	}

	copy(exact, encoded)

	return exact
}

brotli_compress :: proc(src: []u8, allocator: mem.Allocator) -> []u8 {
	return encode_smaller(.Brotli, src, BROTLI_DYNAMIC_LEVEL, allocator)
}

gzip_compress :: proc(src: []u8, allocator: mem.Allocator) -> []u8 {
	// Scratch is heap-owned so a request arena, which cannot free individuals, is
	// only charged the exact encoded body.
	bound := gzip.stream_bound(len(src))
	scratch := rt.heap_allocator()
	if bound <= 0 || bound > GZIP_MAX_OUTPUT || allocator.procedure == nil {
		return nil
	}
	encoder, alloc_error := new(gzip.Stream_Encoder, scratch)
	if alloc_error != nil || encoder == nil {
		return nil
	}
	defer free(encoder, scratch)
	gzip.stream_reset(encoder, GZIP_MAX_OUTPUT)
	staged, stage_error := make([]u8, bound, scratch)
	if stage_error != nil {
		return nil
	}
	defer delete(staged, scratch)
	written, ok := gzip.stream_encode_into(encoder, src, staged)
	if !ok || written <= 0 || written >= len(src) {
		return nil
	}
	exact, exact_error := make([]u8, written, allocator)
	if exact_error != nil {
		return nil
	}
	copy(exact, staged[:written])

	return exact
}

is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}
is_alpha :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}
// HTTP optional whitespace.
is_blank :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t'
}

// Index of the next list element: skips optional whitespace and empty elements.
skip_list_separators :: proc(value: string, from: int) -> int {
	index := from

	for index < len(value) && (is_blank(value[index]) || value[index] == ',') {
		index += 1
	}

	return index
}

Coding_Choice :: struct {
	gzip, brotli, identity, star: int,
	present, valid:               bool,
}

coding_token :: proc(value: u8) -> bool {
	if is_digit(value) || is_alpha(value) {
		return true
	}

	switch value {
	case '!', '#', '$', '%', '&', '\'', '+', '-', '.', '^', '_', '`', '|', '~':
		return true
	}

	return false
}

parse_qvalue :: proc(value: string) -> (q, next: int, ok: bool) {
	if len(value) == 0 {
		return
	}
	index := 0

	if value[0] == '1' {
		q = 1000
		index = 1

		if index < len(value) && value[index] == '.' {
			index += 1
			digits := 0

			for digits < 3 && index < len(value) && is_digit(value[index]) {
				if value[index] != '0' {
					return
				}
				index += 1
				digits += 1
			}
		}
	} else if value[0] == '0' {
		index = 1

		if index < len(value) && value[index] == '.' {
			index += 1
			weight := 100
			digits := 0

			for digits < 3 && index < len(value) && is_digit(value[index]) {
				q += int(value[index] - '0') * weight
				weight /= 10
				index += 1
				digits += 1
			}
		}
	} else {
		return
	}

	if index < len(value) && is_digit(value[index]) {
		return
	}

	return q, index, true
}

accept_coding :: proc(choice: ^Coding_Choice, name: string, q: int) {
	if name == "*" {
		if choice.star < 0 {
			choice.star = q
		}
		return
	}

	if strings.equal_fold(name, "gzip") || strings.equal_fold(name, "x-gzip") {
		if choice.gzip < 0 {
			choice.gzip = q
		}
		return
	}

	if strings.equal_fold(name, "br") {
		if choice.brotli < 0 {
			choice.brotli = q
		}
		return
	}

	if strings.equal_fold(name, "identity") && choice.identity < 0 {
		choice.identity = q
	}
}

parse_coding_list :: proc(value: string, choice: ^Coding_Choice) -> bool {
	index := 0

	for index < len(value) {
		index = skip_list_separators(value, index)
		if index >= len(value) {
			return true
		}
		start := index

		if value[index] == '*' {
			index += 1
		} else {
			for index < len(value) && coding_token(value[index]) {
				index += 1
			}
			if index == start {
				return false
			}
		}

		name := value[start:index]
		quality := 1000
		cursor := index
		for cursor < len(value) && is_blank(value[cursor]) {
			cursor += 1
		}

		if cursor < len(value) && value[cursor] == ';' {
			cursor += 1
			for cursor < len(value) && is_blank(value[cursor]) {
				cursor += 1
			}

			if cursor + 1 >= len(value) || (value[cursor] != 'q' && value[cursor] != 'Q') || value[cursor + 1] != '=' {
				return false
			}

			parsed, consumed, ok := parse_qvalue(value[cursor + 2:])
			if !ok {
				return false
			}
			quality = parsed
			cursor = cursor + 2 + consumed

			if cursor < len(value) && !is_blank(value[cursor]) && value[cursor] != ',' {
				return false
			}

			index = cursor
		}

		accept_coding(choice, name, quality)
	}

	return true
}

parse_accept_encoding :: proc(headers: []Header) -> Coding_Choice {
	choice := Coding_Choice {
		gzip     = -1,
		brotli   = -1,
		identity = -1,
		star     = -1,
		valid    = true,
	}

	for header in headers {
		if !strings.equal_fold(header.name, "Accept-Encoding") {
			continue
		}
		choice.present = true

		if !parse_coding_list(header.value, &choice) {
			return Coding_Choice{}
		}
	}

	return choice
}

// Effective q-value of one coding: explicit, else the wildcard, else refused. An
// identity entry ranked above the coding makes identity the better answer.
coding_quality :: proc(choice: Coding_Choice, explicit: int) -> int {
	quality := explicit

	if quality < 0 {
		if choice.star >= 0 {
			quality = choice.star
		} else {
			quality = 0
		}
	}

	if quality <= 0 {
		return 0
	}

	if choice.identity >= 0 && choice.identity > quality {
		return 0
	}

	return quality
}

// The coding to use among `available`: the highest acceptable q-value, Brotli on a
// tie, identity when nothing is acceptable or the header is absent or malformed.
negotiate_coding :: proc(choice: Coding_Choice, available := bit_set[Content_Coding]{.Gzip, .Brotli}) -> Content_Coding {
	if !choice.present || !choice.valid {
		return .Identity
	}

	brotli_quality, gzip_quality := 0, 0

	if .Brotli in available {
		brotli_quality = coding_quality(choice, choice.brotli)
	}

	if .Gzip in available {
		gzip_quality = coding_quality(choice, choice.gzip)
	}

	if brotli_quality > 0 && brotli_quality >= gzip_quality {
		return .Brotli
	}

	if gzip_quality > 0 {
		return .Gzip
	}

	return .Identity
}

cache_forbids_coding :: proc(value: string) -> bool {
	index := 0

	for index < len(value) {
		index = skip_list_separators(value, index)
		start := index

		for index < len(value) && value[index] != ',' && value[index] != '=' && !is_blank(value[index]) {
			index += 1
		}

		if strings.equal_fold(value[start:index], "no-store") || strings.equal_fold(value[start:index], "private") {
			return true
		}

		for index < len(value) && value[index] != ',' {
			index += 1
		}
	}

	return false
}

compressible_type :: proc(value: string) -> bool {
	start := 0
	for start < len(value) && is_blank(value[start]) {
		start += 1
	}
	end := start
	for end < len(value) && value[end] != ';' && !is_blank(value[end]) {
		end += 1
	}
	media := value[start:end]
	if len(media) >= 5 && strings.equal_fold(media[:5], "text/") {
		return true
	}
	if strings.equal_fold(media, "image/svg+xml") {
		return true
	}
	if strings.equal_fold(media, "application/javascript") {
		return true
	}
	if strings.equal_fold(media, "application/json") {
		return true
	}
	if strings.equal_fold(media, "application/xml") {
		return true
	}
	if strings.equal_fold(media, "application/xhtml+xml") {
		return true
	}
	if len(media) >= 5 && strings.equal_fold(media[len(media) - 5:], "+json") {
		return true
	}
	if len(media) >= 4 && strings.equal_fold(media[len(media) - 4:], "+xml") {
		return true
	}

	return false
}

coding_eligible :: proc(response: Response, plain: int) -> bool {
	status := int(response.status)
	if status == 0 {
		status = 200
	}
	if status < 200 || status == 204 || status == 206 || status == 304 {
		return false
	}

	if plain < GZIP_MIN_BYTES || plain > GZIP_MAX_INPUT || gzip.stream_bound(plain) > GZIP_MAX_OUTPUT {
		return false
	}

	typed := false
	compressible := false

	for header in response.headers {
		if strings.equal_fold(header.name, "Content-Encoding") || strings.equal_fold(header.name, "Content-Range") {
			return false
		}

		if strings.equal_fold(header.name, "Cache-Control") && cache_forbids_coding(header.value) {
			return false
		}

		if !typed && strings.equal_fold(header.name, "Content-Type") {
			typed = true
			compressible = compressible_type(header.value)
		}
	}

	return typed && compressible
}

header_room :: proc(headers: []Header) -> bool {
	used := 96

	for header in headers {
		used += len(header.name) + len(header.value) + 4
		if used > 7000 {
			return false
		}
	}

	return true
}

vary_lists_encoding :: proc(headers: []Header) -> bool {
	for header in headers {
		if !strings.equal_fold(header.name, "Vary") {
			continue
		}
		index := 0
		value := header.value

		for index < len(value) {
			index = skip_list_separators(value, index)
			start := index

			for index < len(value) && value[index] != ',' && !is_blank(value[index]) {
				index += 1
			}

			token := value[start:index]
			if token == "*" || strings.equal_fold(token, "Accept-Encoding") {
				return true
			}
		}
	}

	return false
}

append_response_headers :: proc(request: ^Request, response: ^Response, extra: []Header) -> bool {
	if request.allocator.procedure == nil {
		return false
	}
	stored, err := make([]Header, len(response.headers) + len(extra), request.allocator)
	if err != nil {
		return false
	}
	copy(stored, response.headers)
	copy(stored[len(response.headers):], extra)
	response.headers = stored

	return true
}

Coding_Stream :: struct {
	allocator:                      mem.Allocator,
	inner:                          Response_Stream,
	side:                           exchange.Exchange,
	coding:                         Content_Coding,
	encoder:                        struct #raw_union {
		gzip:   gzip.Stream_Encoder,
		brotli: brotli.Stream_Encoder,
	},
	held:                           []u8,
	wire:                           []u8,
	held_off, wire_len:             int,
	have, inner_done, busy, failed: bool,
}

coding_stream_free :: proc(state: ^Coding_Stream) {
	if state == nil {
		return
	}
	exchange.destroy(&state.side)
	delete(state.wire, state.allocator)
	free(state, state.allocator)
}

coding_drop :: proc(data: rawptr) {
	state := cast(^Coding_Stream)data
	if state == nil {
		return
	}
	inner := state.inner
	state.inner = {}
	coding_stream_free(state)
	if inner.drop != nil {
		inner.drop(inner.data)
	}
}

// Gzip and Brotli stream encoders share one shape: write a prefix, pull output,
// finish. These adapters keep the polling loop independent of the coding.
coding_encoder_pull :: proc(state: ^Coding_Stream, dst: []u8) -> int {
	if state.coding == .Brotli {
		return brotli.stream_pull(&state.encoder.brotli, dst)
	}

	return gzip.stream_pull(&state.encoder.gzip, dst)
}

coding_encoder_write :: proc(state: ^Coding_Stream, src: []u8) -> int {
	if state.coding == .Brotli {
		return brotli.stream_write(&state.encoder.brotli, src)
	}

	return gzip.stream_write(&state.encoder.gzip, src)
}

coding_encoder_finish :: proc(state: ^Coding_Stream) {
	if state.coding == .Brotli {
		brotli.stream_finish(&state.encoder.brotli)
	} else {
		gzip.stream_finish(&state.encoder.gzip)
	}
}

coding_encoder_finished :: proc(state: ^Coding_Stream) -> bool {
	if state.coding == .Brotli {
		return state.encoder.brotli.finished
	}

	return state.encoder.gzip.finished
}

coding_encoder_overflow :: proc(state: ^Coding_Stream) -> bool {
	if state.coding == .Brotli {
		return state.encoder.brotli.overflow
	}

	return state.encoder.gzip.overflow
}

// A write that took nothing is a stall only when pulling cannot help: the output
// buffer has room (gzip) or holds nothing to pull (Brotli), or the stream overflowed.
coding_encoder_stalled :: proc(state: ^Coding_Stream) -> bool {
	if coding_encoder_overflow(state) {
		return true
	}

	if state.coding == .Brotli {
		return state.encoder.brotli.out_len == state.encoder.brotli.out_off
	}

	return len(state.encoder.gzip.out) - state.encoder.gzip.out_len >= 16
}

coding_fail :: proc(state: ^Coding_Stream) -> Stream_Step {
	state.failed = true

	return .Failed
}

coding_next :: proc(data: rawptr, io: ^Stream_IO) -> Stream_Step {
	state := cast(^Coding_Stream)data
	if state == nil || io == nil || state.failed || state.busy {
		return .Failed
	}

	for _ in 0 ..< 8 {
		if state.wire_len == 0 {
			state.wire_len = coding_encoder_pull(state, state.wire)
		}

		if state.wire_len > 0 {
			chunk := owned.Chunk {
				data      = state.wire[:state.wire_len],
				storage   = state.wire,
				release   = coding_wire_release,
				user_data = state,
			}

			state.busy = true
			state.wire_len = 0

			if stream_submit(io, &chunk) != .Accepted {
				state.busy = false
				return coding_fail(state)
			}

			return .Chunk
		}

		if coding_encoder_finished(state) {
			return .Done
		}

		if state.have && state.held_off < len(state.held) {
			count := coding_encoder_write(state, state.held[state.held_off:])

			if count <= 0 {
				if coding_encoder_stalled(state) {
					return coding_fail(state)
				}

				continue
			}

			state.held_off += count
			continue
		}

		if state.have {
			if !exchange.release_body(&state.side) {
				return coding_fail(state)
			}
			state.have, state.held, state.held_off = false, nil, 0
		}

		if state.inner_done {
			coding_encoder_finish(state)

			if coding_encoder_overflow(state) {
				return coding_fail(state)
			}

			continue
		}

		capture := io^
		capture._exchange = &state.side
		capture._submitted = false
		capture._waiting = false
		step := state.inner.next(state.inner.data, &capture)
		if capture._waiting {
			io._waiting = true
		}

		switch step {
		case .Waiting:
			if !io._waiting || capture._submitted {
				return coding_fail(state)
			}
			return .Waiting
		case .Yield:
			if io._waiting || capture._submitted {
				return coding_fail(state)
			}
			return .Yield
		case .Failed:
			return coding_fail(state)
		case .Done:
			if capture._submitted || capture._waiting {
				return coding_fail(state)
			}
			state.inner_done = true
			if exchange.finish(&state.side).kind != .None {
				return coding_fail(state)
			}
		case .Chunk:
			if !capture._submitted || capture._waiting {
				return coding_fail(state)
			}
			payload, ok := exchange.body(&state.side)
			if !ok || len(payload) == 0 {
				return coding_fail(state)
			}
			state.held, state.held_off, state.have = payload, 0, true
		}
	}

	// One poll stays bounded. The encoder keeps its window, so the next poll continues.
	return .Yield
}

coding_wire_release :: proc(_: []u8, data: rawptr) {
	if data != nil {
		(cast(^Coding_Stream)data).busy = false
	}
}

coding_stream_attach :: proc(request: ^Request, response: ^Response, coding: Content_Coding) -> bool {
	allocator := request.backing_allocator
	if allocator.procedure == nil {
		allocator = rt.heap_allocator()
	}
	chunk_cap := response.stream.max_chunk_bytes
	if chunk_cap == 0 {
		chunk_cap = 64 * 1024
	}
	if chunk_cap < 1 || chunk_cap > mem.Megabyte {
		return false
	}
	plain := response.stream.content_length
	state, alloc_error := new(Coding_Stream, allocator)
	if alloc_error != nil || state == nil {
		return false
	}
	state.allocator = allocator
	state.inner = response.stream
	state.coding = coding

	if coding == .Brotli {
		brotli.stream_reset(&state.encoder.brotli, GZIP_MAX_OUTPUT)
	} else {
		gzip.stream_reset(&state.encoder.gzip, GZIP_MAX_OUTPUT)
	}

	wire, wire_error := make([]u8, chunk_cap, allocator)

	if wire_error != nil {
		free(state, allocator)
		return false
	}

	state.wire = wire
	if exchange.init(&state.side, .GET, {chunk_capacity = 1, max_retained_bytes = chunk_cap, max_body_bytes = plain}, allocator).kind !=
	   .None {
		coding_stream_free(state)
		return false
	}

	if exchange.respond(&state.side, {status = 200, content_length = plain}).kind != .None {
		coding_stream_free(state)
		return false
	}

	response.stream = {
		data            = state,
		next            = coding_next,
		drop            = coding_drop,
		content_length  = -1,
		max_chunk_bytes = chunk_cap,
		max_body_bytes  = i64(GZIP_MAX_OUTPUT),
		timeout         = state.inner.timeout,
	}

	return true
}

coding_stream_detach :: proc(response: ^Response) {
	state := cast(^Coding_Stream)response.stream.data
	response.stream = state.inner
	state.inner = {}
	coding_stream_free(state)
}

// A strong validator names exact bytes, and the coded body is a different
// representation. Weakening keeps If-None-Match (weak comparison) working across
// codings without claiming byte equality. Headers must already be request-owned.
weaken_etag :: proc(request: ^Request, headers: []Header) {
	for &header in headers {
		if !strings.equal_fold(header.name, "ETag") || strings.has_prefix(header.value, "W/") {
			continue
		}

		weak, error := strings.concatenate({"W/", header.value}, request.allocator)

		if error == nil {
			header.value = weak
		}

		return
	}
}

// Applies after the handler returns. Buffered bodies keep identity unless the
// coded body is strictly smaller. Eligible streams become one coded body with
// chunked framing. HEAD advertises that framing and does not poll or allocate an
// encoder. Responses marked `uncoded` (prepared representations) are final.
content_coding_prepare :: proc(request: ^Request, response: ^Response) {
	if request == nil || response == nil || request.allocator.procedure == nil || response.uncoded {
		return
	}
	streaming := stream_present(response.stream)
	if streaming && len(response.body) != 0 {
		return
	}
	plain := len(response.body)

	if streaming {
		if response.stream.content_length < 0 || response.stream.content_length > i64(GZIP_MAX_INPUT) {
			return
		}
		plain = int(response.stream.content_length)
	}

	if !coding_eligible(response^, plain) || !header_room(response.headers) {
		return
	}
	choice := parse_accept_encoding(request.headers)
	if !choice.present || !choice.valid {
		return
	}
	coding := negotiate_coding(choice)
	encoded: []u8
	attached := false
	head := streaming && strings.equal_fold(request.method, "HEAD")

	if coding != .Identity && streaming && !head {
		attached = coding_stream_attach(request, response, coding)
		if !attached {
			coding = .Identity
		}
	}

	if coding != .Identity && !streaming {
		if coding == .Brotli {
			encoded = brotli_compress(response.body, request.allocator)
		} else {
			encoded = gzip_compress(response.body, request.allocator)
		}

		if encoded == nil {
			coding = .Identity
		}
	}

	extra: [2]Header
	count := 0
	// Eligible bytes can differ for another Accept-Encoding, including identity.
	if !vary_lists_encoding(response.headers) {
		extra[count] = {"Vary", "Accept-Encoding"}
		count += 1
	}

	if coding != .Identity {
		extra[count] = {"Content-Encoding", content_coding_token(coding)}
		count += 1
	}

	if count == 0 {
		if encoded != nil {
			response.body = encoded
		}
		return
	}

	if !append_response_headers(request, response, extra[:count]) {
		delete(encoded, request.allocator)
		if attached {
			coding_stream_detach(response)
		}
		return
	}

	if encoded != nil {
		response.body = encoded
	}
	if coding != .Identity {
		weaken_etag(request, response.headers)
	}
	if coding != .Identity && head {
		response.stream.content_length = -1
	}
}
