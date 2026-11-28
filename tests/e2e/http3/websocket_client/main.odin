// The client of the e2e/http3 suite, over async's HTTP/3 client (client.odin).
// websocket drives the http3_websocket fixture: RFC 9220 tunnels next to plain
// requests on a pool of lanes, an idle timeout, a 128KiB message, close
// handshakes and a cancelled tunnel. shutdown drives the http3_shutdown
// fixture: per-connection and listener-wide GOAWAY while WebSockets and
// requests are in flight. It exits 0 and prints an OK line when every check
// held.
//
//	websocket_client websocket|shutdown <port> <certificate.pem>
package main

import rt "base:runtime"
import "core:bytes"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:time"
import async "shared:async"
import h3 "shared:async/http/v3"
import tls "shared:async/tls"

main :: proc() {
	context.logger = log.nil_logger()
	assert(len(os.args) == 4)
	switch os.args[1] {
	case "websocket":
		websocket(os.args[2], os.args[3])
	case "shutdown":
		shutdown(os.args[2], os.args[3])
	case:
		panic("unknown mode")
	}
}

// One GET of /health: the body must be http-ok.
health :: proc(c: ^Client, label: string = "") {
	g := get(c, "/health")
	defer get_destroy(g)
	if g.error.kind != .None {
		fmt.printf("GET failed error=%v failure=%v\n", g.error, g.failure)
	}
	if label != "" {
		fmt.printf("%s kind=%v status=%d body=%s\n", label, g.error.kind, g.status, string(g.body[:]))
	}
	assert(g.error.kind == .None && g.status == 200 && string(g.body[:]) == "http-ok")
}

lanes_inserted :: proc(pool: ^h3.Pool, user: rawptr) {
	inserts := cast(^u64)user
	for slot in pool.slots {
		if slot.used && slot.client != nil {
			inserts^ += slot.client.qpack.stats.encoded_inserts
		}
	}
}

websocket :: proc(port, cert_path: string) {
	roots: tls.Root_Pool
	assert(tls.root_pool_load_file(&roots, cert_path) == nil)
	defer tls.root_pool_destroy(&roots)
	number, number_ok := strconv.parse_int(port)
	assert(number_ok)
	// Requests name the origin localhost:8443 while the pool dials the HTTP/3
	// port, as an Alt-Svc alternative would be reached.
	c := new(Client)
	defer free(c)
	client_start(c, number, "localhost:8443", &roots, nil)
	conn, error := socket_open(c)
	fmt.printf("OPEN error=%v status=%d\n", error.kind, conn.status)
	assert(error.kind == .None && conn.status == 200)
	assert(socket_protocol(conn) == "chat.v2")
	conn2, error2 := socket_open(c)
	assert(error2.kind == .None && socket_protocol(conn2) == "chat.v2")
	// A websocket whose reads wait too long fails: nothing arrives within its
	// idle timeout, so the read ends with .Timeout instead of blocking.
	conn3, error3 := socket_open(c, {idle_timeout = 500 * time.Millisecond, ping_interval = async.WS_PING_OFF})
	assert(error3.kind == .None)
	_, expired, expired_error := socket_receive(conn3)
	assert(expired_error.kind != .None && expired == nil && conn3.close.reason == .Timeout)
	socket_wait(conn3)
	socket_destroy(conn3)
	for _ in 0 ..< 7 {
		health(c)
	}
	assert(socket_send(conn, .Text, transmute([]u8)string("native-hello")).kind == .None)
	kind, data, read := socket_receive(conn)
	fmt.printf("READ kind=%v n=%d\n", read.kind, len(data))
	assert(read.kind == .None && kind == .Text && string(data) == "native-hello")
	delete(data, rt.heap_allocator())
	// This exceeds both the HTTP2 stream window and Saba's64KiB body queue.
	// Incremental backpressure must complete without buffering an unbounded body.
	payload := make([]u8, 128 * 1024)
	defer delete(payload)
	for &byte, i in payload {
		byte = u8(i % 251)
	}
	assert(socket_send(conn, .Binary, payload).kind == .None)
	kind, data, read = socket_receive(conn)
	fmt.printf("LARGE kind=%v n=%d opcode=%v\n", read.kind, len(data), kind)
	assert(read.kind == .None && kind == .Binary && len(data) == len(payload) && bytes.equal(payload, data))
	delete(data, rt.heap_allocator())
	assert(socket_close(conn).kind == .None)
	assert(conn.close.reason == .Local_Close && conn.close.clean)
	assert(socket_send(conn2, .Text, transmute([]u8)string("second-stream")).kind == .None)
	kind, data, read = socket_receive(conn2)
	assert(read.kind == .None && string(data) == "second-stream")
	delete(data, rt.heap_allocator())
	assert(socket_close(conn2).kind == .None)
	assert(conn2.close.reason == .Local_Close && conn2.close.clean)
	health(c, "AFTER")
	inserts: u64
	with_pool(c, lanes_inserted, &inserts)
	assert(inserts > 0)
	// A websocket still open when the client goes away is reset with
	// H3_REQUEST_CANCELLED, and its tunnel gives back everything it held.
	live, live_error := socket_open(c)
	assert(live_error.kind == .None)
	socket_cancel(live)
	assert(live.ended && live.tunnel._self == nil && live.close.reason == .Cancelled)
	socket_destroy(live)
	socket_destroy(conn)
	socket_destroy(conn2)
	assert(client_drain(c))
	client_stop(c)
	fmt.println("OK native-http3-websocket")
}

