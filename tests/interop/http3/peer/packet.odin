package saba_test_h3_peer

import ngtcp2 "../../../support/c/ngtcp2"
import "core:c"

// QUIC packets a suite builds or reads itself, next to the genuine ones
// ngtcp2 writes (RFC 9000 section 17, RFC 9001 section 5). The keys come from
// the same places ngtcp2's do: Initial keys from the client's first
// Destination Connection ID, Handshake keys from the TLS secrets the keylog
// reported. Header protection is AES-ECB, so a suite that opens or builds
// Handshake packets offers only AES-GCM cipher suites.

INITIAL_SALT_V1 := [20]u8 {
	0x38,
	0x76,
	0x2c,
	0xf7,
	0xf5,
	0x59,
	0x34,
	0xb3,
	0x4d,
	0x17,
	0x9a,
	0xe6,
	0xa4,
	0xc8,
	0x0c,
	0xad,
	0xcc,
	0xbb,
	0x7f,
	0x0a,
}
TAG_LENGTH :: 16

Packet_Type :: enum {
	Initial,
	Zero_RTT,
	Handshake,
	Retry,
	Short,
	Version_Negotiation,
}

Packet :: struct {
	type:      Packet_Type,
	version:   u32,
	dcid:      []u8,
	scid:      []u8,
	// The whole packet, within the datagram it came in.
	bytes:     []u8,
	// Where the (protected) packet number starts.
	pn_offset: int,
}

// One direction of one packet number space.
Keys :: struct {
	aead:     ngtcp2.Crypto_Aead,
	aead_ctx: ngtcp2.Crypto_Aead_Ctx,
	iv:       [32]u8,
	ivlen:    int,
	hp:       ^ngtcp2.EVP_CIPHER_CTX,
	sealing:  bool,
	// The largest packet number opened so far, for decoding truncated ones.
	largest:  i64,
	valid:    bool,
}

varint :: proc(out: ^[dynamic]u8, value: u64) {
	switch {
	case value < 1 << 6:
		append(out, u8(value))
	case value < 1 << 14:
		append(out, u8(value >> 8) | 0x40, u8(value))
	case value < 1 << 30:
		append(out, u8(value >> 24) | 0x80, u8(value >> 16), u8(value >> 8), u8(value))
	case:
		append(out, u8(value >> 56) | 0xc0, u8(value >> 48), u8(value >> 40), u8(value >> 32))
		append(out, u8(value >> 24), u8(value >> 16), u8(value >> 8), u8(value))
	}
}

read_varint :: proc(data: []u8, at: ^int) -> (u64, bool) {
	if at^ >= len(data) {
		return 0, false
	}
	length := 1 << (data[at^] >> 6)
	if at^ + length > len(data) {
		return 0, false
	}
	value := u64(data[at^] & 0x3f)
	for i in 1 ..< length {
		value = value << 8 | u64(data[at^ + i])
	}
	at^ += length
	return value, true
}

// Splits a datagram into its packets. Short header packets take the rest of
// the datagram; their Destination Connection ID is cid_length long.
packets :: proc(datagram: []u8, cid_length: int, allocator := context.temp_allocator) -> []Packet {
	found := make([dynamic]Packet, allocator)
	at := 0
	for at < len(datagram) {
		data := datagram[at:]
		if data[0] & 0x80 == 0 {
			if len(data) < 1 + cid_length {
				break
			}
			append(
				&found,
				Packet {
					type = .Short,
					dcid = data[1:1 + cid_length],
					bytes = data,
					pn_offset = 1 + cid_length,
				},
			)
			break
		}
		if len(data) < 7 {
			break
		}
		p: Packet
		p.version = u32(data[1]) << 24 | u32(data[2]) << 16 | u32(data[3]) << 8 | u32(data[4])
		i := 5
		n := int(data[i])
		i += 1
		if i + n >= len(data) {
			break
		}
		p.dcid = data[i:i + n]
		i += n
		n = int(data[i])
		i += 1
		if i + n > len(data) {
			break
		}
		p.scid = data[i:i + n]
		i += n
		if p.version == 0 {
			p.type = .Version_Negotiation
			p.bytes = data
			append(&found, p)
			break
		}
		p.type = Packet_Type((data[0] >> 4) & 3)
		if p.type == .Retry {
			p.bytes = data
			append(&found, p)
			break
		}
		if p.type == .Initial {
			token, ok := read_varint(data, &i)
			if !ok {
				break
			}
			i += int(token)
		}
		length, ok := read_varint(data, &i)
		if !ok || i + int(length) > len(data) {
			break
		}
		p.pn_offset = i
		p.bytes = data[:i + int(length)]
		append(&found, p)
		at += len(p.bytes)
	}
	return found[:]
}

