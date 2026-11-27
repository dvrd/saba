package saba_websocket

import core "../core"
import "core:testing"

@(test)
extended_connect_uses_protocol_and_version_without_http1_key :: proc(t: ^testing.T) {
	headers := []core.Header {
		{"host", "example.test"},
		{"sec-websocket-version", "13"},
		{"sec-websocket-protocol", "chat"},
	}

	request := core.Request {
		method   = "CONNECT",
		version  = "HTTP/2",
		protocol = "websocket",
		path     = "/chat",
		headers  = headers,
	}

	fields, error := request_fields(&request)
	testing.expect_value(t, error.kind, .None)
	testing.expect_value(t, fields.version, "13")
	testing.expect_value(t, fields.key, "")
	testing.expect_value(t, fields.offered_count, 1)

	for extra in ([]core.Header {
			{"sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ=="},
			{"upgrade", "websocket"},
			{"connection", "upgrade"},
			{"sec-websocket-version", "13"},
		}) {
		combined: [4]core.Header
		copy(combined[:], headers)
		combined[3] = extra
		request.headers = combined[:]
		_, rejected := request_fields(&request)
		testing.expect_value(t, rejected.kind, .Invalid_Request)
	}

	request.headers = headers
	request.protocol = "other"
	_, wrong_protocol := request_fields(&request)
	testing.expect_value(t, wrong_protocol.kind, .Invalid_Request)
	request.protocol = "websocket"
	request.method = "GET"
	_, wrong_method := request_fields(&request)
	testing.expect_value(t, wrong_method.kind, .Invalid_Request)
}

@(test)
extended_connect_preserves_origin_policy_before_owner_transfer :: proc(t: ^testing.T) {
	headers := []core.Header {
		{"host", "example.test"},
		{"sec-websocket-version", "13"},
		{"origin", "https://example.test"},
	}

	request := core.Request {
		method   = "CONNECT",
		version  = "HTTP/2",
		protocol = "websocket",
		path     = "/chat",
		headers  = headers,
	}

	probe := WS79_Policy_Probe {
		reject_origin = true,
	}

	owner: WS79_Application_Probe
	response, error := upgrade(
		&request,
		{check_origin = ws79_origin_policy, policy_data = &probe},
		ws79_application(&owner),
	)
	testing.expect_value(t, error.kind, .Origin_Rejected)
	testing.expect_value(t, probe.origins, 1)
	testing.expect_value(t, owner.drops, 0)
	testing.expect(t, response.upgrade.data == nil)
	core.discard_response(&response)
}

@(test)
http3_extended_connect_uses_shared_websocket_validation :: proc(t: ^testing.T) {
	headers := [2]core.Header{{"host", "localhost"}, {"sec-websocket-version", "13"}}
	request := core.Request {
		method   = "CONNECT",
		version  = "HTTP/3",
		protocol = "websocket",
		headers  = headers[:],
	}

	_, error := request_fields(&request)
	testing.expect_value(t, error.kind, .None)
	request.protocol = "unknown"
	_, error = request_fields(&request)
	testing.expect_value(t, error.kind, .Invalid_Request)
}

// Extended CONNECT has no key, so the version field is the one RFC 8441 check
// left: a missing or other version is refused like an HTTP/1.1 upgrade's.
@(test)
extended_connect_requires_websocket_version_13 :: proc(t: ^testing.T) {
	for version in ([]string{"", "12", "8"}) {
		headers := [2]core.Header{{"host", "example.test"}, {"sec-websocket-version", version}}
		count := 2 if version != "" else 1
		request := core.Request {
			method   = "CONNECT",
			version  = "HTTP/2",
			protocol = "websocket",
			headers  = headers[:count],
		}
		_, error := request_fields(&request)
		testing.expectf(t, error.kind == .Invalid_Request, "version %q: %v", version, error.kind)
		testing.expect_value(t, error.status, core.HTTP_Status.Bad_Request)
	}
}
