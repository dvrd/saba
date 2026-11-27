// Saba's HTTP/3 server driven by its own ecosystem's clients (surf and
// async's HTTP/3 client), each a program of its own: HEAD semantics,
// WebSockets over extended CONNECT, graceful shutdown with GOAWAY, and
// trailers. The same behaviours against independent implementations are in
// tests/interop/http3.
package e2e_http3_test

import harness "../../support/harness"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

CERTIFICATE :: "tests/fixtures/tls/localhost.pem"
KEY :: "tests/fixtures/tls/rsa2048.pem"

// Builds the server and the client, runs the client (with arguments, then the
// server's port and the certificate) until it prints its OK line and exits,
// stops the server and returns the RESULT line it printed.
exercise :: proc(
	t: ^testing.T,
	server_source, client_source: string,
	arguments: ..string,
) -> string {
	testing.set_fail_timeout(t, 3 * time.Minute)
	directory := harness.workdir(t, "e2e-http3")
	defer os.remove_all(directory)
	server_binary, server_built := harness.build(t, server_source, directory)
	client_binary, client_built := harness.build(t, client_source, directory)
	if !server_built || !client_built {
		return ""
	}
	server, input, started := harness.start_with_input(t, {server_binary, CERTIFICATE, KEY})
	if !started {
		return ""
	}
	defer harness.stop(server)
	port, ready := harness.ready(t, server)
	if !ready {
		os.close(input)
		return ""
	}
	command := make([dynamic]string, context.temp_allocator)
	append(&command, client_binary)
	append(&command, ..arguments)
	append(&command, fmt.tprintf("%d", port), CERTIFICATE)
	if client, client_started := harness.start(t, command[:]); client_started {
		harness.expect_line(t, client, "OK ", 30 * time.Second)
		harness.exited_cleanly(t, client)
		harness.stop(client)
	}
	harness.send_input(t, input, "s")
	os.close(input)
	if !harness.exited_cleanly(t, server) {
		return ""
	}
	results := harness.lines_with(server, "RESULT ")
	return results[len(results) - 1] if len(results) > 0 else ""
}

// HEAD /head204, /head304 and /head200 on one pooled connection.
@(test)
head_semantics :: proc(t: ^testing.T) {
	result := exercise(t, "tests/fixtures/apps/http3_probe", "tests/e2e/http3/head_client")
	testing.expect_value(t, result, "RESULT calls=3")
}

// Four tunnels (one ended by its idle timeout, one cancelled), three echoed
// messages and eight plain requests; Saba's resource scope is empty after.
@(test)
websocket :: proc(t: ^testing.T) {
	result := exercise(
		t,
		"tests/fixtures/apps/http3_websocket",
		"tests/e2e/http3/websocket_client",
		"websocket",
	)
	testing.expect_value(t, result, "RESULT opened=4 dropped=4 messages=3 http=8 resets=1")
}

// Two tunnels, three plain requests (/drain, /health, /global-drain) and one
// slow streamed response; the echoes repeat until the client saw GOAWAY.
@(test)
shutdown :: proc(t: ^testing.T) {
	result := exercise(
		t,
		"tests/fixtures/apps/http3_shutdown",
		"tests/e2e/http3/websocket_client",
		"shutdown",
	)
	testing.expectf(
		t,
		strings.has_prefix(result, "RESULT opened=2 dropped=2 messages=") &&
		strings.has_suffix(result, " http=3 resets=0 stream_drops=1"),
		"got %q",
		result,
	)
}

// Two POSTs with request trailers, with and without a body.
@(test)
trailers :: proc(t: ^testing.T) {
	result := exercise(t, "tests/fixtures/apps/http3_trailers", "tests/e2e/http3/trailers_client")
	testing.expect_value(t, result, "RESULT calls=2")
}
