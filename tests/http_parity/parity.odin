package http_parity_tests

import server "../.."
import http "../../../http"
import http1 "../../../http/v1"
import corpus "../../../http/testsupport"
import "core:testing"
import "core:log"

@(test)
request_corpus_matches_shared_parser :: proc(t: ^testing.T) {
	for item in corpus.REQUESTS {
		headers: [128]server.Header
		protocol_headers: [128]http.Header
		actual, status := server.parse_request(item.wire, headers[:])
		expected, shared_status := http1.request_head_decode_framed(item.wire, protocol_headers[:])
		expected_status := item.status
        if item.name == "chunked unsupported" do expected_status = 0 // Explicit Saba/framed-parser opt-in.
		testing.expectf(t, int(status) == expected_status, "%s: server status %v, want %v", item.name, status, expected_status)
		testing.expectf(t, int(shared_status) == expected_status, "%s: shared status %v, want %v", item.name, shared_status, expected_status)
		if status == .None && shared_status == .None {
			testing.expect_value(t, actual.method, expected.method)
			testing.expect_value(t, actual.path, expected.path)
			testing.expect_value(t, actual.query, expected.query)
			testing.expect_value(t, actual.content_length, expected.content_length)
		}
	}
}

@(test)
local_header_limits_and_response_rules_are_preserved :: proc(t: ^testing.T) {
	header_storage: [128]server.Header
	large := make([]u8, 9000)
	defer delete(large)
	for &c in large do c = 'x'
	copy(large, "GET / HTTP/1.1\r\nHost: example.com\r\nX: ")
	copy(large[len(large)-4:], "\r\n\r\n")
	_, status := server.parse_request(string(large), header_storage[:])
	testing.expect_value(t,status,.Request_Header_Fields_Too_Large)
	_, status = server.parse_request("GET / HTTP/1.1\r\nHost: example.com\r\nX: value\r\n\r\n",header_storage[:1])
	testing.expect_value(t,status,.Request_Header_Fields_Too_Large)
	buffer: [8192]u8
	body := []u8{'a','b','c'}
	head, ok := server.response_headers(server.Response{status=.OK,body=body},buffer[:])
	testing.expect(t,ok)
	parsed, _, error := http1.response_header_decode(head)
	testing.expect_value(t,error.kind,.None)
	testing.expect_value(t,parsed.content_length,u64(3))
	previous_logger := context.logger
	context.logger = log.nil_logger()
	_, ok = server.response_headers(server.Response{status=.No_Content,body=body},buffer[:])
	context.logger = previous_logger
	testing.expect(t,!ok)
	context.logger = log.nil_logger()
	_, ok = server.response_headers(server.Response{status=.Not_Modified,body=body},buffer[:])
	context.logger = previous_logger
	testing.expect(t,!ok)
	for code in ([]server.HTTP_Status{.No_Content,.Not_Modified}) {
		encoded, valid := server.response_headers(server.Response{status=code},buffer[:])
		testing.expect(t,valid)
		decoded, _, e := http1.response_header_decode(encoded)
		testing.expect_value(t,e.kind,.None)
		testing.expect_value(t,decoded.framing,.None)
	}
	testing.expect_value(t,server.status_text(.Method_Not_Allowed),"405 Method Not Allowed")
}
