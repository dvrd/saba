// HTTP/3 trailers between Saba and nghttp3: request trailers reach the
// handler, response trailers come back as their own field section (not merged
// into the head), and a request with a forbidden trailer is reset with
// H3_MESSAGE_ERROR while its connection keeps serving.
package trailers_test

import nghttp3 "../../../support/c/nghttp3"
import peer "../peer"
import "core:fmt"
import "core:testing"
import "core:time"

SERVER :: "tests/fixtures/apps/http3_trailers"

// POST /trailers with a Host header that disagrees with :authority (Saba
// takes :authority) and the body.
post :: proc(cl: ^peer.Client, body: string, trailer: peer.Field) -> ^peer.Stream {
	headers := []peer.Field {
		{"host", "evil.invalid"},
		{"content-length", fmt.tprintf("%d", len(body))},
	}
	trailers := []peer.Field{trailer}
	s := peer.request(
		cl,
		{
			method = "POST",
			path = "/trailers",
			headers = headers,
			body = transmute([]u8)body,
			trailers = trailers,
		},
	)
	if s != nil {
		peer.await(s)
	}
	return s
}

expect_echo :: proc(t: ^testing.T, cl: ^peer.Client, body: string, loc := #caller_location) {
	s := post(cl, body, {"x-request-checksum", "abc"})
	if !testing.expectf(
		t,
		s != nil && s.ended && peer.status(s) == 200,
		"POST of %q: %s",
		body,
		peer.describe(cl),
		loc = loc,
	) {
		return
	}
	testing.expect_value(t, string(s.body[:]), "echo", loc = loc)
	testing.expectf(
		t,
		s.sections == 1 && len(s.trailers) == 1 && s.trailers[0] == {"x-response-checksum", "ack"},
		"response trailers: %d sections, %v",
		s.sections,
		s.trailers[:],
		loc = loc,
	)
	testing.expect_value(t, peer.header(s, "x-response-checksum"), "", loc = loc)
}

@(test)
independent_client :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 60 * time.Second)
	server, ok := peer.serve(t, SERVER, peer.CERTIFICATE, peer.KEY)
	if !ok {
		return
	}
	defer peer.stop(t, &server)
	cl: peer.Client
	defer peer.destroy(&cl)
	if !testing.expect(t, peer.connect(&cl, {port = server.port, roots = peer.CERTIFICATE})) {
		return
	}
	expect_echo(t, &cl, "payload")
	expect_echo(t, &cl, "")
	// Content-Length is not allowed in trailers (RFC 9110 section 6.5.1).
	bad := post(&cl, "payload", {"content-length", "9"})
	testing.expectf(
		t,
		bad != nil && bad.reset == nghttp3.H3_MESSAGE_ERROR,
		"the malformed request: reset 0x%x, %s",
		bad.reset if bad != nil else -1,
		peer.describe(&cl),
	)
	expect_echo(t, &cl, "payload")
	testing.expect(t, !cl.closed, "the malformed request closed the connection")
	peer.close(&cl)
	testing.expect_value(t, peer.stop(t, &server), "RESULT calls=3")
}