// Every byte of the datagram is zero from here on: padding outside packets.
only_zeros :: proc(data: []u8) -> bool {
	for b in data {
		if b != 0 {
			return false
		}
	}
	return true
}

hkdf_expand_label :: proc(md: ^ngtcp2.Crypto_Md, secret: []u8, label: string, out: []u8) -> bool {
	info := make([dynamic]u8, context.temp_allocator)
	full := len("tls13 ") + len(label)
	append(&info, u8(len(out) >> 8), u8(len(out)), u8(full))
	append(&info, "tls13 ")
	append(&info, label)
	append(&info, 0)
	return(
		ngtcp2.crypto_hkdf_expand(
			raw_data(out),
			len(out),
			md,
			raw_data(secret),
			len(secret),
			raw_data(info),
			len(info),
		) ==
		0 \
	)
}

keys_from_secret :: proc(
	ctx: ^ngtcp2.Crypto_Ctx,
	secret: []u8,
	sealing: bool,
) -> (
	k: Keys,
	ok: bool,
) {
	k.aead = ctx.aead
	k.sealing = sealing
	k.largest = -1
	keylen := int(ngtcp2.crypto_aead_keylen(&ctx.aead))
	k.ivlen = int(ngtcp2.crypto_packet_protection_ivlen(&ctx.aead))
	if keylen != 16 || k.ivlen > len(k.iv) {
		// Only AES-128 header protection is implemented.
		return k, false
	}
	key, hp: [16]u8
	if !hkdf_expand_label(&ctx.md, secret, "quic key", key[:]) ||
	   !hkdf_expand_label(&ctx.md, secret, "quic iv", k.iv[:k.ivlen]) ||
	   !hkdf_expand_label(&ctx.md, secret, "quic hp", hp[:]) {
		return k, false
	}
	init := ngtcp2.crypto_aead_ctx_encrypt_init if sealing else ngtcp2.crypto_aead_ctx_decrypt_init
	if init(&k.aead_ctx, &k.aead, raw_data(key[:]), c.size_t(k.ivlen)) != 0 {
		return k, false
	}
	k.hp = ngtcp2.EVP_CIPHER_CTX_new()
	if ngtcp2.EVP_EncryptInit_ex(k.hp, ngtcp2.EVP_aes_128_ecb(), nil, raw_data(hp[:]), nil) != 1 {
		ngtcp2.crypto_aead_ctx_free(&k.aead_ctx)
		ngtcp2.EVP_CIPHER_CTX_free(k.hp)
		return k, false
	}
	k.valid = true
	return k, true
}

keys_destroy :: proc(k: ^Keys) {
	if k.valid {
		ngtcp2.crypto_aead_ctx_free(&k.aead_ctx)
		ngtcp2.EVP_CIPHER_CTX_free(k.hp)
	}
	k^ = {}
}

// The Initial keys of one side (server: what the server seals with).
initial_keys :: proc(cl: ^Client, server, sealing: bool) -> (Keys, bool) {
	ctx := &cl.initial_ctx
	initial: [32]u8
	salt := INITIAL_SALT_V1
	if ngtcp2.crypto_hkdf_extract(
		   raw_data(initial[:]),
		   &ctx.md,
		   raw_data(cl.dcid.data[:]),
		   cl.dcid.datalen,
		   raw_data(salt[:]),
		   len(salt),
	   ) !=
	   0 {
		return {}, false
	}
	secret: [32]u8
	if !hkdf_expand_label(&ctx.md, initial[:], "server in" if server else "client in", secret[:]) {
		return {}, false
	}
	return keys_from_secret(ctx, secret[:], sealing)
}

// The Handshake keys of one side, once the keylog reported its secret.
handshake_keys :: proc(cl: ^Client, server, sealing: bool) -> (Keys, bool) {
	secret := cl.secrets.server_handshake[:] if server else cl.secrets.client_handshake[:]
	if len(secret) == 0 {
		return {}, false
	}
	ctx: ngtcp2.Crypto_Ctx
	if ngtcp2.crypto_ctx_tls(&ctx, cl.ossl) == nil {
		return {}, false
	}
	return keys_from_secret(&ctx, secret, sealing)
}

nonce :: proc(k: ^Keys, pn: u64) -> [32]u8 {
	n := k.iv
	for i in 0 ..< 8 {
		n[k.ivlen - 1 - i] ~= u8(pn >> (8 * uint(i)))
	}
	return n
}

