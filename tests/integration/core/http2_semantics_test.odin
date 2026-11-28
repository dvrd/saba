package saba_core

import "core:sync"
import "core:testing"
import "core:time"
import hpack "shared:async/http/hpack"

// HTTP semantics of the HTTP/2 owner as a hand-framed peer sees them: field
// sections, statuses and refusals, read through the h2w loopback fixture.

// The peer's side of the server's HPACK context, for tests that read more
// than a static-table status. Every HEADERS frame on the connection must pass
// through it, in order.
H2W_Decoder :: struct {
	decoder: hpack.Decoder,
	section: hpack.Field_Section,
}

h2w_decoder_init :: proc(d: ^H2W_Decoder) {
	assert(hpack.decoder_init(&d.decoder, hpack.DEFAULT_LIMITS, 4096, context.allocator).kind == .None)
	assert(hpack.section_init(&d.section, hpack.DEFAULT_LIMITS, context.allocator).kind == .None)
}

h2w_decoder_destroy :: proc(d: ^H2W_Decoder) {
	hpack.section_destroy(&d.section)
	hpack.decoder_destroy(&d.decoder)
}

// The fields of one complete HEADERS frame, valid until the next call.
h2w_decode :: proc(d: ^H2W_Decoder, frame: H2W_Frame) -> ([]hpack.Field, bool) {
	if frame.kind != 1 || frame.flags & 0x4 == 0 {
		return nil, false
	}
	block := frame.payload
	if frame.flags & 0x8 != 0 && len(block) > 0 {
		pad := int(block[0])
		if 1 + pad > len(block) {
			return nil, false
		}
		block = block[1:len(block) - pad]
	}
	if frame.flags & 0x20 != 0 {
		if len(block) < 5 {
			return nil, false
		}
		block = block[5:]
	}
	_ = hpack.section_reset(&d.section)
	if hpack.decoder_begin(&d.decoder, &d.section).kind != .None {
		return nil, false
	}
	for _ in 0 ..< 64 {
		result := hpack.decoder_feed(&d.decoder, block, true, 1 << 16)
		block = block[result.consumed:]
		switch result.status {
		case .Ready:
			return hpack.section_fields(&d.section)
		case .Failed:
			return nil, false
		case .Need_Input, .Yield:
		}
	}
	return nil, false
}

h2w_field :: proc(fields: []hpack.Field, name: string) -> (string, bool) {
	for field in fields {
		if field.name == name {
			return field.value, true
		}
	}
	return "", false
}

// RFC 9110 sections 6.4.1 and 8.6: a 204 carries no content and no
// Content-Length; a HEAD response carries the length a GET would have, and
// no content. The engine refuses to send a 204 with a Content-Length, so a
// Saba that added one would reset the stream instead of answering.
@(test)
h2_no_content_and_head_responses_carry_the_right_content_length :: proc(t: ^testing.T) {
	state := H2W_Server {
		idle = H2W_PATIENCE,
	}
	h2w_run(t, &state, proc(t: ^testing.T, state: ^H2W_Server, peer: ^H2W_Peer) {
		decoder: H2W_Decoder
		h2w_decoder_init(&decoder)
		defer h2w_decoder_destroy(&decoder)
		wire: [dynamic]u8
		defer delete(wire)
		h2w_get(&wire, 1, "/empty")
		h2w_headers(&wire, 3, true, {{":method", "HEAD"}, {":scheme", "https"}, {":authority", "localhost"}, {":path", "/"}})
		if !testing.expect(t, h2w_preface(peer) && h2w_send(peer, wire[:])) {
			return
		}
		ended: [2]bool
		for !ended[0] || !ended[1] {
			frame, ok := h2w_next(peer, true)
			if !testing.expect(t, ok && frame.kind != 7, "connection ended before both responses") {
				return
			}
			if frame.stream != 1 && frame.stream != 3 {
				continue
			}
			if !testing.expectf(t, frame.kind != 3, "stream %d was reset instead of answered", frame.stream) {
				return
			}
			testing.expectf(t, frame.kind != 0 || len(frame.payload) == 0, "stream %d carried content", frame.stream)
			if frame.kind == 1 {
				fields, decoded := h2w_decode(&decoder, frame)
				if !testing.expect(t, decoded, "undecodable response field section") {
					return
				}
				status, _ := h2w_field(fields, ":status")
				length, has_length := h2w_field(fields, "content-length")
				if frame.stream == 1 {
					testing.expect_value(t, status, "204")
					testing.expect(t, !has_length, "a 204 response carries content-length")
				} else {
					testing.expect_value(t, status, "200")
					testing.expectf(t, has_length && length == "2", "HEAD content-length %q, not the GET length 2", length)
				}
			}
			ended[frame.stream / 2] ||= frame.kind <= 1 && frame.flags & 1 != 0
		}
	})
}

