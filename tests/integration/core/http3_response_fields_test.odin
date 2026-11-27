package saba_core

import "shared:async/tls"
import tlscredentials "shared:async/tls/credentials"
import credential_store "shared:async/tls/credentials/store"
import "core:net"
import http3 "shared:async/http/v3"
import "core:testing"
import "core:thread"
import "core:time"

H3_Fields_Server :: struct {
	config:  Server,
	control: Server_Control,
	ok:      bool,
}

h3_fields_handler :: proc(_: rawptr, _: ^Connection, request: ^Request) -> Response {
	switch request.path {
	case "/hop":
		headers := make([]Header, 5, request.allocator)
		headers[0] = {"Connection", "close"}
		headers[1] = {"Keep-Alive", "timeout=5"}
		headers[2] = {"Transfer-Encoding", "chunked"}
		headers[3] = {"Upgrade", "h2c"}
		headers[4] = {"X-Kept", "yes"}
		return {status = .OK, headers = headers, body = transmute([]u8)string("hop-filtered")}
	case "/flood":
		headers := make([]Header, 80, request.allocator)
		for &header in headers {
			header = {"x-filler", "value"}
		}
		return {status = .OK, headers = headers, body = transmute([]u8)string("flood")}
	case "/split":
		headers := make([]Header, 1, request.allocator)
		headers[0] = {"x-note", "one\r\ntwo"}
		return {status = .OK, headers = headers, body = transmute([]u8)string("split")}
	}
	return {status = .OK, body = transmute([]u8)string("plain")}
}

// The wire layer treats an invalid response field section as a connection
// error. Connection-specific handler headers used to reach it unfiltered, so
// one `Connection: close` tore down every stream on the client's connection.
@(test)
http3_connection_specific_and_unrepresentable_response_headers_stay_stream_local :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	testing.expect(t, http3_skip_response_header("connection"))
	testing.expect(t, http3_skip_response_header("transfer-encoding"))
	testing.expect(t, http3_skip_response_header(":status"))
	testing.expect(t, !http3_skip_response_header("content-length"))
	testing.expect(t, http3_field_valid("x-ok", "fine value"))
	testing.expect(t, !http3_field_valid("x bad", "v"))
	testing.expect(t, !http3_field_valid("x-ok", "a\nb"))
	testing.expect(t, !http3_field_valid("", "v"))

	certificate := #load("../../tests/fixtures/tls/localhost.pem")
	credential, created := tlscredentials.create(
		certificate,
		#load("../../tests/fixtures/tls/rsa2048.pem"),
		{},
		context.allocator,
	)
	assert(created == .None)
	store, stored := credential_store.create({}, context.allocator)
	assert(stored.kind == .None && credential_store.replace(store, &credential).kind == .None)
	defer credential_store.destroy(&store)
	roots: tls.Root_Pool
	assert(tls.root_pool_parse(&roots, certificate) == nil)
	defer tls.root_pool_destroy(&roots)
	fixture: H3_Fields_Server
	fixture.config = {
		handler = h3_fields_handler,
		control = &fixture.control,
		workers = 1,
		http3 = {enabled = true, endpoint = {net.IP4_Loopback, 0}, credentials = store},
	}
	worker := thread.create_and_start_with_poly_data(&fixture, proc(f: ^H3_Fields_Server) {f.ok = serve(f.config)})
	assert(worker != nil)
	defer {
		stop_server(&fixture.control)
		thread.join(worker)
		thread.destroy(worker)
		testing.expect(t, fixture.ok)
	}
	// A startup bound only: generous, since a loaded machine can take seconds
	// to start serve, and nothing here measures it.
	until := time.tick_add(time.tick_now(), 60 * time.Second)
	for !server_ready(&fixture.control) && time.tick_diff(time.tick_now(), until) > 0 {
		thread.yield()
	}
	endpoint, ready := server_http3_endpoint(&fixture.control)
	if !testing.expect(t, ready && endpoint.port > 0) {
		return
	}

	exchange :: proc(endpoint: net.Endpoint, roots: ^tls.Root_Pool, path: string) -> http3.Client_Result {
		return http3.client_exchange_request(
			endpoint,
			"127.0.0.1",
			{method = "GET", target = path, authority = "127.0.0.1"},
			roots.roots[:roots.count],
			time.time_add(time.now(), 5 * time.Second),
		)
	}

	hop := exchange(endpoint, &roots, "/hop")
	testing.expect(t, hop.error == .None, h3_test_error(&hop))
	testing.expect_value(t, hop.status, 200)
	testing.expect_value(t, h3_test_body(&hop), "hop-filtered")
	// Only x-kept survives beside whatever the transport adds itself.
	testing.expect(t, hop.header_count >= 1 && hop.header_count <= 3)

	flood := exchange(endpoint, &roots, "/flood")
	testing.expect(t, flood.error == .None, h3_test_error(&flood))
	testing.expect_value(t, flood.status, 500)

	split := exchange(endpoint, &roots, "/split")
	testing.expect(t, split.error == .None, h3_test_error(&split))
	testing.expect_value(t, split.status, 500)
}
