package saba_core

import http3 "shared:async/http/v3"
import async "shared:async"
import "core:testing"

// HTTP semantics of the HTTP/3 request callback, driven directly through
// http3_poll as the listener drives it: what reaches the handler, and what the
// wire layer is handed to send.

H3_Semantics :: struct {
	calls, drops: int,
	host:         string,
	hosts:        int,
	trailer:      string,
}

h3_semantics_handler :: proc(data: rawptr, _: ^Connection, request: ^Request) -> Response {
	probe := cast(^H3_Semantics)data
	probe.calls += 1
	probe.host = header_value(request, "host")
	probe.hosts = 0
	for header in request.headers {
		if header.name == "host" || header.name == "Host" {
			probe.hosts += 1
		}
	}
	probe.trailer = ""
	for trailer in request.trailers {
		if trailer.name == "x-checksum" {
			probe.trailer = trailer.value
		}
	}

	switch request.path {
	case "/trailers":
		trailers := make([]Header, 1, request.allocator)
		trailers[0] = {"Grpc-Status", "0"}
		return {status = .OK, body = transmute([]u8)string("body"), trailers = trailers}
	case "/refuse-upgrade":
		return {status = .Forbidden, upgrade = {data = probe, resume = h3_semantics_resume, drop = h3_semantics_drop}}
	case "/refuse":
		return {status = .Forbidden, body = transmute([]u8)string("no")}
	case "/fields-63", "/fields-64":
		headers := make([]Header, 63 if request.path == "/fields-63" else 64, request.allocator)
		for &header in headers {
			header = {"x-filler", "value"}
		}
		return {status = .OK, headers = headers, body = transmute([]u8)string("fields")}
	}

	return {status = .OK, body = transmute([]u8)string("seven b")}
}

h3_semantics_resume :: proc(_: rawptr, _: ^Upgrade_IO) -> async.Resume_Result {
	return .Done
}

h3_semantics_drop :: proc(data: rawptr) {
	(cast(^H3_Semantics)data).drops += 1
}

h3_semantics_limit :: proc(_: ^Request) -> int {
	return 7
}

h3_semantics_init :: proc(runtime: ^Server_Runtime, owner: ^Http3, probe: ^H3_Semantics) {
	h3_unit_init(runtime, owner, nil)
	runtime.config.handler = h3_semantics_handler
	runtime.config.handler_data = probe
	runtime.config.request_body_limit = h3_semantics_limit
	owner.config.handler = h3_semantics_handler
	owner.config.handler_data = probe
}

// One request through the callback; the response is checked before release.
h3_semantics_poll :: proc(owner: ^Http3, request: ^http3.Server_Request) -> (http3.Server_Response, http3.Response_Status) {
	response: http3.Server_Response
	status := http3_poll(owner, request, &response)
	return response, status
}

// A body of exactly the configured limit reaches the handler; one octet more
// is answered 413 without it. An extended CONNECT for a protocol Saba does not
// implement is answered 501 without it.
@(test)
http3_body_limit_boundary_and_unknown_protocols_are_answered_before_the_handler :: proc(t: ^testing.T) {
	runtime: Server_Runtime
	owner: Http3
	probe: H3_Semantics
	h3_semantics_init(&runtime, &owner, &probe)
	defer h3_unit_destroy(&runtime)

	at_limit := http3.Server_Request {
		method = "POST",
		target = "/",
		body   = transmute([]u8)string("payload"),
	}
	response, status := h3_semantics_poll(&owner, &at_limit)
	testing.expect_value(t, status, http3.Response_Status.Ready)
	testing.expect_value(t, response.status, 200)
	testing.expect_value(t, probe.calls, 1)
	http3_release(&owner, &at_limit)

	over := http3.Server_Request {
		method = "POST",
		target = "/",
		body   = transmute([]u8)string("payload!"),
	}
	response, status = h3_semantics_poll(&owner, &over)
	testing.expect_value(t, status, http3.Response_Status.Ready)
	testing.expect_value(t, response.status, 413)
	testing.expect_value(t, probe.calls, 1)
	http3_release(&owner, &over)

	connect: http3.Connect_Stream
	udp := http3.Server_Request {
		method   = "CONNECT",
		target   = "/.well-known/masque/udp/192.0.2.6/443/",
		protocol = "connect-udp",
		connect  = &connect,
	}
	response, status = h3_semantics_poll(&owner, &udp)
	testing.expect_value(t, status, http3.Response_Status.Ready)
	testing.expect_value(t, response.status, 501)
	testing.expect(t, response.duplex.resume == nil, "an unknown protocol was given a tunnel")
	testing.expect_value(t, probe.calls, 1)
	http3_release(&owner, &udp)
	testing.expect_value(t, runtime.active_connections, 0)
}

// A WebSocket handler that refuses with an upgrade still attached opens no
// tunnel: only 200 does (RFC 9220). Its upgrade is dropped once. A refusal
// without an upgrade is delivered as written.
@(test)
http3_websocket_refusals_open_no_tunnel :: proc(t: ^testing.T) {
	runtime: Server_Runtime
	owner: Http3
	probe: H3_Semantics
	h3_semantics_init(&runtime, &owner, &probe)
	defer h3_unit_destroy(&runtime)

	for target in ([]string{"/refuse-upgrade", "/refuse"}) {
		connect: http3.Connect_Stream
		request := http3.Server_Request {
			method   = "CONNECT",
			target   = target,
			protocol = "websocket",
			connect  = &connect,
		}
		response, status := h3_semantics_poll(&owner, &request)
		testing.expect_value(t, status, http3.Response_Status.Ready)
		testing.expect(t, response.duplex.resume == nil, "a refused WebSocket was given a tunnel")
		if target == "/refuse-upgrade" {
			testing.expect_value(t, response.status, 500)
		} else {
			testing.expect_value(t, response.status, 403)
			testing.expect_value(t, string(response.body), "no")
		}
		http3_release(&owner, &request)
	}
	testing.expect_value(t, probe.drops, 1)
	testing.expect_value(t, runtime.active_connections, 0)
}