mask :: proc(k: ^Keys, sample: []u8) -> [16]u8 {
	out: [32]u8
	length: c.int
	ngtcp2.EVP_EncryptUpdate(k.hp, raw_data(out[:]), &length, raw_data(sample), 16)
	result: [16]u8
	copy(result[:], out[:16])
	return result
}

// A protected long header packet with a 4-byte packet number. The payload is
// sealed as it is: a suite pads it itself when it must.
protect :: proc(
	k: ^Keys,
	type: Packet_Type,
	dcid, scid: []u8,
	pn: u64,
	payload: []u8,
	allocator := context.temp_allocator,
) -> []u8 {
	header := make([dynamic]u8, allocator)
	append(&header, 0xc0 | u8(type) << 4 | 3)
	append(&header, 0, 0, 0, 1)
	append(&header, u8(len(dcid)))
	append(&header, ..dcid)
	append(&header, u8(len(scid)))
	append(&header, ..scid)
	if type == .Initial {
		append(&header, 0)
	}
	varint(&header, u64(4 + len(payload) + TAG_LENGTH))
	pn_offset := len(header)
	append(&header, u8(pn >> 24), u8(pn >> 16), u8(pn >> 8), u8(pn))
	packet := make([]u8, len(header) + len(payload) + TAG_LENGTH, allocator)
	copy(packet, header[:])
	n := nonce(k, pn)
	ngtcp2.crypto_encrypt(
		raw_data(packet[len(header):]),
		&k.aead,
		&k.aead_ctx,
		raw_data(payload),
		len(payload),
		raw_data(n[:]),
		c.size_t(k.ivlen),
		raw_data(header[:]),
		len(header),
	)
	m := mask(k, packet[pn_offset + 4:pn_offset + 20])
	packet[0] ~= m[0] & 0x0f
	for i in 0 ..< 4 {
		packet[pn_offset + i] ~= m[1 + i]
	}
	return packet
}

// Removes the protection of a long header packet: its packet number and
// payload, or false when it does not open with these keys.
open :: proc(
	k: ^Keys,
	p: Packet,
	allocator := context.temp_allocator,
) -> (
	pn: u64,
	payload: []u8,
	ok: bool,
) {
	if p.pn_offset + 20 > len(p.bytes) {
		return
	}
	packet := make([]u8, len(p.bytes), allocator)
	copy(packet, p.bytes)
	m := mask(k, packet[p.pn_offset + 4:p.pn_offset + 20])
	packet[0] ~= m[0] & (0x0f if packet[0] & 0x80 != 0 else 0x1f)
	length := int(packet[0] & 3) + 1
	truncated: u64
	for i in 0 ..< length {
		packet[p.pn_offset + i] ~= m[1 + i]
		truncated = truncated << 8 | u64(packet[p.pn_offset + i])
	}
	pn = decode_packet_number(k.largest, truncated, uint(length) * 8)
	header := packet[:p.pn_offset + length]
	sealed := packet[p.pn_offset + length:]
	if len(sealed) < TAG_LENGTH {
		return
	}
	plain := make([]u8, len(sealed) - TAG_LENGTH, allocator)
	n := nonce(k, pn)
	if ngtcp2.crypto_decrypt(
		   raw_data(plain),
		   &k.aead,
		   &k.aead_ctx,
		   raw_data(sealed),
		   len(sealed),
		   raw_data(n[:]),
		   c.size_t(k.ivlen),
		   raw_data(header),
		   len(header),
	   ) !=
	   0 {
		return
	}
	k.largest = max(k.largest, i64(pn))
	return pn, plain, true
}

// RFC 9000 appendix A.3.
decode_packet_number :: proc(largest: i64, truncated: u64, bits: uint) -> u64 {
	expected := u64(largest + 1)
	window := u64(1) << bits
	half := window / 2
	candidate := (expected & ~(window - 1)) | truncated
	if candidate + half <= expected && candidate < (1 << 62) - window {
		return candidate + window
	}
	if candidate > expected + half && candidate >= window {
		return candidate - window
	}
	return candidate
}

Frame_Kind :: enum {
	Padding,
	Ping,
	Ack,
	Crypto,
	Close,
	Other,
}

Frame :: struct {
	kind:   Frame_Kind,
	type:   u64,
	// The frame as it was encoded.
	raw:    []u8,
	// ACK: the acknowledged ranges, largest first ([2]u64{low, high}), the
	// ACK Delay field and, for type 0x03, the ECN counts.
	ranges: [dynamic][2]u64,
	delay:  u64,
	ecn:    [3]u64,
	// CRYPTO: offset and data.
	offset: u64,
	data:   []u8,
	// CONNECTION_CLOSE: the error code.
	code:   u64,
}