// A HEAD request answered 204 is still a 204: no Content-Length, although
// other HEAD responses carry one. With one, the engine would refuse the
// response and the stream would be reset.
@(test)
h2_head_answered_no_content_carries_no_content_length :: proc(t: ^testing.T) {
	state := H2W_Server {
		idle = H2W_PATIENCE,
	}
	h2w_run(t, &state, proc(t: ^testing.T, state: ^H2W_Server, peer: ^H2W_Peer) {
		decoder: H2W_Decoder
		h2w_decoder_init(&decoder)
		defer h2w_decoder_destroy(&decoder)
		wire: [dynamic]u8
		defer delete(wire)
		h2w_headers(&wire, 1, true, {{":method", "HEAD"}, {":scheme", "https"}, {":authority", "localhost"}, {":path", "/empty"}})
		if !testing.expect(t, h2w_preface(peer) && h2w_send(peer, wire[:])) {
			return
		}
		for {
			frame, ok := h2w_next(peer, true)
			if !testing.expect(t, ok && frame.kind != 7, "connection ended before the response") {
				return
			}
			if frame.stream != 1 {
				continue
			}
			if !testing.expect(t, frame.kind != 3, "a HEAD answered 204 was reset") {
				return
			}
			if frame.kind == 1 {
				fields, decoded := h2w_decode(&decoder, frame)
				if !testing.expect(t, decoded, "undecodable response field section") {
					return
				}
				status, _ := h2w_field(fields, ":status")
				_, has_length := h2w_field(fields, "content-length")
				testing.expect_value(t, status, "204")
				testing.expect(t, !has_length, "a 204 answer to HEAD carries content-length")
			}
			if frame.kind <= 1 && frame.flags & 1 != 0 {
				return
			}
		}
	})
}

// RFC 9110 section 6.5.1: framing, routing, authentication, content metadata,
// cache directives and cookies are not trailer fields. A handler's are dropped
// (HTTP/3 drops the same ones) and the rest of the trailer section is sent.
@(test)
h2_forbidden_trailer_fields_are_dropped :: proc(t: ^testing.T) {
	state := H2W_Server {
		idle = H2W_PATIENCE,
	}
	h2w_run(t, &state, proc(t: ^testing.T, state: ^H2W_Server, peer: ^H2W_Peer) {
		decoder: H2W_Decoder
		h2w_decoder_init(&decoder)
		defer h2w_decoder_destroy(&decoder)
		wire: [dynamic]u8
		defer delete(wire)
		h2w_get(&wire, 1, "/forbidden-trailers")
		if !testing.expect(t, h2w_preface(peer) && h2w_send(peer, wire[:])) {
			return
		}
		sections := 0
		for {
			frame, ok := h2w_next(peer, true)
			if !testing.expect(t, ok && frame.kind != 7, "connection ended before the trailers") {
				return
			}
			if frame.stream != 1 {
				continue
			}
			if !testing.expect(t, frame.kind != 3, "a response with trailers was reset") {
				return
			}
			if frame.kind == 1 {
				fields, decoded := h2w_decode(&decoder, frame)
				if !testing.expect(t, decoded, "undecodable field section") {
					return
				}
				sections += 1
				if sections == 2 {
					testing.expect_value(t, len(fields), 1)
					value, found := h2w_field(fields, "grpc-status")
					testing.expect(t, found && value == "0", "the allowed trailer was not sent")
					for name in ([]string{"set-cookie", "authorization", "cache-control", "content-type"}) {
						_, sent := h2w_field(fields, name)
						testing.expectf(t, !sent, "forbidden trailer %s was sent", name)
					}
				}
			}
			if frame.kind <= 1 && frame.flags & 1 != 0 {
				break
			}
		}
		testing.expect_value(t, sections, 2)
	})
}

