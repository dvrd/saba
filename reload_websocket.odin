package server

import "core:log"
import "core:sync"
import "core:time"
import "core:unicode/utf8"

process_websocket_control_frames :: proc(conn: ^Connection) {
	version := sync.atomic_load(&conn.reload.version)
	conn.write_deadline = {}

	for !sync.atomic_load(&conn.reload.stopped) {
		current_version := sync.atomic_load(&conn.reload.version)
		if current_version != version {
			message := transmute([]u8)string("reload")

			if !send_websocket_frame(conn, .Text, message) do return

			send_websocket_close(conn, REGULAR_CLOSE, "reloading")
			return
		}

		// The HTTP read may already have received the first WebSocket frame.
		if len(conn.read_buffer) == 0 {
			ready, timed_out := wait_ready(
				conn.socket,
				{.IN},
				time.tick_add(time.tick_now(), RELOAD_INTERVAL),
			)

			if timed_out do continue
			if !ready do return
		}

		conn.read_deadline = {}

		header: [2]u8
		n, err := read_connection(conn, header[:1])

		if err != nil {
			log.error("Could not receive WebSocket frame:", err, "| socket:", conn.socket)
			return
		}

		if n == 0 do return

		// Once a frame starts, require the remaining bytes within five seconds.
		conn.read_deadline = time.tick_add(time.tick_now(), REQUEST_HEADER_TIMEOUT)

		if !read_websocket_bytes(conn, header[1:]) do return

		opcode := cast(Opcode)(header[0] & 0x0f) // 0000 1111
		reserved := (header[0] & 0x70) != 0 // 0111 0000
		final := (header[0] & 0x80) != 0 // 1000 0000

		length := cast(int)(header[1] & 0x7f) // 0111 1111
		masked := (header[1] & 0x80) != 0 // 1000 0000

		// This reload channel receives control frames only
		if reserved {
			send_websocket_close(conn, PROTOCOL_ERROR, "reserved bits must be zero")
			return
		}

		if !masked {
			send_websocket_close(conn, PROTOCOL_ERROR, "client frames must be masked")
			return
		}

		if opcode == .Text || opcode == .Binary {
			send_websocket_close(
				conn,
				UNSUPPORTED_DATA,
				"reload endpoint accepts control frames only",
			)
			return
		}

		if opcode != .Close && opcode != .Ping && opcode != .Pong {
			send_websocket_close(conn, PROTOCOL_ERROR, "unsupported opcode")
			return
		}

		if !final {
			send_websocket_close(conn, PROTOCOL_ERROR, "control frames must not be fragmented")
			return
		}

		if length > 125 {
			send_websocket_close(conn, PROTOCOL_ERROR, "control payload exceeds 125 bytes")
			return
		}

		if opcode == .Close && length == 1 {
			send_websocket_close(
				conn,
				PROTOCOL_ERROR,
				"close payload must be empty or contain at least 2 bytes",
			)
			return
		}

		mask: [4]u8
		payload: [125]u8

		if !read_websocket_bytes(conn, mask[:]) do return
		if !read_websocket_bytes(conn, payload[:length]) do return

		for i in 0 ..< length {
			payload[i] ~= mask[i % len(mask)]
		}

		#partial switch opcode {
		case .Close:
			if length >= 2 {
				code := cast(u16)payload[0] << 8 | cast(u16)payload[1]

				if !valid_close_code(code) {
					send_websocket_close(conn, PROTOCOL_ERROR, "invalid close code")
					return
				}

				reason := cast(string)payload[2:length]

				if !utf8.valid_string(reason) {
					send_websocket_close(
						conn,
						INVALID_PAYLOAD_DATA,
						"close reason must be valid UTF-8",
					)
					return
				}
			}

			send_websocket_frame(conn, .Close, payload[:length])
			return
		case .Ping:
			if !send_websocket_frame(conn, .Pong, payload[:length]) do return
		case .Pong:
		}
	}
}