// The frames of an Initial or Handshake payload. A frame type these spaces do
// not allow stops the walk with ok false.
frames :: proc(
	payload: []u8,
	allocator := context.temp_allocator,
) -> (
	found: [dynamic]Frame,
	ok: bool,
) {
	found = make([dynamic]Frame, allocator)
	at := 0
	for at < len(payload) {
		f: Frame
		start := at
		f.type = read_varint(payload, &at) or_return
		switch f.type {
		case 0x00:
			f.kind = .Padding
		case 0x01:
			f.kind = .Ping
		case 0x02, 0x03:
			f.kind = .Ack
			f.ranges = make([dynamic][2]u64, allocator)
			high := read_varint(payload, &at) or_return
			f.delay = read_varint(payload, &at) or_return
			count := read_varint(payload, &at) or_return
			first := read_varint(payload, &at) or_return
			if first > high {
				return found, false
			}
			low := high - first
			append(&f.ranges, [2]u64{low, high})
			for _ in 0 ..< count {
				gap := read_varint(payload, &at) or_return
				length := read_varint(payload, &at) or_return
				if gap + 2 > low || length > low - gap - 2 {
					return found, false
				}
				high = low - gap - 2
				low = high - length
				append(&f.ranges, [2]u64{low, high})
			}
			if f.type == 0x03 {
				for i in 0 ..< 3 {
					f.ecn[i] = read_varint(payload, &at) or_return
				}
			}
		case 0x06:
			f.kind = .Crypto
			f.offset = read_varint(payload, &at) or_return
			length := read_varint(payload, &at) or_return
			if at + int(length) > len(payload) {
				return found, false
			}
			f.data = payload[at:at + int(length)]
			at += int(length)
		case 0x1c, 0x1d:
			f.kind = .Close
			f.code = read_varint(payload, &at) or_return
			if f.type == 0x1c {
				read_varint(payload, &at) or_return
			}
			reason := read_varint(payload, &at) or_return
			if at + int(reason) > len(payload) {
				return found, false
			}
			at += int(reason)
		case:
			f.kind = .Other
			append(&found, f)
			return found, false
		}
		f.raw = payload[start:at]
		append(&found, f)
	}
	return found, true
}

acknowledges :: proc(f: Frame, pn: u64) -> bool {
	for r in f.ranges {
		if r[0] <= pn && pn <= r[1] {
			return true
		}
	}
	return false
}

// An ACK frame for ranges (largest first, not adjacent).
ack_frame :: proc(out: ^[dynamic]u8, f: Frame, ranges: [][2]u64) {
	varint(out, f.type)
	varint(out, ranges[0][1])
	varint(out, f.delay)
	varint(out, u64(len(ranges) - 1))
	varint(out, ranges[0][1] - ranges[0][0])
	for i in 1 ..< len(ranges) {
		varint(out, ranges[i - 1][0] - ranges[i][1] - 2)
		varint(out, ranges[i][1] - ranges[i][0])
	}
	if f.type == 0x03 {
		for count in f.ecn {
			varint(out, count)
		}
	}
}

// The payload with pn taken out of every ACK frame (a frame left with nothing
// to acknowledge is dropped), padded back to its length. False when no frame
// acknowledged pn.
unacknowledge :: proc(
	payload: []u8,
	pn: u64,
	allocator := context.temp_allocator,
) -> (
	out: []u8,
	changed: bool,
) {
	found, ok := frames(payload, allocator)
	if !ok {
		return payload, false
	}
	rebuilt := make([dynamic]u8, allocator)
	for f in found {
		if f.kind != .Ack || !acknowledges(f, pn) {
			append(&rebuilt, ..f.raw)
			continue
		}
		changed = true
		ranges := make([dynamic][2]u64, allocator)
		for r in f.ranges {
			if r[0] <= pn && pn <= r[1] {
				if pn < r[1] {
					append(&ranges, [2]u64{pn + 1, r[1]})
				}
				if r[0] < pn {
					append(&ranges, [2]u64{r[0], pn - 1})
				}
			} else {
				append(&ranges, r)
			}
		}
		if len(ranges) > 0 {
			ack_frame(&rebuilt, f, ranges[:])
		}
	}
	for len(rebuilt) < len(payload) {
		append(&rebuilt, 0)
	}
	return rebuilt[:], changed
}