// Connection-specific fields are not HTTP/2 fields (RFC 9113 section 8.2.2).
// A handler's Connection or Transfer-Encoding is dropped, never sent, and the
// rest of its response is delivered.
@(test)
h2_connection_specific_response_headers_are_dropped :: proc(t: ^testing.T) {
	state := H2W_Server {
		idle = H2W_PATIENCE,
	}
	h2w_run(t, &state, proc(t: ^testing.T, state: ^H2W_Server, peer: ^H2W_Peer) {
		decoder: H2W_Decoder
		h2w_decoder_init(&decoder)
		defer h2w_decoder_destroy(&decoder)
		wire: [dynamic]u8
		defer delete(wire)
		h2w_get(&wire, 1, "/hop")
		if !testing.expect(t, h2w_preface(peer) && h2w_send(peer, wire[:])) {
			return
		}
		headers, body := false, 0
		for {
			frame, ok := h2w_next(peer, true)
			if !testing.expect(t, ok && frame.kind != 7, "connection ended before the response") {
				return
			}
			if frame.stream != 1 {
				continue
			}
			if !testing.expect(t, frame.kind != 3, "a response with connection-specific headers was reset") {
				return
			}
			if frame.kind == 1 {
				fields, decoded := h2w_decode(&decoder, frame)
				if !testing.expect(t, decoded, "undecodable response field section") {
					return
				}
				headers = true
				status, _ := h2w_field(fields, ":status")
				testing.expect_value(t, status, "200")
				kept, _ := h2w_field(fields, "x-kept")
				testing.expect_value(t, kept, "yes")
				for name in ([]string{"connection", "keep-alive", "transfer-encoding", "upgrade"}) {
					_, present := h2w_field(fields, name)
					testing.expectf(t, !present, "%s reached the HTTP/2 response", name)
				}
			}
			if frame.kind == 0 {
				body += len(frame.payload)
			}
			if frame.kind <= 1 && frame.flags & 1 != 0 {
				break
			}
		}
		testing.expect(t, headers, "no response field section")
		testing.expect_value(t, body, 3)
	})
}

