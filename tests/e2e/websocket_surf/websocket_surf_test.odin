// surf's WebSocket client (client/) against Saba's application WebSockets,
// the websocket_policy fixture over ws: subprotocol selection, text and binary
// echo while the client pings every 50 ms, and a close the client starts.
// surf is built into its own program: the suite cannot import it beside the
// harness package.
package saba_e2e_websocket_surf_test

import "core:fmt"
import "core:testing"
import "core:time"
import harness "../../support/harness"

CLIENT :: "tests/e2e/websocket_surf/client"

@(test)
surf_client :: proc(t: ^testing.T) {
	server, launched := launch(t, "ws")
	if !launched {
		return
	}
	defer close(t, &server)
	client, built := harness.build_shared(t, CLIENT)
	if !built {
		return
	}
	p, started := harness.start(t, {client, fmt.tprintf("%d", server.port)})
	if !started {
		return
	}
	defer harness.stop(p)
	_, passed := harness.expect_line(t, p, "OK surf-websocket", 20 * time.Second)
	code := harness.wait(p)
	if !testing.expectf(t, passed && code == 0, "the client exited with %d\n%s", code, harness.transcript(p)) {
		return
	}
	if m, ok := idle(t, &server); ok {
		testing.expectf(t, m.clean == 1 && m.unclean == 0, "%v", m)
	}
}
