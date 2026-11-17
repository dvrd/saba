package saba_core

import exchange "../../http/exchange"
import rt "base:runtime"
import "core:hash"
import "core:math/bits"
import "core:mem"
import owned "core:mem/owned"
import "core:strings"

// Identity is always acceptable. Gzip is the only other coding. x-gzip is an alias.
// Absent or malformed Accept-Encoding stays identity and does not add Vary.
@(private)
GZIP_MIN_BYTES :: 1024
@(private)
GZIP_MAX_INPUT :: 1 << 20
@(private)
GZIP_MAX_OUTPUT :: (1 << 20) + (1 << 18)
@(private)
GZIP_PROBE_LIMIT :: 8
@(private)
GZIP_WINDOW :: 32768
@(private)
GZIP_HASH_BITS :: 12

@(private)
GZIP_LEN_BASE := [29]int {
	3,
	4,
	5,
	6,
	7,
	8,
	9,
	10,
	11,
	13,
	15,
	17,
	19,
	23,
	27,
	31,
	35,
	43,
	51,
	59,
	67,
	83,
	99,
	115,
	131,
	163,
	195,
	227,
	258,
}
@(private)
GZIP_LEN_EXTRA := [29]int{0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0}
@(private)
GZIP_DIST_BASE := [30]int {
	1,
	2,
	3,
	4,
	5,
	7,
	9,
	13,
	17,
	25,
	33,
	49,
	65,
	97,
	129,
	193,
	257,
	385,
	513,
	769,
	1025,
	1537,
	2049,
	3073,
	4097,
	6145,
	8193,
	12289,
	16385,
	24577,
}
@(private)
GZIP_DIST_EXTRA := [30]int {
	0,
	0,
	0,
	0,
	1,
	1,
	2,
	2,
	3,
	3,
	4,
	4,
	5,
	5,
	6,
	6,
	7,
	7,
	8,
	8,
	9,
	9,
	10,
	10,
	11,
	11,
	12,
	12,
	13,
	13,
}

// One final fixed-Huffman deflate block. State is about 184 KiB plus the caller's chunk.
@(private)
Gzip_Encoder :: struct {
	window:                                        [GZIP_WINDOW]u8,
	head:                                          [1 << GZIP_HASH_BITS]i32,
	prev:                                          [GZIP_WINDOW]i32,
	out:                                           [8192]u8,
	out_len, out_off, pos, total, produced, nbits: int,
	bits:                                          u32,
	crc:                                           u32,
	opened, finished, overflow:                    bool,
}

@(private)
gzip_output_bound :: proc(n: int) -> int {
	if n < 0 do return 0

	return 20 + (n * 9 + 7) / 8
}

@(private)
gzip_encoder_reset :: proc(e: ^Gzip_Encoder) {
	mem.set(raw_data(e.head[:]), 0xff, size_of(e.head))
}

@(private)
gzip_byte :: proc(e: ^Gzip_Encoder, value: u8) {
	if e.overflow do return

	if e.produced >= GZIP_MAX_OUTPUT || e.out_len >= len(e.out) {
		e.overflow = true
		return
	}

	e.out[e.out_len] = value
	e.out_len += 1
	e.produced += 1
}

@(private)
gzip_put :: proc(e: ^Gzip_Encoder, value: u32, count: int) {
	if count <= 0 do return
	mask := (u32(1) << uint(count)) - 1
	e.bits |= (value & mask) << uint(e.nbits)
	e.nbits += count

	for e.nbits >= 8 {
		gzip_byte(e, u8(e.bits))
		e.bits >>= 8
		e.nbits -= 8
	}
}

@(private)
gzip_rev :: proc(code: u32, count: int) -> u32 {
	return bits.reverse_bits(code) >> uint(32 - count)
}

@(private)
gzip_huff :: proc(symbol: int) -> (u32, int) {
	switch {
	case symbol <= 143:
		return u32(0x30 + symbol), 8
	case symbol <= 255:
		return u32(0x190 + symbol - 144), 9
	case symbol <= 279:
		return u32(symbol - 256), 7
	}

	return u32(0xc0 + symbol - 280), 8
}