// An extended CONNECT the server cannot take is refused before any handler
// runs: one that ends its stream at once, and one whose target no handler
// expects (an empty :path, which the engine admits for a non-HTTP scheme).
// REFUSED_STREAM tells the client nothing was processed. The connection
// keeps serving.
@(test)
h2_unusable_extended_connect_is_refused_before_the_handler :: proc(t: ^testing.T) {
	state := H2W_Server {
		idle = H2W_PATIENCE,
	}
	h2w_run(t, &state, proc(t: ^testing.T, state: ^H2W_Server, peer: ^H2W_Peer) {
		wire: [dynamic]u8
		defer delete(wire)
		h2w_headers(
			&wire,
			1,
			true,
			{{":method", "CONNECT"}, {":protocol", "websocket"}, {":scheme", "https"}, {":authority", "localhost"}, {":path", "/tunnel"}},
		)
		h2w_headers(
			&wire,
			3,
			false,
			{{":method", "CONNECT"}, {":protocol", "websocket"}, {":scheme", "wss"}, {":authority", "localhost"}, {":path", ""}},
		)
		if !testing.expect(t, h2w_preface(peer) && h2w_send(peer, wire[:])) {
			return
		}
		codes := [2]u32{max(u32), max(u32)}
		for codes[0] == max(u32) || codes[1] == max(u32) {
			frame, ok := h2w_next(peer, true)
			if !testing.expect(t, ok && frame.kind != 7, "connection ended before both tunnels were refused") {
				return
			}
			if frame.stream != 1 && frame.stream != 3 {
				continue
			}
			if !testing.expectf(t, frame.kind == 3, "stream %d was answered (frame type %d), not refused", frame.stream, frame.kind) {
				return
			}
			codes[frame.stream / 2] = h2w_code(frame)
		}
		// REFUSED_STREAM
		testing.expect_value(t, codes[0], u32(7))
		testing.expect_value(t, codes[1], u32(7))
		testing.expect_value(t, sync.atomic_load(&state.handled), 0)

		clear(&wire)
		h2w_get(&wire, 5, "/")
		if !testing.expect(t, h2w_send(peer, wire[:])) {
			return
		}
		answered := false
		for !answered {
			frame, ok := h2w_next(peer, true)
			if !ok || frame.kind == 7 {
				break
			}
			answered = frame.kind == 1 && frame.stream == 5 && h2w_status(frame) == 200
		}
		testing.expect(t, answered, "the connection did not serve a request after the refusals")
	})
}

// Only a 2xx answer opens an RFC 8441 tunnel. A handler that returns an
// upgrade with another status, or a bare 101 on an ordinary stream, has no
// HTTP/2 representation and is answered 501.
@(test)
h2_upgrades_without_a_2xx_tunnel_are_answered_501 :: proc(t: ^testing.T) {
	state := H2W_Server {
		idle = H2W_PATIENCE,
	}
	h2w_run(t, &state, proc(t: ^testing.T, state: ^H2W_Server, peer: ^H2W_Peer) {
		decoder: H2W_Decoder
		h2w_decoder_init(&decoder)
		defer h2w_decoder_destroy(&decoder)
		wire: [dynamic]u8
		defer delete(wire)
		h2w_headers(
			&wire,
			1,
			false,
			{{":method", "CONNECT"}, {":protocol", "websocket"}, {":scheme", "https"}, {":authority", "localhost"}, {":path", "/redirect-tunnel"}},
		)
		h2w_get(&wire, 3, "/switch")
		if !testing.expect(t, h2w_preface(peer) && h2w_send(peer, wire[:])) {
			return
		}
		statuses: [2]string
		ended: [2]bool
		for !ended[0] || !ended[1] {
			frame, ok := h2w_next(peer, true)
			if !testing.expect(t, ok && frame.kind != 7, "connection ended before both answers") {
				return
			}
			if frame.stream != 1 && frame.stream != 3 {
				continue
			}
			index := frame.stream / 2
			if !testing.expectf(t, frame.kind != 3, "stream %d was reset instead of answered", frame.stream) {
				return
			}
			if frame.kind == 1 {
				fields, decoded := h2w_decode(&decoder, frame)
				if !testing.expect(t, decoded, "undecodable response field section") {
					return
				}
				if statuses[index] == "" {
					statuses[index], _ = h2w_field(fields, ":status")
				}
			}
			ended[index] ||= frame.kind <= 1 && frame.flags & 1 != 0
		}
		testing.expect_value(t, statuses[0], "501")
		testing.expect_value(t, statuses[1], "501")
	})
}

