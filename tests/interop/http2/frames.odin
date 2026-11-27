package saba_interop_http2_test

import "core:fmt"
import "core:testing"
import peer "../../support/peer"

// HTTP/2 frames (RFC 9113) and header blocks written by hand, so the peer
// decides every byte Saba reads.

DATA :: 0
HEADERS :: 1
RST_STREAM :: 3
SETTINGS :: 4
PING :: 6
GOAWAY :: 7
WINDOW_UPDATE :: 8

END_STREAM :: 0x1
ACK :: 0x1
END_HEADERS :: 0x4
PADDED :: 0x8

PREFACE :: "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

Frame :: struct {
	kind, flags: u8,
	stream:      u32,
	payload:     []u8,
}

// One HTTP/2 connection and what its peer saw on it. A failed step records
// its reason on t and returns false.
H2 :: struct {
	t:             ^testing.T,
	conn:          ^peer.Conn,
	settings_acks: int,
	ping_acks:     int,
	frames:        int,
}

fail :: proc(h: ^H2, format: string, args: ..any, loc := #caller_location) -> bool {
	testing.expectf(h.t, false, format, ..args, loc = loc)
	return false
}

write_frame :: proc(h: ^H2, kind, flags: u8, stream: u32, payload: []u8 = nil) -> bool {
	wire := make([]u8, 9 + len(payload), context.temp_allocator)
	n := len(payload)
	wire[0], wire[1], wire[2] = u8(n >> 16), u8(n >> 8), u8(n)
	wire[3], wire[4] = kind, flags
	wire[5], wire[6], wire[7], wire[8] = u8(stream >> 24), u8(stream >> 16), u8(stream >> 8), u8(stream)
	copy(wire[9:], payload)
	return peer.write(h.conn, wire)
}

read_frame :: proc(h: ^H2, limit := 1 << 16) -> (Frame, peer.Status) {
	head, status := peer.read_exact(h.conn, 9)
	if status != .Ok {
		return {}, status
	}
	n := int(head[0]) << 16 | int(head[1]) << 8 | int(head[2])
	if n > limit {
		return {}, .Error
	}
	payload: []u8
	payload, status = peer.read_exact(h.conn, n)
	if status != .Ok {
		return {}, status
	}
	stream := u32(head[5]) << 24 | u32(head[6]) << 16 | u32(head[7]) << 8 | u32(head[8])
	return {head[3], head[4], stream & 0x7fffffff, payload}, .Ok
}

be32 :: proc(b: []u8) -> u32 {
	return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3])
}

be16 :: proc(b: []u8) -> u16 {
	return u16(b[0]) << 8 | u16(b[1])
}

u32_bytes :: proc(v: u32) -> []u8 {
	b := make([]u8, 4, context.temp_allocator)
	b[0], b[1], b[2], b[3] = u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)
	return b
}

// Answers what a peer must: SETTINGS and PING are acknowledged, and DATA is
// credited back on its stream and on the connection.
advance :: proc(h: ^H2, f: Frame) -> bool {
	h.frames += 1
	if f.kind == SETTINGS && f.flags & ACK == 0 {
		h.settings_acks += 1
		return write_frame(h, SETTINGS, ACK, 0)
	}
	if f.kind == PING && f.flags & ACK == 0 {
		h.ping_acks += 1
		return write_frame(h, PING, ACK, 0, f.payload)
	}
	if f.kind == DATA && len(f.payload) > 0 {
		credit := u32_bytes(u32(len(f.payload)))
		return write_frame(h, WINDOW_UPDATE, 0, f.stream, credit) && write_frame(h, WINDOW_UPDATE, 0, 0, credit)
	}
	return true
}

// Reads and answers frames until one of kind arrives on stream. A reset of any
// stream fails.
until :: proc(h: ^H2, stream: u32, kind: u8, frames := 4096, loc := #caller_location) -> (Frame, bool) {
	for _ in 0 ..< frames {
		f, status := read_frame(h)
		if status != .Ok {
			return {}, fail(h, "waiting for frame %d on stream %d: %v", kind, stream, status, loc = loc)
		}
		if !advance(h, f) {
			return {}, fail(h, "could not answer frame %d", f.kind, loc = loc)
		}
		if f.kind == RST_STREAM {
			return f, fail(h, "unexpected RST_STREAM on stream %d: %x", f.stream, f.payload, loc = loc)
		}
		if f.stream == stream && f.kind == kind {
			return f, true
		}
	}
	return {}, fail(h, "no frame %d on stream %d", kind, stream, loc = loc)
}

