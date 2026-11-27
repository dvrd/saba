package saba_core

import "shared:async/tls"
import "core:fmt"
import "core:net"
import "core:sync"
import "core:thread"
import "core:time"
import http3 "shared:async/http/v3"

H3_Test_Client :: struct {
	endpoint:  net.Endpoint,
	request:   http3.Client_Request,
	timeout:   time.Duration,
	untrusted: bool,
	cancelled: bool,
	worker:    ^thread.Thread,
	result:    http3.Client_Result,
}

h3_test_client_start :: proc(client: ^H3_Test_Client) {
	if client.request.method == "" {
		client.request.method = "GET"
	}
	client.request.authority = "synthetic.invalid"
	client.request.cancel = proc(data: rawptr) -> bool {
		return sync.atomic_load(cast(^bool)data)
	}
	client.request.cancel_data = &client.cancelled
	client.worker = thread.create_and_start_with_poly_data(client, h3_test_client_run)
	assert(client.worker != nil)
}

h3_test_client_run :: proc(client: ^H3_Test_Client) {
	roots: tls.Root_Pool
	defer tls.root_pool_destroy(&roots)
	if !client.untrusted {
		assert(tls.root_pool_parse(&roots, transmute([]u8)string(HTTPS80_TEST_CERT)) == nil)
	}
	client.result = http3.client_exchange_request(
		client.endpoint,
		"synthetic.invalid",
		client.request,
		roots.roots[:roots.count],
		time.time_add(time.now(), client.timeout),
	)
}

h3_test_client_join :: proc(client: ^H3_Test_Client) {
	if client.worker != nil {
		thread.join(client.worker)
		thread.destroy(client.worker)
		client.worker = nil
	}
}

h3_test_client_cancel :: proc(client: ^H3_Test_Client) {
	sync.atomic_store(&client.cancelled, true)
	h3_test_client_join(client)
}

h3_test_exchange :: proc(
	port: int,
	request: http3.Client_Request,
	timeout: time.Duration,
	listener: ^Http3 = nil,
	untrusted := false,
) -> http3.Client_Result {
	client := H3_Test_Client {
		endpoint  = {net.IP4_Loopback, port},
		request   = request,
		timeout   = timeout,
		untrusted = untrusted,
	}
	h3_test_client_start(&client)
	defer h3_test_client_cancel(&client)
	if listener != nil {
		for !thread.is_done(client.worker) {
			if !http3.listener_step(&listener.live) {
				sync.atomic_store(&client.cancelled, true)
				break
			}
			time.sleep(time.Millisecond)
		}
	}
	h3_test_client_join(&client)
	return client.result
}

h3_test_body :: proc(result: ^http3.Client_Result) -> string {
	return string(result.body[:result.body_len])
}

h3_test_error :: proc(result: ^http3.Client_Result) -> string {
	return fmt.tprintf("%v %s", result.error, string(result.reason[:result.reason_len]))
}