@(private)
gzip_symbol :: proc(e: ^Gzip_Encoder, symbol: int) {
	code, count := gzip_huff(symbol)
	gzip_put(e, gzip_rev(code, count), count)
}

@(private)
gzip_open :: proc(e: ^Gzip_Encoder) {
	if e.opened do return

	for value in ([10]u8{0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0xff}) {
		gzip_byte(e, value)
	}

	gzip_put(e, 3, 3) // Final fixed-Huffman block.
	e.opened = true
}

@(private)
gzip_match :: proc(e: ^Gzip_Encoder, length, distance: int) {
	for index := 28; index >= 0; index -= 1 {
		if length >= GZIP_LEN_BASE[index] {
			gzip_symbol(e, 257 + index)
			extra := GZIP_LEN_EXTRA[index]
			if extra > 0 do gzip_put(e, u32(length - GZIP_LEN_BASE[index]), extra)
			break
		}
	}

	for index := 29; index >= 0; index -= 1 {
		if distance >= GZIP_DIST_BASE[index] {
			gzip_put(e, gzip_rev(u32(index), 5), 5)
			extra := GZIP_DIST_EXTRA[index]
			if extra > 0 do gzip_put(e, u32(distance - GZIP_DIST_BASE[index]), extra)
			return
		}
	}

	e.overflow = true
}

@(private)
gzip_hash :: proc(a, b, c: u8) -> int {
	value := (u32(a) | u32(b) << 8 | u32(c) << 16) * 0x1e35a7bd

	return int(value >> (32 - GZIP_HASH_BITS))
}

@(private)
gzip_source :: proc(e: ^Gzip_Encoder, abs, base: int, src: []u8) -> u8 {
	if abs >= base do return src[abs - base]

	return e.window[abs & (GZIP_WINDOW - 1)]
}

// Consumes a prefix. A full emission buffer stops progress without failing.
@(private)
gzip_write :: proc(e: ^Gzip_Encoder, src: []u8) -> int {
	if e.finished || e.overflow || len(src) == 0 do return 0
	gzip_open(e)
	if e.overflow do return 0
	base, consumed := e.pos, 0

	for consumed < len(src) {
		if len(e.out) - e.out_len < 16 do break
		current := base + consumed
		best_length, best_distance := 0, 0

		if consumed + 2 < len(src) {
			hash := gzip_hash(src[consumed], src[consumed + 1], src[consumed + 2])
			candidate := int(e.head[hash])

			for _ in 0 ..< GZIP_PROBE_LIMIT {
				if candidate < 0 do break
				distance := current - candidate
				if distance <= 0 || distance > GZIP_WINDOW do break
				limit := min(258, len(src) - consumed)
				length := 0

				for length < limit {
					if gzip_source(e, candidate + length, base, src) != src[consumed + length] do break
					length += 1
				}

				if length > best_length {
					best_length, best_distance = length, distance
				}

				next := int(e.prev[candidate & (GZIP_WINDOW - 1)])
				if next >= candidate do break
				candidate = next
			}

			slot := current & (GZIP_WINDOW - 1)
			e.prev[slot] = e.head[hash]
			e.head[hash] = i32(current)
		}

		if best_length >= 3 {
			gzip_match(e, best_length, best_distance)

			for offset in 1 ..< best_length {
				at := current + offset
				e.window[at & (GZIP_WINDOW - 1)] = src[consumed + offset]

				if consumed + offset + 2 < len(src) {
					hash := gzip_hash(src[consumed + offset], src[consumed + offset + 1], src[consumed + offset + 2])
					index := at & (GZIP_WINDOW - 1)
					e.prev[index] = e.head[hash]
					e.head[hash] = i32(at)
				}
			}

			e.window[current & (GZIP_WINDOW - 1)] = src[consumed]
			consumed += best_length
		} else {
			gzip_symbol(e, int(src[consumed]))
			e.window[current & (GZIP_WINDOW - 1)] = src[consumed]
			consumed += 1
		}

		if e.overflow do return 0
	}

	if consumed > 0 {
		e.crc = hash.crc32(src[:consumed], e.crc)
		e.total += consumed
		e.pos += consumed
	}

	return consumed
}

