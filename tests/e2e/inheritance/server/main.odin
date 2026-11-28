// The server of e2e/inheritance: HTTP/1.1 on a TCP port and HTTP/3 on a UDP
// port. On "s" it starts a program that outlives it and prints its pid; on
// "q", or when its input closes, it stops and exits.
//
//     server <certificate.pem> <key.pem>
package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:thread"
import "core:time"
import core "shared:saba/core"
import credentials "shared:async/tls/credentials"
import store "shared:async/tls/credentials/store"

route :: proc(_: rawptr, _: ^core.Connection, _: ^core.Request) -> core.Response {
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

	control: core.Server_Control
	config := core.Server {
		port       = 0,
		workers    = 1,
		handler    = route,
		control    = &control,
		keep_alive = {enabled = true},
		http3      = {enabled = true, endpoint = {net.IP4_Loopback, 0}, credentials = owner},
		// Not under test; generous for a loaded machine.
		timeouts   = {header = time.Minute, idle = time.Minute},
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
}
