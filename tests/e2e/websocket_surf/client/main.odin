// The client of e2e/websocket_surf: surf's WebSocket client against the
// websocket_policy fixture over ws. Every check is an assert; it prints OK
// surf-websocket at the end.
//
//     client <port>
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:sync"
import "core:time"
import surf "shared:surf"

// Each operation completes on the client's task; the main thread waits here.
Waiter :: struct {
	done: sync.Sema,
}

finished :: proc(op: ^surf.WebSocket_Op) {
	sync.sema_post(&(cast(^Waiter)op.user_data).done)
}

wait :: proc(op: ^surf.WebSocket_Op) {
	assert(sync.sema_wait_with_timeout(&(cast(^Waiter)op.user_data).done, 5 * time.Second))
}

main :: proc() {
	assert(len(os.args) == 2)
	port, valid := strconv.parse_int(os.args[1])
	assert(valid)

	client: surf.Client
	assert(client_start(&client) == .None)
	defer {
		assert(surf.client_close(&client).kind == .None)
		for !surf.client_quiescent(&client) {
			time.sleep(time.Millisecond)
		}
		assert(surf.client_destroy(&client).kind == .None)
	}

	waiter: Waiter
	op := surf.WebSocket_Op {
		callback  = finished,
		user_data = &waiter,
	}
	url := fmt.tprintf("ws://127.0.0.1:%d/surf", port)
	session, opened := surf.client_websocket_open(
		&client,
		url,
		{
			origin = "https://allowed.invalid",
			subprotocols = []string{"chat.v1", "chat.v2"},
			max_message_size = 4096,
			handshake_timeout = 3 * time.Second,
			// The server must answer the client's Pings while messages flow.
			ping_interval = 50 * time.Millisecond,
		},
		&op,
	)
	assert(opened.kind == .None)
	wait(&op)
	assert(op.error.kind == .None)
	defer assert(surf.client_websocket_release(&client, session).kind == .None)

	echo(&client, session, &op, .Text, transmute([]u8)string("existing-surf-client"))
	// Let at least one Ping and its Pong cross before the next message.
	time.sleep(150 * time.Millisecond)
	echo(&client, session, &op, .Binary, []u8{1, 2, 3, 4})

	assert(surf.client_websocket_close(&client, session, &op, 1000, "surf-done").kind == .None)
	wait(&op)
	assert(op.error.kind == .None)
	fmt.println("OK surf-websocket")
}

client_start :: proc(client: ^surf.Client) -> surf.Client_Error_Kind {
	return surf.client_start(client, {http = {allow_http = true}}).kind
}

// Sends payload and reads the server's echo of it.
echo :: proc(
	client: ^surf.Client,
	session: surf.WebSocket_Handle,
	op: ^surf.WebSocket_Op,
	kind: surf.WebSocket_Message_Kind,
	payload: []u8,
) {
	assert(surf.client_websocket_write(client, session, op, kind, payload).kind == .None)
	wait(op)
	assert(op.error.kind == .None && op.n == len(payload))

	buffer := make([]u8, 4096)
	defer delete(buffer)
	assert(surf.client_websocket_read(client, session, op, buffer).kind == .None)
	wait(op)
	assert(op.error.kind == .None && op.message == kind && op.n == len(payload))
	assert(string(buffer[:op.n]) == string(payload))
}
