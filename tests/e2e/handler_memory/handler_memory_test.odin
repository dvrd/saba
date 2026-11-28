// A handler that allocates with the default allocator and never frees: what
// it leaves ends with its request, so the process does not grow, and a body
// built that way arrives whole.
package saba_e2e_handler_memory_test

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"
import harness "../../support/harness"

// What /forget leaves behind each time it is asked.
FORGOTTEN :: 4 * 1024 * 1024
REQUESTS :: 64

get :: proc(t: ^testing.T, connection: net.TCP_Socket, target: string) -> (harness.Response, bool) {
	harness.send_text(connection, fmt.tprintf("GET %s HTTP/1.1\r\nHost: a\r\n\r\n", target))
	response, answered := harness.read_response(t, connection)
	if !answered || !testing.expect_value(t, response.status, 200) {
		return {}, false
	}
	return response, true
}

peak :: proc(t: ^testing.T, connection: net.TCP_Socket) -> (int, bool) {
	response, answered := get(t, connection, "/peak")
	if !answered {
		return 0, false
	}
	bytes, parsed := strconv.parse_int(strings.trim_space(string(response.body)))
	return bytes, testing.expectf(t, parsed && bytes > 0, "unexpected peak %q", string(response.body))
}

@(test)
what_a_handler_forgets_ends_with_its_request :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Minute)
	directory := harness.workdir(t, "handler-memory")
	defer os.remove_all(directory)
	binary, built := harness.build(t, "tests/e2e/handler_memory/server", directory)
	if !built {
		return
	}
	p, input, started := harness.start_with_input(t, {binary})
	if !started {
		return
	}
	defer harness.stop(p)
	defer os.close(input)
	line, ready := harness.expect_line(t, p, "READY ", 60 * time.Second)
	if !ready {
		return
	}
	port, _ := strconv.parse_int(strings.trim_space(line[len("READY "):]))
	connection, connected := harness.connect(t, port)
	if !connected {
		return
	}
	defer net.close(connection)
	_ = net.set_option(connection, .Receive_Timeout, time.Minute)

	// A few requests first: the peak then holds one request's worth.
	for _ in 0 ..< 4 {
		if _, ok := get(t, connection, "/forget"); !ok {
			return
		}
	}
	before, measured := peak(t, connection)
	if !measured {
		return
	}
	for _ in 0 ..< REQUESTS {
		if _, ok := get(t, connection, "/forget"); !ok {
			return
		}
	}
	after, again := peak(t, connection)
	if !again {
		return
	}
	// Kept, the requests would have added REQUESTS * FORGOTTEN to the peak.
	grown := after - before
	testing.expectf(
		t,
		grown < REQUESTS * FORGOTTEN / 8,
		"the process grew by %d bytes over %d requests that each forgot %d",
		grown,
		REQUESTS,
		FORGOTTEN,
	)

	// A body the handler built with the default allocator and handed over.
	for size in ([]int{0, 1, 100, 70_000, 3_000_000}) {
		response, answered := get(t, connection, fmt.tprintf("/body?%d", size))
		if !answered || !testing.expect_value(t, len(response.body), size) {
			return
		}
		whole := true
		for value, index in response.body {
			whole &&= value == u8('a' + index % 26)
		}
		testing.expectf(t, whole, "a body of %d bytes arrived changed", size)
	}
}
