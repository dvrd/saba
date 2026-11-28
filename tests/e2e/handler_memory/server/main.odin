// The server of e2e/handler_memory. Its handler never names an allocator and
// never frees: /forget allocates FORGOTTEN bytes and writes to every one,
// /body answers with a body built the same way, and /peak answers the largest
// resident size the process has had, in bytes. It stops when its input closes.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:sys/posix"
import "core:thread"
import "core:time"
import core "shared:saba/core"

FORGOTTEN :: 4 * 1024 * 1024

route :: proc(_: rawptr, _: ^core.Connection, request: ^core.Request) -> core.Response {
	switch request.path {
	case "/forget":
		forgotten := make([]u8, FORGOTTEN)
		// Touched, so that the pages count as resident.
		for &value, index in forgotten {
			value = u8(index)
		}
		return {status = .OK, body = transmute([]u8)string("ok")}
	case "/body":
		size, ok := strconv.parse_int(request.query, 10)
		if !ok || size < 0 || size > FORGOTTEN {
			return {status = .Bad_Request}
		}
		body: [dynamic]u8
		for index in 0 ..< size {
			append(&body, u8('a' + index % 26))
		}
		return {status = .OK, body = body[:]}
	case "/peak":
		usage: posix.rusage
		if posix.getrusage(.SELF, &usage) != .OK {
			return {status = .Internal_Server_Error}
		}
		// Bytes on Darwin, kilobytes elsewhere.
		peak := i64(usage.ru_maxrss)
		when ODIN_OS != .Darwin {
			peak *= 1024
		}
		return {status = .OK, body = transmute([]u8)fmt.aprintf("%d", peak)}
	}
	return {status = .Not_Found}
}

main :: proc() {
	control: core.Server_Control
	config := core.Server {
		port       = 0,
		workers    = 1,
		handler    = route,
		control    = &control,
		keep_alive = {enabled = true, max_requests = 1000},
		// Not under test; generous for a loaded machine.
		timeouts   = {header = time.Minute, idle = time.Minute, response = time.Minute},
	}
	worker := thread.create_and_start_with_poly_data(&config, proc(c: ^core.Server) {assert(core.serve(c^))})
	assert(worker != nil)
	// Polled until the listener is published or serve returns, with no bound
	// of its own: the test's ready timeout reports a server that never starts.
	for !core.server_ready(&control) && !thread.is_done(worker) {
		time.sleep(time.Millisecond)
	}
	endpoint, ready := core.server_endpoint(&control)
	assert(ready)
	fmt.printf("READY %d\n", endpoint.port)
	os.flush(os.stdout)

	command: [1]u8
	for {
		n, error := os.read(os.stdin, command[:])
		if n <= 0 || error != nil {
			break
		}
	}
	core.stop_server(&control)
	thread.join(worker)
}
