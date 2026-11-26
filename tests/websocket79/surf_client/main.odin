package main

import client "shared:surf"
import codec "shared:async/websocket"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:time"

main :: proc() {
	assert(len(os.args) == 2)
	port, valid := strconv.parse_int(os.args[1])
	assert(valid)
	socket, error := net.dial_tcp_from_endpoint({net.IP4_Loopback, port})
	assert(error == nil)
	tcp := net.TCP_Connection {
		socket = socket,
	}

	connection: client.WebSocket_Conn
	assert(
		client.websocket_client(
			&connection,
			client.websocket_tcp_stream(&tcp),
			{
				host = "synthetic.invalid",
				target = "/surf",
				origin = "https://allowed.invalid",
				subprotocols = []string{"chat.v1", "chat.v2"},
				max_message_size = 4096,
				handshake_timeout = 3 * time.Second,
			},
		) ==
		.None,
	)
	defer client.websocket_close(&connection)
	assert(client.websocket_upgrade(&connection).kind == .None)
	assert(
		client.websocket_write_message(&connection, .Text, transmute([]u8)string("existing-surf-client")).kind ==
		.None,
	)
	buffer: [4096]u8
	opcode, n, read_error := client.websocket_read_message(&connection, buffer[:])
	assert(read_error.kind == .None && opcode == codec.Opcode.Text)
	assert(cast(string)buffer[:n] == "existing-surf-client")
	assert(client.websocket_ping(&connection, transmute([]u8)string("surf-ping")).kind == .None)
	assert(client.websocket_write_message(&connection, .Binary, []u8{1, 2, 3, 4}).kind == .None)
	opcode, n, read_error = client.websocket_read_message(&connection, buffer[:])
	assert(read_error.kind == .None && opcode == codec.Opcode.Binary && n == 4)
	assert(buffer[0] == 1 && buffer[1] == 2 && buffer[2] == 3 && buffer[3] == 4)
	assert(client.websocket_close(&connection, 1000, "surf-done").kind == .None)
	fmt.println("{\"passed\":true,\"client\":\"existing-surf\"}")
}
