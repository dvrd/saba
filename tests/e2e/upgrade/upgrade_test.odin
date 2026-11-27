// Core's protocol upgrade: a raw echo protocol taken over after a 101, with
// bytes that arrived with the request, heads the encoder rejects, a peer that
// resets before the 101 and a shutdown while the upgraded task waits. Every
// session the handler creates is dropped exactly once.
package saba_e2e_upgrade_test

import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"
import harness "../../support/harness"

upgrade_request :: proc(path: string) -> string {
	return strings.concatenate(
		{"GET ", path, " HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: raw-echo\r\n\r\n"},
		context.temp_allocator,
	)
}

switched :: proc(t: ^testing.T, conn: net.TCP_Socket, loc := #caller_location) -> bool {
	head, _ := harness.read_head(t, conn)
	return testing.expectf(t, strings.has_prefix(head, "HTTP/1.1 101 "), "not switched: %q", head, loc = loc)
}

// The peer closes without sending another byte.
ends :: proc(t: ^testing.T, conn: net.TCP_Socket, loc := #caller_location) -> bool {
	b: [1]u8
	n, error := net.recv_tcp(conn, b[:])
	return testing.expectf(t, n == 0 && error == nil, "expected a close, got %d bytes, %v", n, error, loc = loc)
}

// The dropped line of the next session: "dropped <id> <resumes>".
resumes :: proc(t: ^testing.T, p: ^harness.Process) -> int {
	line, found := harness.expect_line(t, p, "dropped ")
	if !found {
		return -1
	}
	count, _ := strconv.parse_int(harness.last_field(line))
	return count
}

@(test)
raw_upgrade_sessions :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 2 * time.Minute)
	work := harness.workdir(t, "upgrade")
	defer os.remove_all(work)
	binary, built := harness.build(t, "tests/e2e/upgrade/server", work)
	if !built {
		return
	}
	p, input, started := harness.start_with_input(t, {binary})
	if !started {
		return
	}
	defer {
		harness.stop(p)
		os.close(input)
	}
	port, ready := harness.ready(t, p)
	if !ready {
		return
	}

	// Bytes sent with the request survive the release of the HTTP arena,
	// whole or with the rest arriving after the 101.
	for early in ([]string{"abcde", "ab"}) {
		conn, _ := harness.dial(port)
		defer net.close(conn)
		harness.send_text(conn, strings.concatenate({upgrade_request("/echo"), early}, context.temp_allocator))
		harness.expect_line(t, p, "created ")
		switched(t, conn)
		if len(early) < 5 {
			harness.send_text(conn, "cde")
		}
		echo, _ := harness.read_n(t, conn, 5)
		testing.expect_value(t, string(echo), "abcde")
		ends(t, conn)
		testing.expectf(t, resumes(t, p) > 0, "%q: session dropped without resuming", early)
	}

	// A continuation without state has no destructor to run.
	{
		conn, _ := harness.dial(port)
		defer net.close(conn)
		harness.send_text(conn, upgrade_request("/stateless"))
		switched(t, conn)
		ends(t, conn)
	}

	// A non-101 upgrade just closes; a 101 head the encoder rejects (a CR LF
	// in a field, a missing or blank protocol) answers 500. Neither resumes.
	for path in ([]string{"/reject", "/badheader", "/missingprotocol", "/emptyprotocol"}) {
		conn, _ := harness.dial(port)
		defer net.close(conn)
		harness.send_text(conn, upgrade_request(path))
		harness.expect_line(t, p, "created ")
		if path == "/reject" {
			ends(t, conn)
		} else {
			reply, _ := harness.read_to_close(conn)
			testing.expectf(t, strings.has_prefix(string(reply), "HTTP/1.1 500 "), "%s: %q", path, reply)
		}
		testing.expectf(t, resumes(t, p) == 0, "%s resumed", path)
	}

	// The peer resets while the handler still runs: the 101 write fails
	// before the session resumes.
	{
		conn, _ := harness.dial(port)
		harness.send_text(conn, upgrade_request("/writefail"))
		harness.expect_line(t, p, "created ")
		harness.reset(conn)
		testing.expect(t, resumes(t, p) == 0, "response write must fail before resume")
	}

	// Shutdown cancels the pending upgraded read and drops the session once.
	conn, _ := harness.dial(port)
	harness.send_text(conn, upgrade_request("/cancel"))
	harness.expect_line(t, p, "created ")
	switched(t, conn)
	harness.send_input(t, input, "s")
	exited := harness.exited_cleanly(t, p, 8 * time.Second)
	net.close(conn)
	if !exited {
		return
	}
	final, _ := harness.expect_line(t, p, "finished ")
	testing.expect_value(t, final, "finished 8 8")
}
