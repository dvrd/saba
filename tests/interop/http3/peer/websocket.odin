package saba_test_h3_peer

import "core:crypto"
import "core:time"

// RFC 6455 messages over an extended CONNECT stream (RFC 9220), framed here:
// the client masks every frame, the server never does.

Ws_Opcode :: enum u8 {
	Continuation = 0x0,
	Text         = 0x1,
	Binary       = 0x2,
	Close        = 0x8,
	Ping         = 0x9,
	Pong         = 0xa,
}

Ws_Message :: struct {
	opcode: Ws_Opcode,
	data:   []u8,
}

// A tunnel and how far its received bytes have been read as messages.
Socket :: struct {
	stream: ^Stream,
	read:   int,
}

// A client frame with FIN set.
ws_frame :: proc(opcode: Ws_Opcode, payload: []u8, allocator := context.temp_allocator) -> []u8 {
	out := make([dynamic]u8, allocator)
	append(&out, 0x80 | u8(opcode))
	n := len(payload)
	switch {
	case n < 126:
		append(&out, 0x80 | u8(n))
	case n < 1 << 16:
		append(&out, 0x80 | 126, u8(n >> 8), u8(n))
	case:
		append(&out, 0x80 | 127)
		for i := 7; i >= 0; i -= 1 {
			append(&out, u8(n >> uint(8 * i)))
		}
	}
	key: [4]u8
	crypto.rand_bytes(key[:])
	append(&out, ..key[:])
	for b, i in payload {
		append(&out, b ~ key[i % 4])
	}
	return out[:]
}

// The next whole message in data after at, its fragments joined.
ws_next :: proc(data: []u8, at: ^int, allocator := context.temp_allocator) -> (Ws_Message, bool) {
	cursor := at^
	opcode: Ws_Opcode
	payload := make([dynamic]u8, allocator)
	for {
		if cursor + 2 > len(data) {
			return {}, false
		}
		first, second := data[cursor], data[cursor + 1]
		cursor += 2
		n := int(second & 0x7f)
		if n == 126 {
			if cursor + 2 > len(data) {
				return {}, false
			}
			n = int(data[cursor]) << 8 | int(data[cursor + 1])
			cursor += 2
		} else if n == 127 {
			if cursor + 8 > len(data) {
				return {}, false
			}
			n = 0
			for i in 0 ..< 8 {
				n = n << 8 | int(data[cursor + i])
			}
			cursor += 8
		}
		if second & 0x80 != 0 || cursor + n > len(data) {
			return {}, false
		}
		if Ws_Opcode(first & 0x0f) != .Continuation {
			opcode = Ws_Opcode(first & 0x0f)
		}
		append(&payload, ..data[cursor:cursor + n])
		cursor += n
		if first & 0x80 != 0 {
			break
		}
	}
	at^ = cursor
	return {opcode, payload[:]}, true
}

// An extended CONNECT for a WebSocket on path, after its response headers
// arrived (or the stream settled).
ws_open :: proc(
	cl: ^Client,
	path := "/socket",
	origin := "https://allowed.invalid",
	subprotocol := "chat.v2",
	protocol := "websocket",
) -> Socket {
	fields := []Field {
		{"sec-websocket-version", "13"},
		{"origin", origin},
		{"sec-websocket-protocol", subprotocol},
	}
	s := request(
		cl,
		{method = "CONNECT", protocol = protocol, path = path, headers = fields, open = true},
	)
	if s != nil {
		run(s.client, 8 * time.Second, proc(cl: ^Client, data: rawptr) -> bool {
				s := cast(^Stream)data
				return len(s.headers) > 0 || settled(s)
			}, s)
	}
	return {stream = s}
}

ws_send :: proc(socket: ^Socket, opcode: Ws_Opcode, payload: []u8) {
	send(socket.stream, ws_frame(opcode, payload))
}

// Runs until the next message of kind want arrives (skipping others) and
// returns its payload, or false when the tunnel or connection ended first.
ws_receive :: proc(
	socket: ^Socket,
	want: Ws_Opcode,
	timeout: time.Duration = 8 * time.Second,
) -> (
	[]u8,
	bool,
) {
	Wait :: struct {
		socket:  ^Socket,
		want:    Ws_Opcode,
		message: Ws_Message,
		found:   bool,
	}
	wait := Wait {
		socket = socket,
		want   = want,
	}
	run(socket.stream.client, timeout, proc(cl: ^Client, data: rawptr) -> bool {
			w := cast(^Wait)data
			for {
				message, ok := ws_next(w.socket.stream.body[:], &w.socket.read)
				if !ok {
					break
				}
				if message.opcode == w.want {
					w.message, w.found = message, true
					return true
				}
			}
			return settled(w.socket.stream)
		}, &wait)
	return wait.message.data, wait.found
}

// Sends a message and waits for the next message of kind want.
ws_exchange :: proc(
	socket: ^Socket,
	opcode: Ws_Opcode,
	payload: []u8,
	want: Ws_Opcode,
) -> (
	[]u8,
	bool,
) {
	ws_send(socket, opcode, payload)
	return ws_receive(socket, want)
}

// The close handshake: Close 1000 with the end of the stream, then the
// server's Close.
ws_close :: proc(socket: ^Socket) -> bool {
	ws_send(socket, .Close, {0x03, 0xe8})
	finish(socket.stream)
	_, closed := ws_receive(socket, .Close)
	return closed
}
