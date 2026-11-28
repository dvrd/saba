package saba_e2e_offload_test

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"
import harness "../../support/harness"

// tests/fixtures/apps/offload: one network worker, two job workers that block
// until /release, and stdin commands that stop (s) or drain (d) the server and
// then release (r) the jobs it left behind.
Server :: struct {
	p:       ^harness.Process,
	input:   ^os.File,
	port:    int,
	retired: int,
}

// What /status reports: the pool's running, queued and retained jobs, then
// the runs, drops and finished /work requests the program counted.
Status :: [6]int

launch :: proc(t: ^testing.T, binary: string, budget := 0, fifo := "", mode := "") -> (s: Server, ok: bool) {
	env := []string {
		fmt.tprintf("SABA_OFFLOAD_BUDGET_MS=%d", budget),
		fmt.tprintf("SABA_OFFLOAD_FIFO=%s", fifo),
		fmt.tprintf("SABA_RESOURCE_MODE=%s", mode),
	}
	s.p, s.input = harness.start_with_input(t, {binary}, env) or_return
	s.retired = -1
	s.port, ok = harness.ready(t, s.p)
	if !ok {
		close(t, &s)
	}
	return
}

// Every read and write on a client socket gives up after this.
TIMEOUT :: 4 * time.Second

dial :: proc(t: ^testing.T, s: ^Server, loc := #caller_location) -> net.TCP_Socket {
	conn, error := harness.dial(s.port, TIMEOUT)
	testing.expectf(t, error == nil, "connect: %v", error, loc = loc)
	return conn
}

// One request on its own connection.
exchange :: proc(t: ^testing.T, s: ^Server, path: string, loc := #caller_location) -> harness.Response {
	conn := dial(t, s, loc)
	defer net.close(conn)
	harness.send_text(conn, harness.request_wire(path))
	reply, _ := harness.read_response(t, conn, loc = loc)
	return reply
}

cheap :: proc(t: ^testing.T, s: ^Server, loc := #caller_location) -> bool {
	reply := exchange(t, s, "/cheap")
	return testing.expectf(t, string(reply.body) == "cheap", "cheap route: %d %q", reply.status, reply.body, loc = loc)
}

numbers :: proc(text: string, values: []int) {
	fields := strings.fields(text, context.temp_allocator)
	for &value, index in values {
		if index < len(fields) {
			value, _ = strconv.parse_int(fields[index])
		}
	}
}

status :: proc(t: ^testing.T, s: ^Server) -> (state: Status) {
	numbers(string(exchange(t, s, "/status").body), state[:])
	return
}

// Polls /status until condition holds, for at most 3 seconds.
until :: proc(t: ^testing.T, s: ^Server, condition: proc(state: Status) -> bool, loc := #caller_location) -> (Status, bool) {
	began := time.tick_now()
	for {
		state := status(t, s)
		if condition(state) {
			return state, true
		}
		if time.tick_since(began) >= 3 * time.Second {
			testing.expectf(t, false, "status stayed %v", state, loc = loc)
			return state, false
		}
		time.sleep(5 * time.Millisecond)
	}
}

// Stops (s) or drains (d) the server; the program reports how many /work
// requests had finished once serve returned.
retire :: proc(t: ^testing.T, s: ^Server, mode := "s") -> int {
	harness.send_input(t, s.input, mode)
	line, found := harness.expect_line(t, s.p, "retired ", 8 * time.Second)
	if found {
		s.retired, _ = strconv.parse_int(harness.last_field(line))
	}
	return s.retired
}

// Retires the server if it still serves, releases the blocked jobs and checks
// a clean exit: the program asserts that nothing leaked.
finish :: proc(t: ^testing.T, s: ^Server) {
	if s.retired < 0 {
		retire(t, s)
	}
	harness.send_input(t, s.input, "r")
	harness.expect_line(t, s.p, "stopped ", 8 * time.Second)
	if harness.exited_cleanly(t, s.p) {
		errors := harness.stderr_text(s.p)
		testing.expectf(t, !strings.contains(errors, "Assertion"), "%s", errors)
	}
}

// Finishes a server whose checks passed; one that failed is only killed.
close :: proc(t: ^testing.T, s: ^Server) {
	if s.p == nil {
		return
	}
	if !testing.failed(t) {
		finish(t, s)
	}
	harness.stop(s.p)
	os.close(s.input)
	s.p = nil
}