lanes_used :: proc(pool: ^h3.Pool, user: rawptr) {
	used := cast(^int)user
	for slot in pool.slots {
		if slot.used {
			used^ += 1
		}
	}
}

Lane_Check :: struct {
	lane:     ^h3.Client,
	socket:   ^Socket,
	goaway:   bool,
	retired:  bool,
	same:     bool,
	deadline: time.Time,
}

lane_goaway :: proc(pool: ^h3.Pool, user: rawptr) {
	check := cast(^Lane_Check)user
	check.goaway = check.lane.shutdown.received
	// The websocket's tunnel is still on the lane it opened on.
	check.same = check.socket.tunnel._connect != nil && check.socket.tunnel._connect.owner == check.lane
}

lane_retire :: proc(pool: ^h3.Pool, user: rawptr) {
	check := cast(^Lane_Check)user
	check.retired = h3.client_retire_ready(check.lane)
	if !check.retired {
		_ = h3.pool_maintain(pool, check.deadline)
		check.retired = h3.client_retire_ready(check.lane)
	}
}

lane_print :: proc(pool: ^h3.Pool, user: rawptr) {
	owner := (cast(^Lane_Check)user).lane
	fmt.printf(
		"RETIRE phase=%v dead=%v err=%v state=%v control=%d/%d pending=%d\n",
		owner.transport.phase,
		owner.dead,
		owner.err,
		owner.shutdown,
		owner.control.sent,
		owner.control.n,
		owner.pending_output.n,
	)

	for b in owner.transport.bufs {
		if b.used {
			fmt.printf(
				"BUF id=%d n=%d fin=%v ack=%v stop=%v stopack=%v recv=%d recvfin=%v reset=%v\n",
				b.id,
				b.n,
				b.fin,
				b.fin_acked,
				b.want_stop,
				b.stop_acked,
				b.recv_n,
				b.recv_fin,
				b.reset,
			)
		}
	}
}

echo :: proc(socket: ^Socket, text: string) {
	assert(socket_send(socket, .Text, transmute([]u8)text).kind == .None)
	_, data, error := socket_receive(socket)
	assert(error.kind == .None && string(data) == text)
	delete(data, rt.heap_allocator())
}

expect_ok :: proc(c: ^Client, path: string) {
	g := get(c, path)
	defer get_destroy(g)
	assert(g.error.kind == .None && g.status == 200 && string(g.body[:]) == "http-ok")
}

shutdown :: proc(port, cert_path: string) {
	roots: tls.Root_Pool
	assert(tls.root_pool_load_file(&roots, cert_path) == nil)
	defer tls.root_pool_destroy(&roots)
	number, number_ok := strconv.parse_int(port)
	assert(number_ok)
	authority := fmt.aprintf("localhost:%s", port)
	defer delete(authority)
	c := new(Client)
	defer free(c)
	client_start(c, number, authority, &roots, nil)
	socket, error := socket_open(c)
	assert(error.kind == .None && socket.lane != nil)
	check := Lane_Check {
		lane   = socket.lane,
		socket = socket,
	}
	// The server drains the websocket's connection (and the request's own)
	// while the slow response is still in flight: that response completes.
	expect_ok(c, "/drain")
	echo(socket, "after-goaway")
	until := time.time_add(time.now(), 3 * time.Second)
	for !check.goaway && time.diff(time.now(), until) > 0 {
		with_pool(c, lane_goaway, &check)
		if !check.goaway {
			echo(socket, "after-goaway")
		}
	}
	assert(check.goaway && check.same)
	expect_ok(c, "/health")
	used := 0
	with_pool(c, lanes_used, &used)
	with_pool(c, lane_goaway, &check)
	assert(used >= 2 && check.same)
	assert(socket_close(socket).kind == .None)
	assert(socket.close.reason == .Local_Close && socket.close.clean)
	check.deadline = time.time_add(time.now(), 3 * time.Second)

	for !check.retired && time.diff(time.now(), check.deadline) > 0 {
		with_pool(c, lane_retire, &check)
		if !check.retired {
			time.sleep(time.Millisecond)
		}
	}

	if !check.retired {
		g := get(c, "/inspect")
		get_destroy(g)
		with_pool(c, lane_print, &check)
	}

	assert(check.retired)
	second, second_error := socket_open(c)
	assert(second_error.kind == .None)
	expect_ok(c, "/global-drain")
	echo(second, "global-live")
	assert(socket_close(second).kind == .None)
	assert(second.close.reason == .Local_Close && second.close.clean)
	assert(client_drain(c))
	socket_destroy(socket)
	socket_destroy(second)
	client_stop(c)
	fmt.println("OK per-peer and global GOAWAY preserve WebSockets and ordinary requests")
}
