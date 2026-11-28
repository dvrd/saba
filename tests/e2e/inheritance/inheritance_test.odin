// A program the server starts must inherit none of its sockets: the server
// starts one that outlives it, exits, and nothing of the server may be left
// behind in that program.
package saba_e2e_inheritance_test

import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import harness "../../support/harness"

@(test)
started_programs_inherit_none_of_the_servers_sockets :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Minute)
	directory := harness.workdir(t, "inheritance")
	defer os.remove_all(directory)
	binary, built := harness.build(t, "tests/e2e/inheritance/server", directory)
	if !built {
		return
	}
	p, input, started := harness.start_with_input(
		t,
		{binary, harness.fixture("tls/localhost.pem"), harness.fixture("tls/rsa2048.pem")},
	)
	if !started {
		return
	}
	defer harness.stop(p)
	defer os.close(input)

	line, ready := harness.expect_line(t, p, "READY ", 60 * time.Second)
	if !ready {
		return
	}
	ports := strings.fields(line, context.temp_allocator)
	if !testing.expectf(t, len(ports) == 3, "unexpected ready line %q", line) {
		return
	}
	tcp, _ := strconv.parse_int(ports[1])
	udp, _ := strconv.parse_int(ports[2])

	// A connection the server has accepted and keeps alive.
	connection, connected := harness.connect(t, tcp)
	if !connected {
		return
	}
	defer net.close(connection)
	harness.send_text(connection, "GET / HTTP/1.1\r\nHost: a\r\n\r\n")
	response, answered := harness.read_response(t, connection)
	if !answered || !testing.expect_value(t, response.status, 200) {
		return
	}

	// The server starts a program that outlives it, then exits.
	if !harness.send_input(t, input, "s") {
		return
	}
	child, spawned := harness.expect_line(t, p, "CHILD ", 30 * time.Second)
	if !spawned {
		return
	}
	pid, _ := strconv.parse_int(strings.trim_space(child[len("CHILD "):]))
	if !testing.expectf(t, pid > 1, "unexpected child line %q", child) {
		return
	}
	defer posix.kill(posix.pid_t(pid), .SIGKILL)
	if !harness.send_input(t, input, "q") || !harness.exited_cleanly(t, p) {
		return
	}

	// The accepted connection ended with the server: the program holds no copy.
	testing.expect(
		t,
		harness.await_close(connection, 30 * time.Second),
		"the started program holds the accepted connection open",
	)

	// The TCP port is closed: the program holds no copy of the listening socket.
	if lingering, dialed := harness.dial(tcp); dialed == nil {
		net.close(lingering)
		testing.expect(t, false, "the started program still listens on the server's TCP port")
	}

	// The UDP port is free: the program holds no copy of the HTTP/3 socket.
	if socket, bound := net.make_bound_udp_socket(net.IP4_Loopback, udp); bound == nil {
		net.close(socket)
	} else {
		testing.expectf(t, false, "the started program still holds the server's UDP port: %v", bound)
	}
}
