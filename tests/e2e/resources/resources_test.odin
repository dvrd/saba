// Admission against one global budget shared by uploads, buffered responses,
// streams and offloaded jobs, with its snapshots taken outside the HTTP
// budget: each limit rejects with a 503 on its own, cheap routes keep
// answering, and everything is given back when the peers go.
package saba_e2e_resources_test

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import harness "../../support/harness"

PROGRAM :: "tests/fixtures/apps/offload"
KiB :: 1024
MiB :: 1024 * KiB

// Storage follows the bytes received, not the declared length: all but the
// last byte are sent, so the server really holds size bytes yet never
// dispatches the request.
partial_upload :: proc(conn: net.TCP_Socket, size: int) {
	harness.send_text(conn, fmt.tprintf("POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Length: %d\r\n\r\n", size))
	// A rejection mid-upload fails the send; the 503 is already on its way.
	harness.send_text(conn, strings.repeat("x", size - 1, context.temp_allocator))
}

// A connection whose small receive buffer leaves a response unread.
slow_reader :: proc(t: ^testing.T, s: ^Server, path: string) -> net.TCP_Socket {
	conn := dial(t, s)
	_ = net.set_option(conn, .Receive_Buffer_Size, 1024)
	harness.send_text(conn, harness.request_wire(path))
	return conn
}

rejected :: proc(t: ^testing.T, s: ^Server, path: string, loc := #caller_location) -> bool {
	return testing.expectf(t, exchange(t, s, path).status == 503, "%s admitted", path, loc = loc)
}

@(test)
mixed_resource_admission :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Minute)
	work := harness.workdir(t, "resources")
	defer os.remove_all(work)
	binary, built := harness.build(t, PROGRAM, work)
	if !built {
		return
	}
	level_admission(t, binary)
	byte_admission(t, binary)
	stream_and_metadata(t, binary)
	mixed(t, binary)
}

// Operation and connection limits reject on their own, with ample global
// headroom.
level_admission :: proc(t: ^testing.T, binary: string) -> bool {
	for mode in ([]string{"operation", "connection"}) {
		s := launch(t, binary, mode = mode) or_return
		defer close(t, &s)
		{
			conn := dial(t, &s)
			defer net.close(conn)
			partial_upload(conn, MiB)
			reply, _ := harness.read_response(t, conn)
			testing.expectf(t, reply.status == 503, "%s: upload admitted", mode)
		}
		wait_usage(t, &s, proc(v: Usage) -> bool {return v.bytes == 0}) or_return
		values: [6]int
		numbers(string(exchange(t, &s, "/scopes").body), values[:])
		operation_limit, connection_limit, global_limit := values[0], values[1], values[2]
		operation_used, connection_used, global_used := values[3], values[4], values[5]
		testing.expect_value(t, operation_limit, 512 * KiB if mode == "operation" else 32 * MiB)
		testing.expect_value(t, connection_limit, 512 * KiB if mode == "connection" else 64 * MiB)
		testing.expect_value(t, global_limit, 256 * MiB)
		testing.expectf(
			t,
			0 < operation_used && operation_used <= connection_used && connection_used <= global_used,
			"%s: scopes %v",
			mode,
			values,
		)
		cheap(t, &s)
	}
	return true
}

byte_admission :: proc(t: ^testing.T, binary: string) -> bool {
	// An upload is charged for its full backing before the payload arrives:
	// two hold the global 3 MiB, a third is rejected, and resets recover.
	{
		s := launch(t, binary, mode = "bytes") or_return
		defer close(t, &s)
		clients := [2]net.TCP_Socket{dial(t, &s), dial(t, &s)}
		for conn in clients {
			partial_upload(conn, MiB)
		}
		held := wait_usage(t, &s, proc(v: Usage) -> bool {return v.bytes >= 2 * MiB}) or_return
		testing.expectf(t, held.jobs == 0 && held.streams == 0, "uploads hold %v", held)
		{
			conn := dial(t, &s)
			defer net.close(conn)
			partial_upload(conn, MiB)
			reply, _ := harness.read_response(t, conn)
			testing.expect_value(t, reply.status, 503)
		}
		cheap(t, &s)
		testing.expect(t, usage(t, &s).rejected > held.rejected, "rejection not counted")
		for conn in clients {
			harness.reset(conn)
		}
		wait_usage(t, &s, proc(v: Usage) -> bool {return v.bytes == 0}) or_return
	}
	// A slow reader of a buffered response holds its body, and holds it once:
	// the handler allocated it with the request's allocator, so the server
	// sends it from there. Two such readers leave no room for another large
	// response.
	{
		s := launch(t, binary, mode = "bytes") or_return
		defer close(t, &s)
		reply := exchange(t, &s, "/slow")
		testing.expectf(t, reply.status == 200 && len(reply.body) == MiB, "/slow: %d, %d bytes", reply.status, len(reply.body))
		wait_usage(t, &s, proc(v: Usage) -> bool {return v.bytes == 0}) or_return
		first := slow_reader(t, &s, "/slow")
		wait_usage(t, &s, proc(v: Usage) -> bool {return v.bytes >= MiB}) or_return
		// Long enough for a second copy to have been made, were there one.
		time.sleep(200 * time.Millisecond)
		one := usage(t, &s)
		testing.expectf(t, one.bytes < 2 * MiB, "one slow reader holds its body twice: %v", one)
		second := slow_reader(t, &s, "/slow")
		wait_usage(t, &s, proc(v: Usage) -> bool {return v.bytes >= 2 * MiB}) or_return
		rejected(t, &s, "/large")
		cheap(t, &s)
		harness.reset(first)
		harness.reset(second)
		wait_usage(t, &s, proc(v: Usage) -> bool {return v.bytes == 0}) or_return
	}
	return true
}

