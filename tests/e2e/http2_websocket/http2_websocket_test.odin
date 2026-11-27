// WebSocket over HTTP/2 (RFC 8441) between Saba's own halves: the
// http2_websocket fixture server and async's HTTP/2 client in client/. Two
// sockets and plain GETs share one connection; a 128 KiB message crosses the
// stream window and the server's body queue; with client certificates the
// identity is rotated between connections.
package saba_e2e_http2_websocket_test

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import harness "../../support/harness"

SERVER :: "tests/fixtures/apps/http2_websocket"
CLIENT :: "tests/e2e/http2_websocket/client"

// Runs the client against the server and checks the server's counters after
// it stopped.
drive :: proc(t: ^testing.T, server_args: []string, client_args: []string) {
	s, launched := launch(t, SERVER, ..server_args)
	if !launched {
		return
	}
	defer release(&s)
	client, built := harness.build_shared(t, CLIENT)
	if !built {
		return
	}
	command := make([dynamic]string, context.temp_allocator)
	append(&command, client, fmt.tprintf("%d", s.port))
	append(&command, ..client_args)
	p, started := harness.start(t, command[:])
	if !started {
		return
	}
	defer harness.stop(p)
	_, passed := harness.expect_line(t, p, "OK native-http2-websocket", 30 * time.Second)
	code := harness.wait(p)
	if !testing.expectf(t, passed && code == 0, "the client exited with %d\n%s", code, harness.transcript(p)) {
		return
	}
	if !finish(t, &s) {
		return
	}
	// The client's two WebSockets, both closed in order.
	line, _ := harness.expect_line(t, s.p, "RESULT ")
	testing.expectf(t, strings.contains(line, "opened=2 dropped=2"), "%s", line)
	testing.expectf(t, strings.contains(line, "resets=0"), "%s", line)
}

@(test)
native_client :: proc(t: ^testing.T) {
	cert := harness.fixture("tls/localhost.pem")
	drive(t, {"server", cert, harness.fixture("tls/rsa2048.pem")}, {cert})
}

// The server requires client certificates from the mTLS root. The client
// presents client.pem, then rotates to client-large.pem: the open connection
// keeps the identity of its handshake and one new dial presents the new one.
@(test)
native_client_certificates :: proc(t: ^testing.T) {
	mtls :: proc(name: string) -> string {
		return harness.fixture(strings.concatenate({"tls/mtls/", name}, context.temp_allocator))
	}
	root := mtls("root.pem")
	drive(
		t,
		{"server-mtls", mtls("server.pem"), mtls("server-key.pem"), root},
		{root, mtls("client.pem"), mtls("client-key.pem"), mtls("client-large.pem"), mtls("client-large-key.pem")},
	)
}
