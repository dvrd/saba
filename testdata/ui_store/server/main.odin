package main

import fixture ".."
import "core:fmt"
import "core:os"
import "core:thread"
import "core:time"
import server "shared:saba/core"

// Loopback-only test process. The parent kills it with an open SQLite
// transaction to exercise durable recovery with a real process boundary.
Host :: struct {
	store:            fixture.State,
	control:          server.Server_Control,
	directory, phase: string,
}

authorize :: proc(req: ^server.Request) -> fixture.Identity {
	switch server.header_value(req, "X-Test-Identity") {
	case "ana":
		return {"north", "ana", .Allowed}
	case "bo":
		return {"north", "bo", .Allowed}
	case "south":
		return {"south", "ana", .Allowed}
	case "revoked":
		return {"north", "ana", .Forbidden}
	}
	return {}
}
may_write :: proc(tenant, caller: string) -> bool {
	return(
		(tenant == "north" && (caller == "ana" || caller == "bo")) ||
		(tenant == "south" && caller == "ana") \
	)
}
observe :: proc(data: rawptr, phase: fixture.Stage, operation: string) {
	host := cast(^Host)data
	if operation != "barrier" || fmt.tprint(phase) != host.phase {
		return
	}
	assert(os.write_entire_file(fmt.tprintf("%s/paused", host.directory), "1") == nil)
	deadline := time.tick_add(time.tick_now(), 25 * time.Second)
	for !os.exists(fmt.tprintf("%s/resume", host.directory)) {
		assert(time.tick_since(deadline) < 0, "receipt barrier timed out")
		time.sleep(2 * time.Millisecond)
	}
}
route :: proc(data: rawptr, conn: ^server.Connection, req: ^server.Request) -> server.Response {
	host := cast(^Host)data
	if req.path == "/health" {
		return {status = .OK, body = transmute([]u8)string("ready")}
	}
	return fixture.handle(&host.store, conn, req)
}
main :: proc() {
	assert(len(os.args) == 3)
	host := Host {
		directory = os.args[1],
		phase     = os.args[2],
	}
	assert(
		fixture.open(
			&host.store,
			fmt.tprintf("%s/receipts.sqlite", host.directory),
			authorize,
			may_write,
		),
	)
	defer fixture.close(&host.store)
	assert(fixture.seed(&host.store, "north") && fixture.seed(&host.store, "south"))
	host.store.checkpoint, host.store.checkpoint_data = observe, &host
	service := thread.create_and_start_with_poly_data(&host, proc(s: ^Host) {
		assert(
			server.serve(
				{
					address = "127.0.0.1",
					port = 0,
					workers = 1,
					handler = route,
					handler_data = s,
					control = &s.control,
				},
			),
		)
	})
	assert(service != nil)
	defer thread.destroy(service)
	for !server.server_ready(&host.control) {thread.yield()}
	endpoint, ok := server.server_endpoint(&host.control)
	assert(ok)
	temporary := fmt.tprintf("%s/port.tmp", host.directory)
	assert(os.write_entire_file(temporary, fmt.tprintf("%d", endpoint.port)) == nil)
	assert(os.rename(temporary, fmt.tprintf("%s/port", host.directory)) == nil)
	thread.join(service)
}