// Reads DATA on stream until want arrived and compares it.
data :: proc(h: ^H2, stream: u32, want: []u8, loc := #caller_location) -> bool {
	got := make([dynamic]u8, context.temp_allocator)
	for len(got) < len(want) {
		f := until(h, stream, DATA, loc = loc) or_return
		append(&got, ..f.payload)
	}
	if string(got[:]) != string(want) {
		return fail(h, "DATA on stream %d: got %x, want %x", stream, got[:], want, loc = loc)
	}
	return true
}

data_string :: proc(h: ^H2, stream: u32, want: string, loc := #caller_location) -> bool {
	return data(h, stream, transmute([]u8)want, loc)
}

// HPACK (RFC 7541) without Huffman coding or the dynamic table.

// A literal field without indexing and with a literal name.
literal :: proc(block: ^[dynamic]u8, name, value: string) {
	append(block, 0, u8(len(name)))
	append(block, ..transmute([]u8)name)
	append(block, u8(len(value)))
	append(block, ..transmute([]u8)value)
}

// A literal field without indexing whose name is static table entry index.
indexed_name :: proc(block: ^[dynamic]u8, index: u8, value: string) {
	append(block, index, u8(len(value)))
	append(block, ..transmute([]u8)value)
}

// An extended CONNECT (RFC 8441) for a chat.v2 WebSocket on path.
connect :: proc(path: string) -> []u8 {
	b := make([dynamic]u8, context.temp_allocator)
	indexed_name(&b, 2, "CONNECT")
	literal(&b, ":protocol", "websocket")
	append(&b, 0x87) // :scheme https
	indexed_name(&b, 1, "synthetic.invalid")
	indexed_name(&b, 4, path)
	literal(&b, "sec-websocket-version", "13")
	literal(&b, "sec-websocket-protocol", "chat.v2")
	literal(&b, "origin", "https://allowed.invalid")
	return b[:]
}

// GET path over https.
get :: proc(path: string) -> []u8 {
	b := make([dynamic]u8, context.temp_allocator)
	append(&b, 0x82, 0x87) // :method GET, :scheme https
	indexed_name(&b, 1, "synthetic.invalid")
	indexed_name(&b, 4, path)
	return b[:]
}

// A masked WebSocket frame (RFC 6455) with a short payload.
masked :: proc(opcode: u8, payload: []u8) -> []u8 {
	assert(len(payload) <= 125, "short fixture only")
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, 0x80 | opcode, 0x80 | u8(len(payload)), 1, 2, 3, 4)
	for v, i in payload {
		append(&out, v ~ out[2 + i % 4])
	}
	return out[:]
}

masked_string :: proc(opcode: u8, payload: string) -> []u8 {
	return masked(opcode, transmute([]u8)payload)
}

// An unmasked server text frame with a short payload.
server_text :: proc(payload: string) -> []u8 {
	return transmute([]u8)fmt.tprintf("\x81%c%s", u8(len(payload)), payload)
}

// Decodes an HPACK integer with an n-bit prefix.
hpack_int :: proc(b: []u8, at: ^int, bits: uint) -> (u64, bool) {
	if at^ >= len(b) {
		return 0, false
	}
	mask := u8(1 << bits - 1)
	n := u64(b[at^] & mask)
	at^ += 1
	if n < u64(mask) {
		return n, true
	}
	shift: uint = 0
	for {
		if at^ >= len(b) || shift > 56 {
			return 0, false
		}
		v := b[at^]
		at^ += 1
		n += u64(v & 127) << shift
		if v & 128 == 0 {
			return n, true
		}
		shift += 7
	}
}

hpack_string :: proc(b: []u8, at: ^int) -> (value: string, huffman: bool, ok: bool) {
	if at^ >= len(b) {
		return
	}
	huffman = b[at^] & 128 != 0
	n := hpack_int(b, at, 7) or_return
	if n > u64(len(b) - at^) {
		return
	}
	value = string(b[at^:at^ + int(n)])
	at^ += int(n)
	return value, huffman, true
}

// Whether a response block (sent to a peer that set a zero header table)
// carries content-length and :status 304. Static indices are decoded; a
// Huffman-coded literal name only counts through its index.
conditional_head_fields :: proc(b: []u8) -> (length, not_modified, ok: bool) {
	for at := 0; at < len(b); {
		first := b[at]
		if first & 128 != 0 {
			index := hpack_int(b, &at, 7) or_return
			length ||= index == 28
			not_modified ||= index == 11
			continue
		}
		if first & 0xe0 == 0x20 {
			_ = hpack_int(b, &at, 5) or_return
			continue
		}
		bits: uint = 6 if first & 0x40 != 0 else 4
		index := hpack_int(b, &at, bits) or_return
		name := ""
		if index == 0 {
			value, huffman := hpack_string(b, &at) or_return
			if !huffman {
				name = value
			}
		}
		_, _ = hpack_string(b, &at) or_return
		length ||= index == 28 || name == "content-length"
	}
	return length, not_modified, true
}
