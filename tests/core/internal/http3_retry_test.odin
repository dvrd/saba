package saba_core

import surf "shared:surf"
import "core:crypto"
import "shared:async/tls"
import tlscredentials "shared:async/tls/credentials"
import credential_store "shared:async/tls/credentials/store"
import "core:fmt"
import "core:net"
import "shared:async/quic"
import http3 "shared:async/http/v3"
import "core:testing"
import "core:thread"
import "core:time"

Retry_Saba_Probe :: struct {
	calls:     int,
	validated: bool,
}
Retry_Saba_Server :: struct {
	config:  Server,
	control: Server_Control,
	ok:      bool,
}
retry_saba_handler :: proc(data: rawptr, conn: ^Connection, request: ^Request) -> Response {
	probe := cast(^Retry_Saba_Probe)data
	probe.calls += 1
	// The handler runs on the HTTP3 listener task, so inspecting its current
	// peer table is serialized with admission. Application code need not do this.
	peers := 0

	if conn != nil && conn._task != nil {
		for peer in conn._task.runtime.http3.live.peers {
			if peer != nil {
				peers += 1

				if !peer.retry.validated {
					probe.validated = false
				}
			}
		}
	}

	if peers == 0 {
		probe.validated = false
	}

	return {status = .OK, body = transmute([]u8)string("saba-retry-validated")}
}
@(test)
http3_retry_normal_serve_uses_explicit_store_before_dispatch :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 15 * time.Second)
	credential, ce := tlscredentials.create(
		#load("../../tests/testdata/tls/localhost.pem"),
		#load("../../tests/testdata/tls/rsa2048.pem"),
		{},
		context.allocator,
	)
	assert(ce == .None)
	store, se := credential_store.create({}, context.allocator)
	assert(se.kind == .None)
	assert(credential_store.replace(store, &credential).kind == .None)
	defer credential_store.destroy(&store)
	tokens: quic.Retry_Tokens
	secret: [32]u8
	crypto.rand_bytes(secret[:])
	assert(quic.retry_tokens_init(&tokens, secret[:], 1, 30, time.to_unix_seconds(time.now())) == .None)
	crypto.zero_explicit(&secret, size_of(secret))
	defer quic.retry_tokens_destroy(&tokens)
	probe := Retry_Saba_Probe {
		validated = true,
	}; fixture: Retry_Saba_Server
	fixture.config = {
		handler = retry_saba_handler,
		handler_data = &probe,
		control = &fixture.control,
		workers = 2,
		http3 = {enabled = true, endpoint = {net.IP4_Loopback, 0}, credentials = store, retry = &tokens},
	}

	worker := thread.create_and_start_with_poly_data(&fixture, proc(f: ^Retry_Saba_Server) {f.ok = serve(f.config)})
	defer thread.destroy(worker)
	joined := false

	defer if !joined {
		stop_server(&fixture.control)
		thread.join(worker)
	}

	until := time.tick_add(time.tick_now(), 5 * time.Second)
	for !server_ready(&fixture.control) && time.tick_diff(time.tick_now(), until) > 0 {thread.yield()}
	endpoint, ready := server_http3_endpoint(&fixture.control)

	if !testing.expect(t, ready && endpoint.port > 0) {
		return
	}

	url_buffer: [96]u8
	url := fmt.bprintf(url_buffer[:], "https://127.0.0.1:%d/retry", endpoint.port)
	roots: tls.Root_Pool
	assert(tls.root_pool_parse(&roots, #load("../../tests/testdata/tls/localhost.pem")) == nil)
	defer tls.root_pool_destroy(&roots)
	native := http3.client_exchange_request(
		endpoint, "127.0.0.1", {method = "GET", target = "/retry", authority = "127.0.0.1"},
		roots.roots[:roots.count], time.time_add(time.now(), 5 * time.Second),
	)
	testing.expect(t, native.error == .None, h3_test_error(&native))
	testing.expect_value(t, native.status, 200)
	testing.expect_value(t, h3_test_body(&native), "saba-retry-validated")
	response, surf_error := surf.execute(
		{method = .GET, url = url},
		{http3 = true, timeout = 8 * time.Second, tls = {root_cas = roots.roots[:roots.count]}},
	)
	defer surf.response_destroy(&response)
	testing.expect_value(t, surf_error.kind, .None)
	testing.expect_value(t, response.status, 200)
	testing.expect_value(t, string(response.body), "saba-retry-validated")
	stop_server(&fixture.control)
	thread.join(worker)
	joined = true
	testing.expect(t, fixture.ok && probe.validated)
	testing.expect_value(t, probe.calls, 2)
}