// A response that asks to close the connection ends it gracefully over
// HTTP/2: GOAWAY(NO_ERROR) naming the stream that asked, and a request the
// client sends afterwards is not processed.
@(test)
h2_close_connection_response_sends_goaway :: proc(t: ^testing.T) {
	// The final GOAWAY follows the peer's PING acknowledgement, which a
	// starved test thread can delay past the fixture's one-second bound.
	state := H2W_Server {
		idle     = H2W_PATIENCE,
		response = H2W_PATIENCE - time.Second,
	}
	h2w_run(t, &state, proc(t: ^testing.T, state: ^H2W_Server, peer: ^H2W_Peer) {
		wire: [dynamic]u8
		defer delete(wire)
		h2w_get(&wire, 1, "/close")
		if !testing.expect(t, h2w_preface(peer) && h2w_send(peer, wire[:])) {
			return
		}
		// The final GOAWAY names the last stream processed. The server may
		// write it before the last frame of the response that asked for it.
		goaways, last := 0, max(u32)
		ended := false
		for !ended {
			frame, ok := h2w_next(peer, true)
			if !testing.expect(t, ok, "connection ended before the response") {
				return
			}
			testing.expect(t, frame.kind != 3, "the closing response was reset")
			if frame.kind == 7 && len(frame.payload) >= 8 {
				goaways += 1
				last = (u32(frame.payload[0]) << 24 | u32(frame.payload[1]) << 16 | u32(frame.payload[2]) << 8 | u32(frame.payload[3])) & 0x7fffffff
				testing.expect_value(t, h2w_code(frame), u32(0))
			}
			ended = frame.stream == 1 && frame.kind <= 1 && frame.flags & 1 != 0
		}
		clear(&wire)
		h2w_get(&wire, 3, "/")
		_ = h2w_send(peer, wire[:])
		for {
			frame, ok := h2w_next(peer, true)
			if !ok {
				break
			}
			if !testing.expect(t, !(frame.kind == 1 && frame.stream == 3), "a request after the closing response was served") {
				return
			}
			if frame.kind == 7 && len(frame.payload) >= 8 {
				goaways += 1
				last = (u32(frame.payload[0]) << 24 | u32(frame.payload[1]) << 16 | u32(frame.payload[2]) << 8 | u32(frame.payload[3])) & 0x7fffffff
				testing.expect_value(t, h2w_code(frame), u32(0))
			}
		}
		testing.expect(t, goaways > 0, "no GOAWAY after a response that closes the connection")
		testing.expect_value(t, last, u32(1))
		testing.expect_value(t, sync.atomic_load(&state.handled), 1)
	})
}

// Request trailers (RFC 9113 section 8.1) reach the handler beside the body.
@(test)
h2_request_trailers_reach_the_handler :: proc(t: ^testing.T) {
	state := H2W_Server {
		idle = H2W_PATIENCE,
	}
	h2w_run(t, &state, proc(t: ^testing.T, state: ^H2W_Server, peer: ^H2W_Peer) {
		wire: [dynamic]u8
		defer delete(wire)
		h2w_headers(&wire, 1, false, {{":method", "POST"}, {":scheme", "https"}, {":authority", "localhost"}, {":path", "/trailer-echo"}})
		h2w_frame(&wire, 0, 0, 1, transmute([]u8)string("payload"))
		h2w_headers(&wire, 1, true, {{"x-checksum", "c0ffee"}})
		if !testing.expect(t, h2w_preface(peer) && h2w_send(peer, wire[:])) {
			return
		}
		body: [dynamic]u8
		defer delete(body)
		for {
			frame, ok := h2w_next(peer, true)
			if !testing.expect(t, ok && frame.kind != 7, "connection ended before the response") {
				return
			}
			if frame.stream != 1 {
				continue
			}
			if !testing.expect(t, frame.kind != 3, "a request with trailers was reset") {
				return
			}
			if frame.kind == 0 {
				append(&body, ..frame.payload)
			}
			if frame.kind <= 1 && frame.flags & 1 != 0 {
				break
			}
		}
		testing.expect_value(t, string(body[:]), "c0ffee")
	})
}
