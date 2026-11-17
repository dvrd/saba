package saba_core

import "core:testing"
import "core:log"

@(test)
response_adapter_retains_defaults_body_policy_and_server_limit :: proc(t: ^testing.T) {
	context.logger = log.nil_logger() // Negative inputs intentionally log rejection.
	buffer: [RESPONSE_HEADER_LIMIT + 1]u8
	wire, ok := response_headers({}, buffer[:])
	testing.expect(t, ok)
	testing.expect_value(t, string(wire), "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")

	for status in ([]HTTP_Status{.No_Content, .Not_Modified, .Switching_Protocols}) {
		_, ok = response_headers({status = status, body = []u8{42}}, buffer[:])
		testing.expect(t, !ok)
	}

	_, ok = response_headers({status = cast(HTTP_Status)999}, buffer[:])
	testing.expect(t, !ok)
	large: [RESPONSE_HEADER_LIMIT]u8
	for &b in large {
		b = 'x'
	}
	_, ok = response_headers({headers = {{"X", string(large[:])}}}, buffer[:])
	testing.expect(t, !ok)
}
