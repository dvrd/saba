package saba_websocket

import core "../core"
import "core:testing"

WS79_Policy_Probe :: struct {
	origins, protocols, offered:     int,
	origin_present:                  bool,
	reject_origin, select_unoffered: bool,
}

ws79_origin_policy :: proc(data: rawptr, request: ^core.Request, origin: string, present: bool) -> bool {
	probe := cast(^WS79_Policy_Probe)data
	assert(request.path == "/chat")
	probe.origins += 1
	probe.origin_present = present
	assert(origin == "https://example.test")

	return !probe.reject_origin
}

ws79_protocol_policy :: proc(data: rawptr, _: ^core.Request, offered: []string) -> (string, bool) {
	probe := cast(^WS79_Policy_Probe)data
	probe.protocols += 1
	probe.offered = len(offered)

	if probe.select_unoffered {
		return "other", true
	}

	assert(len(offered) == 2 && offered[0] == "first" && offered[1] == "second")

	return offered[1], true
}

@(test)
origin_policy_is_explicit_and_missing_origin_is_distinct_from_present_origin :: proc(t: ^testing.T) {
	base := ws79_headers()
	headers: [6]core.Header
	copy(headers[:], base[:])
	headers[5] = {"Origin", "https://example.test"}
	request := ws79_request(headers[:], context.allocator)
	response, error := upgrade(&request, {}, {})
	testing.expect_value(t, error.kind, .Origin_Rejected)
	core.discard_response(&response)
	probe := WS79_Policy_Probe {
		reject_origin = true,
	}

	response, error = upgrade(&request, {check_origin = ws79_origin_policy, policy_data = &probe}, {})
	testing.expect_value(t, error.kind, .Origin_Rejected)
	testing.expect_value(t, probe.origins, 1)
	testing.expect(t, probe.origin_present)
	core.discard_response(&response)
	request.headers = base[:]
	response, error = upgrade(&request, {}, {})
	testing.expect_value(t, error.kind, .Invalid_Context)
	core.discard_response(&response)
}

@(test)
protocol_hook_sees_all_offered_header_fields_and_cannot_select_unoffered_protocol :: proc(t: ^testing.T) {
	base := ws79_headers()
	headers: [8]core.Header
	copy(headers[:], base[:])
	headers[5] = {"Origin", "https://example.test"}
	headers[6], headers[7] = {"Sec-WebSocket-Protocol", "first"}, {"Sec-WebSocket-Protocol", "second"}
	request := ws79_request(headers[:], context.allocator)
	probe := WS79_Policy_Probe {
		select_unoffered = true,
	}

	config := Config {
		check_origin       = ws79_origin_policy,
		select_subprotocol = ws79_protocol_policy,
		policy_data        = &probe,
	}

	response, error := upgrade(&request, config, {})
	testing.expect_value(t, error.kind, .Protocol_Rejected)
	testing.expect_value(t, probe.origins, 1)
	testing.expect_value(t, probe.protocols, 1)
	testing.expect_value(t, probe.offered, 2)
	core.discard_response(&response)
	probe.select_unoffered = false
	response, error = upgrade(&request, config, {})
	// The policies passed; this isolated request deliberately has no retained
	// server connection context and must not create an unmanaged session.
	testing.expect_value(t, error.kind, .Invalid_Context)
	testing.expect_value(t, probe.protocols, 2)
	core.discard_response(&response)
}

@(test)
ambiguous_singleton_and_duplicate_protocol_fields_fail_before_policy_hooks :: proc(t: ^testing.T) {
	base := ws79_headers()

	for duplicate in ([3]core.Header {
			{"Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="},
			{"Sec-WebSocket-Version", "13"},
			{"Host", "example.test"},
		}) {
		headers: [6]core.Header
		copy(headers[:], base[:])
		headers[5] = duplicate
		request := ws79_request(headers[:], context.allocator)
		_, error := request_fields(&request)
		testing.expect_value(t, error.kind, .Invalid_Request)
	}

	headers: [7]core.Header
	copy(headers[:], base[:])
	headers[5], headers[6] = {"Sec-WebSocket-Protocol", "same"}, {"Sec-WebSocket-Protocol", "same"}
	request := ws79_request(headers[:], context.allocator)
	_, error := request_fields(&request)
	testing.expect_value(t, error.kind, .Invalid_Request)
	headers[5], headers[6] = {"Origin", "https://example.test"}, {"Origin", "https://other.test"}
	_, error = request_fields(&request)
	testing.expect_value(t, error.kind, .Invalid_Request)
}