// RFC 9114 section 4.2: field names are lowercase on the wire, trailers too.
// A HEAD response carries the length a GET would have and no content.
@(test)
http3_response_trailers_are_lowercased_and_head_keeps_the_length :: proc(t: ^testing.T) {
	runtime: Server_Runtime
	owner: Http3
	probe: H3_Semantics
	h3_semantics_init(&runtime, &owner, &probe)
	defer h3_unit_destroy(&runtime)

	request := http3.Server_Request {
		method = "GET",
		target = "/trailers",
	}
	response, status := h3_semantics_poll(&owner, &request)
	testing.expect_value(t, status, http3.Response_Status.Ready)
	if testing.expect_value(t, len(response.trailers), 1) {
		testing.expect_value(t, response.trailers[0].name, "grpc-status")
		testing.expect_value(t, response.trailers[0].value, "0")
	}
	http3_release(&owner, &request)

	request = {
		method = "HEAD",
		target = "/",
	}
	response, status = h3_semantics_poll(&owner, &request)
	testing.expect_value(t, status, http3.Response_Status.Ready)
	testing.expect_value(t, response.status, 200)
	testing.expect_value(t, len(response.body), 0)
	length := ""
	for field in response.headers {
		if field.name == "content-length" {
			length = field.value
		}
	}
	testing.expect_value(t, length, "7")
	http3_release(&owner, &request)
}

// A response field section holds :status and at most 63 other fields, the
// most the wire layer sends. 63 are delivered; 64 become an ordinary 500
// rather than a section the wire layer would reset the stream over.
@(test)
http3_response_field_count_boundary_is_63 :: proc(t: ^testing.T) {
	runtime: Server_Runtime
	owner: Http3
	probe: H3_Semantics
	h3_semantics_init(&runtime, &owner, &probe)
	defer h3_unit_destroy(&runtime)

	for target in ([]string{"/fields-63", "/fields-64"}) {
		request := http3.Server_Request {
			method = "GET",
			target = target,
		}
		response, status := h3_semantics_poll(&owner, &request)
		testing.expect_value(t, status, http3.Response_Status.Ready)
		if target == "/fields-63" {
			testing.expect_value(t, response.status, 200)
			testing.expect_value(t, len(response.headers), 63)
			testing.expect_value(t, string(response.body), "fields")
		} else {
			testing.expect_value(t, response.status, 500)
			testing.expect_value(t, len(response.headers), 0)
		}
		http3_release(&owner, &request)
	}
}

// Http3_Config.max_body caps a buffered response body: one of exactly the cap
// is sent, one octet more fails the request.
@(test)
http3_max_body_admits_a_body_of_exactly_the_cap :: proc(t: ^testing.T) {
	runtime: Server_Runtime
	owner: Http3
	probe: H3_Semantics
	h3_semantics_init(&runtime, &owner, &probe)
	defer h3_unit_destroy(&runtime)

	// The default response body is "seven b".
	for cap in ([]int{7, 6}) {
		owner.config.max_body = cap
		owner.rejected = false
		request := http3.Server_Request {
			method = "GET",
			target = "/",
		}
		response, status := h3_semantics_poll(&owner, &request)
		if cap == 7 {
			testing.expect_value(t, status, http3.Response_Status.Ready)
			testing.expect_value(t, string(response.body), "seven b")
			testing.expect(t, !owner.rejected, "a body of exactly max_body was rejected")
		} else {
			testing.expect_value(t, status, http3.Response_Status.Failed)
			testing.expect(t, owner.rejected, "a body over max_body was not rejected")
		}
		http3_release(&owner, &request)
	}
	testing.expect_value(t, runtime.active_connections, 0)
}

// :authority is the target authority (RFC 9114 section 4.3.1). The handler
// sees it as its one Host header, never a conflicting legacy Host field, and
// it sees the request's trailers.
@(test)
http3_authority_is_the_only_host_and_trailers_reach_the_handler :: proc(t: ^testing.T) {
	runtime: Server_Runtime
	owner: Http3
	probe: H3_Semantics
	h3_semantics_init(&runtime, &owner, &probe)
	defer h3_unit_destroy(&runtime)

	fields := []http3.Field{{name = "host", value = "legacy.invalid"}}
	trailers := []http3.Field{{name = "x-checksum", value = "c0ffee"}}
	request := http3.Server_Request {
		method    = "POST",
		target    = "/",
		authority = "fixture.invalid",
		headers   = fields,
		trailers  = trailers,
		body      = transmute([]u8)string("abc"),
	}
	_, status := h3_semantics_poll(&owner, &request)
	testing.expect_value(t, status, http3.Response_Status.Ready)
	testing.expect_value(t, probe.calls, 1)
	testing.expect_value(t, probe.host, "fixture.invalid")
	testing.expect_value(t, probe.hosts, 1)
	testing.expect_value(t, probe.trailer, "c0ffee")
	http3_release(&owner, &request)
}