stream_and_metadata :: proc(t: ^testing.T, binary: string) -> bool {
	// One active streaming exchange blocks a second; its final disposal gives
	// the slot back.
	{
		s := launch(t, binary, mode = "streams") or_return
		defer close(t, &s)
		conn := slow_reader(t, &s, "/stream")
		wait_usage(t, &s, proc(v: Usage) -> bool {return v.streams == 1}) or_return
		rejected(t, &s, "/stream")
		cheap(t, &s)
		harness.reset(conn)
		wait_usage(t, &s, proc(v: Usage) -> bool {return v.streams == 0 && v.bytes == 0}) or_return
	}
	// Connection metadata grows from two slots to 32 while the payload
	// limits stay fixed.
	{
		s := launch(t, binary, mode = "bytes") or_return
		defer close(t, &s)
		clients: [20]net.TCP_Socket
		for &conn in clients {
			conn = dial(t, &s)
		}
		view := wait_usage(t, &s, proc(v: Usage) -> bool {return v.capacity >= 32 && v.nodes >= 42}) or_return
		testing.expectf(t, view.bytes == 0 && view.streams == 0 && view.jobs == 0, "idle connections hold %v", view)
		testing.expectf(t, view.limit == 3 * MiB && view.growths > 0, "after growth: %v", view)
		for conn in clients {
			harness.reset(conn)
		}
		wait_usage(t, &s, proc(v: Usage) -> bool {return v.nodes == 2}) or_return
	}
	return true
}

// Slow readers, an upload, jobs and streams share 20 MiB, two streams and two
// jobs; each kind is rejected at its bound and late jobs outlive the server.
mixed :: proc(t: ^testing.T, binary: string) -> bool {
	s := launch(t, binary, mode = "mixed") or_return
	defer close(t, &s)
	clients := make([dynamic]net.TCP_Socket, context.temp_allocator)
	defer for conn in clients {
		net.close(conn)
	}
	// Three bodies of 4 MiB, each held once.
	for _ in 0 ..< 3 {
		append(&clients, slow_reader(t, &s, "/slow"))
	}
	wait_usage(t, &s, proc(v: Usage) -> bool {return v.bytes >= 12 * MiB}) or_return
	upload := dial(t, &s)
	append(&clients, upload)
	partial_upload(upload, 4 * MiB)
	wait_usage(t, &s, proc(v: Usage) -> bool {return v.bytes >= 16 * MiB}) or_return
	payload := strings.repeat("j", 512 * KiB, context.temp_allocator)
	for _ in 0 ..< 2 {
		conn := dial(t, &s)
		append(&clients, conn)
		harness.send_text(conn, harness.request_wire("/work", "POST", payload))
	}
	wait_usage(t, &s, proc(v: Usage) -> bool {return v.running == 2 && v.jobs == 2}) or_return
	for _ in 0 ..< 2 {
		append(&clients, slow_reader(t, &s, "/stream"))
	}
	held := wait_usage(t, &s, proc(v: Usage) -> bool {return v.streams == 2 && v.bytes > 16 * MiB}) or_return
	testing.expectf(t, held.queued == 0 && held.held == 0, "under pressure: %v", held)
	rejected(t, &s, "/work")
	rejected(t, &s, "/stream")
	rejected(t, &s, "/large")
	for _ in 0 ..< 16 {
		cheap(t, &s)
	}
	pressure := usage(t, &s)
	testing.expectf(t, pressure.jobs == 2 && pressure.running == 2 && pressure.streams == 2, "under pressure: %v", pressure)
	testing.expectf(t, pressure.rejected > held.rejected && pressure.peak <= pressure.limit, "under pressure: %v", pressure)
	retire(t, &s)
	// The jobs are released only after the whole server and runtime retired.
	late := usage(t, &s)
	testing.expectf(t, late.jobs == 2 && late.running == 2 && late.streams == 0, "after retirement: %v", late)
	return testing.expectf(t, late.bytes >= MiB, "after retirement: %v", late)
}
