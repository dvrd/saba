// The server of e2e/inheritance: HTTP/1.1 on a TCP port, HTTP/3 on a UDP
// port, and an upstream client. On "s" it starts a program that outlives it
// and prints its pid; on "q", or when its input closes, it stops and exits.
//
//     server <certificate.pem> <key.pem>
package main

import rt "base:runtime"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:strconv"
import "core:thread"
import "core:time"
import async "shared:async"
import core "shared:saba/core"
import upstream "shared:saba/upstream"
import credentials "shared:async/tls/credentials"
import store "shared:async/tls/credentials/store"
import surf "shared:surf"

App :: struct {
	runtime:    async.Runtime,
	client:     surf.Client,
	dispatcher: upstream.Dispatcher,
}

// The upstream of this server is the test's own origin on 127.0.0.1, which
// the default policy refuses.
allow_loopback :: proc(_: string, addresses: []net.Endpoint, _: rawptr) -> bool {
	for address in addresses {
		ip, ok := address.address.(net.IP4_Address)
		if !ok || ip != net.IP4_Loopback {
			return false
		}
	}
	return len(addresses) > 0
}

copy_body :: proc(source: ^surf.Response, allocator: mem.Allocator) -> (core.Response, bool) {
	bytes, error := make([]u8, len(source.body), allocator)
	if error != nil {
		return {}, false
	}
	copy(bytes, source.body)
	return {status = core.HTTP_Status(source.status), body = bytes}, true
}

// /fetch?<port> asks the origin on that loopback port through the upstream
// client, which keeps the connection it opened.
route :: proc(data: rawptr, _: ^core.Connection, request: ^core.Request) -> core.Response {
	app := cast(^App)data
	if request.path == "/fetch" {
		port, ok := strconv.parse_int(request.query, 10)
		if !ok || port <= 0 || port > 65535 {
			return {status = .Bad_Request}
		}
		// Surf copies the request while it is submitted.
		buffer: [64]u8
		url := fmt.bprintf(buffer[:], "http://127.0.0.1:%d/", port)
		return upstream.response(&app.dispatcher, request, {method = .GET, url = url}, copy_body)
	}
	return {status = .OK, body = transmute([]u8)string("ok")}
}

main :: proc() {
	assert(len(os.args) == 3)
	cert, ce := os.read_entire_file(os.args[1], context.allocator)
	assert(ce == nil)
	key, ke := os.read_entire_file(os.args[2], context.allocator)
	assert(ke == nil)
	identity, created := credentials.create(cert, key, {}, context.allocator)
	assert(created == .None)
	owner, se := store.create({}, context.allocator)
	assert(se.kind == .None)
	assert(store.replace(owner, &identity).kind == .None)

	app := new(App)
	allocator := rt.heap_allocator()
	assert(async.init(&app.runtime, {workers = 1, task_capacity = 4, io_capacity = 4, allocator = allocator}).kind == .None)
	client := surf.Client_Config {
		http = {allow_http = true, timeout = time.Minute, max_body_size = 8192, address_policy = allow_loopback},
		// The connection to the origin must still be open when the program
		// starts, however slow the machine is.
		idle_timeout = 10 * time.Minute,
	}
	assert(upstream.attach(&app.dispatcher, &app.client, &app.runtime, client, allocator))
	assert(async.start(&app.runtime).kind == .None)

	control: core.Server_Control
	config := core.Server {
		port         = 0,
		workers      = 1,
		handler      = route,
		handler_data = app,
		control      = &control,
		keep_alive   = {enabled = true},
		http3        = {enabled = true, endpoint = {net.IP4_Loopback, 0}, credentials = owner},
		// Not under test; generous for a loaded machine.
		timeouts     = {header = time.Minute, idle = time.Minute, response = time.Minute},
	}
	worker := thread.create_and_start_with_poly_data(&config, proc(c: ^core.Server) {assert(core.serve(c^))})
	assert(worker != nil)
	// Polled until the listeners are published or serve returns, with no bound
	// of its own: the test's ready timeout reports a server that never starts.
	for !core.server_ready(&control) && !thread.is_done(worker) {
		time.sleep(time.Millisecond)
	}
	tcp, tcp_ready := core.server_endpoint(&control)
	udp, udp_ready := core.server_http3_endpoint(&control)
	assert(tcp_ready && udp_ready)
	fmt.printf("READY %d %d\n", tcp.port, udp.port)
	os.flush(os.stdout)

	command: [1]u8
	for {
		n, error := os.read(os.stdin, command[:])
		if n <= 0 || error != nil || command[0] == 'q' {
			break
		}
		if command[0] == 's' {
			// Its standard streams are /dev/null; every other descriptor the
			// server holds is inherited unless it is close-on-exec.
			child, started := os.process_start({command = {"/bin/sleep", "120"}})
			assert(started == nil)
			fmt.printf("CHILD %d\n", child.pid)
			os.flush(os.stdout)
		}
	}
	core.stop_server(&control)
	thread.join(worker)
	// The upstream client is left as it is: the process exits holding its
	// connection to the origin, so only the exit closes it, and only when no
	// other process holds a copy.
}