@(private)
gzip_finish :: proc(e: ^Gzip_Encoder) -> bool {
	if e.finished do return true
	if e.overflow || len(e.out) - e.out_len < 24 do return false
	gzip_open(e)
	gzip_symbol(e, 256)

	if e.nbits > 0 {
		gzip_byte(e, u8(e.bits))
		e.bits, e.nbits = 0, 0
	}

	crc, size := e.crc, u32(e.total)
	for shift in ([4]u32{0, 8, 16, 24}) do gzip_byte(e, u8(crc >> shift))
	for shift in ([4]u32{0, 8, 16, 24}) do gzip_byte(e, u8(size >> shift))
	e.finished = !e.overflow

	return e.finished
}

@(private)
gzip_pull :: proc(e: ^Gzip_Encoder, dst: []u8) -> int {
	available := e.out_len - e.out_off
	count := min(len(dst), available)
	if count <= 0 do return 0
	copy(dst[:count], e.out[e.out_off:][:count])
	remain := e.out_len - (e.out_off + count)
	if remain > 0 do copy(e.out[:remain], e.out[e.out_off + count:][:remain])
	e.out_len, e.out_off = remain, 0

	return count
}

@(private)
gzip_encode_into :: proc(e: ^Gzip_Encoder, src, dst: []u8) -> (written: int, ok: bool) {
	offset := 0

	for offset < len(src) {
		if e.overflow do return 0, false

		if len(e.out) - e.out_len < 32 {
			count := gzip_pull(e, dst[written:])
			if count == 0 do return 0, false
			written += count
			continue
		}

		count := gzip_write(e, src[offset:])
		if count <= 0 do return 0, false
		offset += count
	}

	for !e.finished {
		if e.overflow do return 0, false

		if len(e.out) - e.out_len < 32 {
			count := gzip_pull(e, dst[written:])
			if count == 0 do return 0, false
			written += count
			continue
		}

		gzip_finish(e)
	}

	for e.out_len != e.out_off {
		count := gzip_pull(e, dst[written:])
		if count == 0 do return 0, false
		written += count
	}

	return written, !e.overflow
}

@(private)
gzip_compress :: proc(src: []u8, allocator: mem.Allocator) -> []u8 {
	// Scratch is heap-owned so a request arena, which cannot free individuals, is
	// only charged the exact encoded body.
	bound := gzip_output_bound(len(src))
	scratch := rt.heap_allocator()
	if bound <= 0 || bound > GZIP_MAX_OUTPUT || allocator.procedure == nil do return nil
	encoder, alloc_error := new(Gzip_Encoder, scratch)
	if alloc_error != nil || encoder == nil do return nil
	defer free(encoder, scratch)
	gzip_encoder_reset(encoder)
	staged, stage_error := make([]u8, bound, scratch)
	if stage_error != nil do return nil
	defer delete(staged, scratch)
	written, ok := gzip_encode_into(encoder, src, staged)
	if !ok || written <= 0 || written >= len(src) do return nil
	exact, exact_error := make([]u8, written, allocator)
	if exact_error != nil do return nil
	copy(exact, staged[:written])

	return exact
}

@(private)
is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}
@(private)
is_alpha :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}
// HTTP optional whitespace.
@(private)
is_blank :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t'
}

// Index of the next list element: skips optional whitespace and empty elements.
@(private)
skip_list_separators :: proc(value: string, from: int) -> int {
	index := from

	for index < len(value) && (is_blank(value[index]) || value[index] == ',') {
		index += 1
	}

	return index
}

@(private)
Coding_Choice :: struct {
	gzip, identity, star: int,
	present, valid:       bool,
}

@(private)
coding_token :: proc(value: u8) -> bool {
	if is_digit(value) || is_alpha(value) do return true

	switch value {
	case '!', '#', '$', '%', '&', '\'', '+', '-', '.', '^', '_', '`', '|', '~':
		return true
	}

	return false
}

