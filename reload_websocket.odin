package server

import "core:sync"
import "core:time"
import "core:unicode/utf8"
import async "shared:async"

@(private)
reset_websocket_read :: proc(task: ^Connection_Task) {
	task.websocket_used = 0
	task.websocket_expected = 2
	task.deadline = async.deadline_after(&task.runtime.executor, RELOAD_INTERVAL)
	task.connection.read_deadline = time.tick_add(time.tick_now(), RELOAD_INTERVAL)
}

// Yield here means that the connection's next state is ready to advance in
// this invocation. Pending I/O returns Waiting to the shared runtime.
@(private)
resume_reload_websocket :: proc(task: ^Connection_Task) -> async.Resume_Result {
	conn := &task.connection
	used := task.websocket_used
	if task.phase == .WebSocket_Header && used == 0 {
		if sync.atomic_load(&conn.reload.stopped) do return .Done
		if sync.atomic_load(&conn.reload.version) != task.websocket_version {
			at := append_websocket_frame(
				task.websocket_output[:],
				.Text,
				transmute([]u8)string("reload"),
			)
			payload := []u8 {
				u8(REGULAR_CLOSE >> 8),
				u8(REGULAR_CLOSE & 255),
				'r',
				'e',
				'l',
				'o',
				'a',
				'd',
				'i',
				'n',
				'g',
			}
			at += append_websocket_frame(task.websocket_output[at:], .Close, payload)
			queue_websocket_output(task, at, true)
			return .Yield
		}
	}
	target := task.websocket_expected
	if task.phase == .WebSocket_Header && used == 0 do target = 1
	n, err := task_read(task, task.websocket_input[used:target])
	if err.kind == .Pending do return .Waiting
	if err.kind == .Timeout && used == 0 && task.phase == .WebSocket_Header {
		reset_websocket_read(task)
		return .Yield
	}
	if err.kind != .None do return .Done
	task.websocket_used += n
	used = task.websocket_used
	if used == 1 {
		// Once a frame begins, its remaining bytes have the existing five
		// second frame deadline rather than the idle reload polling interval.
		task.deadline = async.deadline_after(&task.runtime.executor, REQUEST_HEADER_TIMEOUT)
		conn.read_deadline = time.tick_add(time.tick_now(), REQUEST_HEADER_TIMEOUT)
		return .Yield
	}
	if used < task.websocket_expected do return .Yield
	header := task.websocket_input[:2]
	opcode := Opcode(header[0] & 15)
	length := int(header[1] & 127)
	if task.phase == .WebSocket_Header {
		code: u16 = PROTOCOL_ERROR
		reason: string
		if header[0] & 0x70 != 0 {
			reason = "reserved bits must be zero"
		} else if header[1] & 0x80 == 0 {
			reason = "client frames must be masked"
		} else if opcode == .Text || opcode == .Binary {
			code = UNSUPPORTED_DATA; reason = "reload endpoint accepts control frames only"
		} else if opcode != .Close && opcode != .Ping && opcode != .Pong {
			reason = "unsupported opcode"
		} else if header[0] & 0x80 == 0 {
			reason = "control frames must not be fragmented"
		} else if length > 125 {
			reason = "control payload exceeds 125 bytes"
		} else if opcode == .Close && length == 1 {
			reason = "close payload must be empty or contain at least 2 bytes"
		}
		if reason != "" {
			queue_websocket_close(task, code, reason)
			return .Yield
		}
		task.websocket_expected = 6 + length
		task.phase = .WebSocket_Frame
		return .Yield
	}
	mask := task.websocket_input[2:6]
	payload := task.websocket_input[6:6 + length]
	for &value, i in payload do value ~= mask[i % 4]
	#partial switch opcode {
	case .Close:
		if length >= 2 {
			code := u16(payload[0]) << 8 | u16(payload[1])
			if !valid_close_code(code) {
				queue_websocket_close(task, PROTOCOL_ERROR, "invalid close code")
				return .Yield
			}
			if !utf8.valid_string(string(payload[2:])) {
				queue_websocket_close(
					task,
					INVALID_PAYLOAD_DATA,
					"close reason must be valid UTF-8",
				)
				return .Yield
			}
		}
		size := append_websocket_frame(task.websocket_output[:], .Close, payload)
		queue_websocket_output(task, size, true)
	case .Ping:
		size := append_websocket_frame(task.websocket_output[:], .Pong, payload)
		queue_websocket_output(task, size, false)
	case .Pong:
		reset_websocket_read(task)
		task.phase = .WebSocket_Header
	case:
		unreachable()
	}
	return .Yield
}

@(private)
append_websocket_frame :: proc(storage: []u8, opcode: Opcode, payload: []u8) -> int {
	assert(len(payload) <= 125 && len(storage) >= len(payload) + 2)
	storage[0], storage[1] = 0x80 | u8(opcode), u8(len(payload))
	copy(storage[2:], payload)
	return len(payload) + 2
}

@(private)
queue_websocket_output :: proc(task: ^Connection_Task, count: int, close_after: bool) {
	task.output = {task.websocket_output[:count], nil}
	task.output_index, task.output_offset = 0, 0
	task.finish_after_write = close_after
	task.after_write = .WebSocket_Header
	task.deadline = async.deadline_after(&task.runtime.executor, RESPONSE_SEND_TIMEOUT)
	task.phase = .Write
}

@(private)
queue_websocket_close :: proc(task: ^Connection_Task, code: u16, reason: string) {
	payload: [125]u8
	assert(len(reason) <= 123)
	payload[0], payload[1] = u8(code >> 8), u8(code & 255)
	copy(payload[2:], reason)
	size := append_websocket_frame(task.websocket_output[:], .Close, payload[:2 + len(reason)])
	queue_websocket_output(task, size, true)
}
