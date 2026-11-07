package saba_development

import "core:crypto/legacy/sha1"
import "core:encoding/base64"
import "core:log"
import "core:strings"
import "core:time"

Opcode :: enum u8 {
	Continue = 0x00,
	Text     = 0x01,
	Binary   = 0x02,
	// 0x03–0x07 | Reserved for future data-frame types
	Close    = 0x08,
	Ping     = 0x09,
	Pong     = 0x0a,
	// 0x0b–0x0f | Reserved for future control-frame types
}

REGULAR_CLOSE :: 1000
PROTOCOL_ERROR :: 1002
UNSUPPORTED_DATA :: 1003
INVALID_PAYLOAD_DATA :: 1007

// Returns an accept value borrowing caller storage; no stack-backed value escapes.
@(private)
websocket_accept :: proc(request: ^Request, storage: []u8) -> (string, HTTP_Status) {
	key := header_value(request, "Sec-WebSocket-Key")
	nonce: [16]byte
	decoded, decode_error := base64.decode_into_buf(nonce[:], key, options = {.Strict})
	connection := header_value(request, "Connection")
	has_upgrade := false
	for token in strings.split_iterator(&connection, ",") {
		if strings.equal_fold(strings.trim_space(token), "upgrade") do has_upgrade = true
	}
	if decode_error != nil ||
	   len(decoded) != len(nonce) ||
	   header_value(request, "Sec-WebSocket-Version") != "13" ||
	   !strings.equal_fold(header_value(request, "Upgrade"), "websocket") ||
	   !has_upgrade {
		return "", .Bad_Request
	}
	hash: sha1.Context
	digest: [sha1.DIGEST_SIZE]u8
	sha1.init(&hash)
	sha1.update(&hash, transmute([]u8)key)
	sha1.update(&hash, transmute([]u8)WEBSOCKET_GUID)
	sha1.final(&hash, digest[:])
	accept, err := base64.encode_into_buf(storage, digest[:])
	if err != nil do return "", .Internal_Server_Error
	return string(accept), .None
}

upgrade_websocket :: proc(conn: ^Connection, request: ^Request) -> bool {
	storage: [28]u8
	accept, status := websocket_accept(request, storage[:])
	if status != .None {
		send_empty_response(conn, status); return false
	}
	return send_response(
		conn,
		{
			status = .Switching_Protocols,
			headers = []Header{{"Upgrade", "websocket"}, {"Sec-WebSocket-Accept", accept}},
		},
	)
}

send_websocket_frame :: proc(conn: ^Connection, opcode: Opcode, payload: []u8) -> bool {
	if len(payload) > 125 {
		log.error("WebSocket control payload exceeds 125 bytes")
		return false
	}

	frame: [127]u8
	frame[0] = 0x80 | cast(u8)opcode
	frame[1] = cast(u8)len(payload)
	copy(frame[2:], payload)

	conn.write_deadline = time.tick_add(time.tick_now(), RESPONSE_SEND_TIMEOUT)

	return send_bytes(conn, frame[:2 + len(payload)], "WebSocket frame")
}

send_websocket_close :: proc(conn: ^Connection, code: u16, reason: string) -> bool {
	if len(reason) > 123 {
		log.error("WebSocket close reason exceeds 123 bytes")
		return false
	}

	payload: [125]u8
	payload[0] = u8(code >> 8)
	payload[1] = u8(code & 0xff)
	copy(payload[2:], transmute([]u8)reason)

	return send_websocket_frame(conn, .Close, payload[:2 + len(reason)])
}

read_websocket_bytes :: proc(conn: ^Connection, buffer: []u8) -> bool {
	used := 0

	for used < len(buffer) {
		n, err := read_connection(conn, buffer[used:])
		if err != nil {
			log.error("Could not read WebSocket frame:", err, "| socket:", conn.socket)

			return false
		}

		if n == 0 {
			log.error("Client disconnected during WebSocket frame", "| socket:", conn.socket)

			return false
		}

		used += n
	}

	return true
}

valid_close_code :: proc(code: u16) -> bool {
	return(
		(code >= 1000 && code <= 1003) ||
		(code >= 1007 && code <= 1014) ||
		(code >= 3000 && code <= 4999) \
	)
}