@(private)
parse_qvalue :: proc(value: string) -> (q, next: int, ok: bool) {
	if len(value) == 0 do return
	index := 0

	if value[0] == '1' {
		q = 1000
		index = 1

		if index < len(value) && value[index] == '.' {
			index += 1
			digits := 0

			for digits < 3 && index < len(value) && is_digit(value[index]) {
				if value[index] != '0' do return
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

	if index < len(value) && is_digit(value[index]) do return

	return q, index, true
}

@(private)
accept_coding :: proc(choice: ^Coding_Choice, name: string, q: int) {
	if name == "*" {
		if choice.star < 0 do choice.star = q
		return
	}

	if strings.equal_fold(name, "gzip") || strings.equal_fold(name, "x-gzip") {
		if choice.gzip < 0 do choice.gzip = q
		return
	}

	if strings.equal_fold(name, "identity") && choice.identity < 0 do choice.identity = q
}

@(private)
parse_coding_list :: proc(value: string, choice: ^Coding_Choice) -> bool {
	index := 0

	for index < len(value) {
		index = skip_list_separators(value, index)
		if index >= len(value) do return true
		start := index

		if value[index] == '*' {
			index += 1
		} else {
			for index < len(value) && coding_token(value[index]) do index += 1
			if index == start do return false
		}

		name := value[start:index]
		quality := 1000
		cursor := index
		for cursor < len(value) && is_blank(value[cursor]) do cursor += 1

		if cursor < len(value) && value[cursor] == ';' {
			cursor += 1
			for cursor < len(value) && is_blank(value[cursor]) do cursor += 1

			if cursor + 1 >= len(value) || (value[cursor] != 'q' && value[cursor] != 'Q') || value[cursor + 1] != '=' {
				return false
			}

			parsed, consumed, ok := parse_qvalue(value[cursor + 2:])
			if !ok do return false
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

@(private)
parse_accept_encoding :: proc(headers: []Header) -> Coding_Choice {
	choice := Coding_Choice {
		gzip     = -1,
		identity = -1,
		star     = -1,
		valid    = true,
	}

	for header in headers {
		if !strings.equal_fold(header.name, "Accept-Encoding") do continue
		choice.present = true

		if !parse_coding_list(header.value, &choice) {
			return Coding_Choice{}
		}
	}

	return choice
}

@(private)
gzip_preferred :: proc(choice: Coding_Choice) -> bool {
	quality := choice.gzip

	if quality < 0 {
		if choice.star >= 0 do quality = choice.star
		else do quality = 0
	}

	if quality <= 0 do return false

	return choice.identity < 0 || choice.identity <= quality
}

@(private)
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

		for index < len(value) && value[index] != ',' do index += 1
	}

	return false
}

@(private)
compressible_type :: proc(value: string) -> bool {
	start := 0
	for start < len(value) && is_blank(value[start]) do start += 1
	end := start
	for end < len(value) && value[end] != ';' && !is_blank(value[end]) do end += 1
	media := value[start:end]
	if len(media) >= 5 && strings.equal_fold(media[:5], "text/") do return true
	if strings.equal_fold(media, "image/svg+xml") do return true
	if strings.equal_fold(media, "application/javascript") do return true
	if strings.equal_fold(media, "application/json") do return true
	if strings.equal_fold(media, "application/xml") do return true
	if strings.equal_fold(media, "application/xhtml+xml") do return true
	if len(media) >= 5 && strings.equal_fold(media[len(media) - 5:], "+json") do return true
	if len(media) >= 4 && strings.equal_fold(media[len(media) - 4:], "+xml") do return true

	return false
}

@(private)
coding_eligible :: proc(response: Response, plain: int) -> bool {
	status := int(response.status)
	if status == 0 do status = 200
	if status < 200 || status == 204 || status == 206 || status == 304 do return false

	if plain < GZIP_MIN_BYTES || plain > GZIP_MAX_INPUT || gzip_output_bound(plain) > GZIP_MAX_OUTPUT {
		return false
	}

	typed := false
	compressible := false

	for header in response.headers {
		if strings.equal_fold(header.name, "Content-Encoding") || strings.equal_fold(header.name, "Content-Range") {
			return false
		}

		if strings.equal_fold(header.name, "Cache-Control") && cache_forbids_coding(header.value) do return false

		if !typed && strings.equal_fold(header.name, "Content-Type") {
			typed = true
			compressible = compressible_type(header.value)
		}
	}

	return typed && compressible
}

@(private)
header_room :: proc(headers: []Header) -> bool {
	used := 96

	for header in headers {
		used += len(header.name) + len(header.value) + 4
		if used > 7000 do return false
	}

	return true
}

@(private)
vary_lists_encoding :: proc(headers: []Header) -> bool {
	for header in headers {
		if !strings.equal_fold(header.name, "Vary") do continue
		index := 0
		value := header.value

		for index < len(value) {
			index = skip_list_separators(value, index)
			start := index

			for index < len(value) && value[index] != ',' && !is_blank(value[index]) {
				index += 1
			}

			token := value[start:index]
			if token == "*" || strings.equal_fold(token, "Accept-Encoding") do return true
		}
	}

	return false
}

@(private)
append_response_headers :: proc(request: ^Request, response: ^Response, extra: []Header) -> bool {
	if request.allocator.procedure == nil do return false
	stored, err := make([]Header, len(response.headers) + len(extra), request.allocator)
	if err != nil do return false
	copy(stored, response.headers)
	copy(stored[len(response.headers):], extra)
	response.headers = stored

	return true
}

@(private)
Gzip_Stream :: struct {
	allocator:                      mem.Allocator,
	inner:                          Response_Stream,
	side:                           exchange.Exchange,
	encoder:                        Gzip_Encoder,
	held:                           []u8,
	wire:                           []u8,
	held_off, wire_len:             int,
	have, inner_done, busy, failed: bool,
}

@(private)
gzip_stream_free :: proc(state: ^Gzip_Stream) {
	if state == nil do return
	exchange.destroy(&state.side)
	delete(state.wire, state.allocator)
	free(state, state.allocator)
}

@(private)
gzip_drop :: proc(data: rawptr) {
	state := cast(^Gzip_Stream)data
	if state == nil do return
	inner := state.inner
	state.inner = {}
	gzip_stream_free(state)
	if inner.drop != nil do inner.drop(inner.data)
}

@(private)
gzip_fail :: proc(state: ^Gzip_Stream) -> Stream_Step {
	state.failed = true

	return .Failed
}

@(private)
gzip_next :: proc(data: rawptr, io: ^Stream_IO) -> Stream_Step {
	state := cast(^Gzip_Stream)data
	if state == nil || io == nil || state.failed || state.busy do return .Failed

	for _ in 0 ..< 8 {
		if state.wire_len == 0 do state.wire_len = gzip_pull(&state.encoder, state.wire)

		if state.wire_len > 0 {
			chunk := owned.Chunk {
				data      = state.wire[:state.wire_len],
				storage   = state.wire,
				release   = gzip_wire_release,
				user_data = state,
			}

			state.busy = true
			state.wire_len = 0

			if stream_submit(io, &chunk) != .Accepted {
				state.busy = false
				return gzip_fail(state)
			}

			return .Chunk
		}

		if state.encoder.finished do return .Done

		if state.have && state.held_off < len(state.held) {
			count := gzip_write(&state.encoder, state.held[state.held_off:])

			if count <= 0 {
				if state.encoder.overflow || len(state.encoder.out) - state.encoder.out_len >= 16 {
					return gzip_fail(state)
				}

				continue
			}

			state.held_off += count
			continue
		}

		if state.have {
			if !exchange.release_body(&state.side) do return gzip_fail(state)
			state.have, state.held, state.held_off = false, nil, 0
		}

		if state.inner_done {
			gzip_finish(&state.encoder)

			if state.encoder.overflow {
				return gzip_fail(state)
			}

			continue
		}

		capture := io^
		capture._exchange = &state.side
		capture._submitted = false
		capture._waiting = false
		step := state.inner.next(state.inner.data, &capture)
		if capture._waiting do io._waiting = true

		switch step {
		case .Waiting:
			if !io._waiting || capture._submitted do return gzip_fail(state)
			return .Waiting
		case .Yield:
			if io._waiting || capture._submitted do return gzip_fail(state)
			return .Yield
		case .Failed:
			return gzip_fail(state)
		case .Done:
			if capture._submitted || capture._waiting do return gzip_fail(state)
			state.inner_done = true
			if exchange.finish(&state.side).kind != .None do return gzip_fail(state)
		case .Chunk:
			if !capture._submitted || capture._waiting do return gzip_fail(state)
			payload, ok := exchange.body(&state.side)
			if !ok || len(payload) == 0 do return gzip_fail(state)
			state.held, state.held_off, state.have = payload, 0, true
		}
	}

	// One poll stays bounded. The encoder keeps its window, so the next poll continues.
	return .Yield
}

@(private)
gzip_wire_release :: proc(_: []u8, data: rawptr) {
	if data != nil do (cast(^Gzip_Stream)data).busy = false
}

@(private)
gzip_stream_attach :: proc(request: ^Request, response: ^Response) -> bool {
	allocator := request.backing_allocator
	if allocator.procedure == nil do allocator = rt.heap_allocator()
	chunk_cap := response.stream.max_chunk_bytes
	if chunk_cap == 0 do chunk_cap = 64 * 1024
	if chunk_cap < 1 || chunk_cap > mem.Megabyte do return false
	plain := response.stream.content_length
	state, alloc_error := new(Gzip_Stream, allocator)
	if alloc_error != nil || state == nil do return false
	state.allocator = allocator
	state.inner = response.stream
	gzip_encoder_reset(&state.encoder)
	wire, wire_error := make([]u8, chunk_cap, allocator)

	if wire_error != nil {
		free(state, allocator)
		return false
	}

	state.wire = wire
	if exchange.init(&state.side, .GET, {chunk_capacity = 1, max_retained_bytes = chunk_cap, max_body_bytes = plain}, allocator).kind !=
	   .None {
		gzip_stream_free(state)
		return false
	}

	if exchange.respond(&state.side, {status = 200, content_length = plain}).kind != .None {
		gzip_stream_free(state)
		return false
	}

	response.stream = {
		data            = state,
		next            = gzip_next,
		drop            = gzip_drop,
		content_length  = -1,
		max_chunk_bytes = chunk_cap,
		max_body_bytes  = i64(GZIP_MAX_OUTPUT),
		timeout         = state.inner.timeout,
	}

	return true
}

@(private)
gzip_stream_detach :: proc(response: ^Response) {
	state := cast(^Gzip_Stream)response.stream.data
	response.stream = state.inner
	state.inner = {}
	gzip_stream_free(state)
}

// Applies after the handler returns. Buffered bodies keep identity unless gzip is
// strictly smaller. Eligible streams become one gzip member with chunked framing.
// HEAD advertises that framing and does not poll or allocate an encoder.
@(private)
content_coding_prepare :: proc(request: ^Request, response: ^Response) {
	if request == nil || response == nil || request.allocator.procedure == nil do return
	streaming := stream_present(response.stream)
	if streaming && len(response.body) != 0 do return
	plain := len(response.body)

	if streaming {
		if response.stream.content_length < 0 || response.stream.content_length > i64(GZIP_MAX_INPUT) do return
		plain = int(response.stream.content_length)
	}

	if !coding_eligible(response^, plain) || !header_room(response.headers) do return
	choice := parse_accept_encoding(request.headers)
	if !choice.present || !choice.valid do return
	want := gzip_preferred(choice)
	encoded: []u8
	attached := false
	head := streaming && strings.equal_fold(request.method, "HEAD")

	if want && streaming && !head {
		attached = gzip_stream_attach(request, response)
		if !attached do want = false
	}

	if want && !streaming {
		encoded = gzip_compress(response.body, request.allocator)
		if encoded == nil do want = false
	}

	extra: [2]Header
	count := 0
	// Eligible bytes can differ for another Accept-Encoding, including identity.
	if !vary_lists_encoding(response.headers) {
		extra[count] = {"Vary", "Accept-Encoding"}
		count += 1
	}

	if want {
		extra[count] = {"Content-Encoding", "gzip"}
		count += 1
	}

	if count == 0 {
		if encoded != nil do response.body = encoded
		return
	}

	if !append_response_headers(request, response, extra[:count]) {
		delete(encoded, request.allocator)
		if attached do gzip_stream_detach(response)
		return
	}

	if encoded != nil do response.body = encoded
	if want && head do response.stream.content_length = -1
}
