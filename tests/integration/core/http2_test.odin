package saba_core

import "core:testing"
import hpack "shared:async/http/hpack"
import h2 "shared:async/http/v2"

@(test)
h2_limits_match_exchange_budgets :: proc(t: ^testing.T) {
	one := h2_make_limits(1)
	testing.expect_value(t, one.streams, 1)
	testing.expect_value(t, one.reserved_streams, 0)
	testing.expect_value(t, one.frame_payload_bytes, H2_FRAME_BYTES)
	testing.expect_value(t, one.header_block_bytes, REQUEST_HEADER_LIMIT)
	testing.expect_value(t, one.header_list_bytes, REQUEST_HEADER_LIMIT)
	testing.expect_value(t, one.header_fields, REQUEST_HEADER_COUNT_LIMIT)
	testing.expect_value(t, one.hpack_table_bytes, 4096)
	testing.expect_value(t, one.retained_body_bytes, H2_BODY_BUFFER)
	testing.expect_value(t, one.body_chunks, H2_BODY_CHUNKS)
	testing.expect(t, h2.limits_validate(one).kind == .None)
	zero := h2_make_limits(0)
	testing.expect_value(t, zero.streams, 0)
	testing.expect(t, h2.limits_validate(zero).kind == .None)
}

@(test)
h2_concurrency_policy_is_explicit_and_resource_bounded :: proc(t: ^testing.T) {
	testing.expect(t, http2_config_valid({}) && http2_config_valid({256}))
	testing.expect(t, !http2_config_valid({-1}) && !http2_config_valid({257}))
	fixture: Resource_Test
	resource_test_init(&fixture)
	defer resource_test_finish(&fixture)
	testing.expect_value(t, h2_stream_allowance(&fixture.task), 32)
	fixture.runtime.config.http2.max_concurrent_streams = 12
	testing.expect_value(t, h2_stream_allowance(&fixture.task), 12)
	fixture.runtime.config.http2.max_concurrent_streams = 256
	testing.expect_value(t, h2_stream_allowance(&fixture.task), 64)
}

@(test)
h2_zero_stream_budget_advertises_zero_without_fallback :: proc(t: ^testing.T) {
	limits := DEFAULT_CONNECTION_RESOURCES
	limits.streams = 0
	fixture: Resource_Test
	resource_test_init(&fixture, {connection_limits = limits})
	defer resource_test_finish(&fixture)
	testing.expect_value(t, h2_stream_allowance(&fixture.task), 0)
	assert(h2_begin(&fixture.task))
	defer h2_destroy(&fixture.task)
	controls, valid := h2.connection_control_stats(&fixture.task.http2.engine)
	grant, present := controls.advertised.max_concurrent_streams.?
	testing.expect(t, valid && present && grant == 0)
	testing.expect(t, len(fixture.task.http2.requests) == 0 && len(fixture.task.http2.upgrades) == 0)
}

// The engine refuses a body that is not the declared length, and a field
// section over the limit Saba gives it, before Saba sees either. Saba checks
// both again where it hands the request to the handler. No peer can reach
// those checks through the engine, so these call them directly.
@(test)
h2_body_shorter_than_declared_never_reaches_the_handler :: proc(t: ^testing.T) {
	fixture: Resource_Test
	resource_test_init(&fixture)
	defer resource_test_finish(&fixture)
	called := false
	fixture.runtime.config.handler = proc(data: rawptr, _: ^Connection, _: ^Request) -> Response {
		(cast(^bool)data)^ = true
		return {}
	}
	fixture.runtime.config.handler_data = &called

	request := new(H2_Request)
	defer free(request)
	request.request_open, request.have_length = true, true
	request.expected, request.body_len = 10, 5
	fixture.task.http2_request = request
	h2_request_complete(&fixture.task)
	testing.expect(t, request.failed, "a body shorter than its content-length was accepted")
	testing.expect(t, !called, "the handler saw a body shorter than its content-length")
}

@(test)
h2_request_over_the_field_limit_is_refused_before_the_handler :: proc(t: ^testing.T) {
	fixture: Resource_Test
	resource_test_init(&fixture)
	defer resource_test_finish(&fixture)
	request := new(H2_Request)
	defer free(request)
	fixture.task.http2_request = request

	// With the Host field Saba adds from :authority, one field over the limit.
	fields := make([]hpack.Field, REQUEST_HEADER_COUNT_LIMIT)
	defer delete(fields)
	for &field in fields {
		field = {
			name  = "x-filler",
			value = "v",
		}
	}
	summary := h2.Header_Summary {
		fields            = fields,
		method            = "GET",
		scheme            = "https",
		authority         = "localhost",
		path              = "/",
		authority_present = true,
	}
	testing.expect(t, !h2_request_decode(&fixture.task, summary, false), "a request over the field limit was decoded")
	testing.expect(t, !request.failed, "an oversized field section is the peer's error, not a failure of the stream's storage")

	// At the limit the request is decoded. Its body is still open, so nothing
	// is dispatched; the fixture's own request is put back for its cleanup.
	saved := fixture.task.request
	summary.fields = fields[:REQUEST_HEADER_COUNT_LIMIT - 1]
	if testing.expect(t, h2_request_decode(&fixture.task, summary, false), "a request at the field limit was refused") {
		testing.expect_value(t, len(fixture.task.request.headers), REQUEST_HEADER_COUNT_LIMIT)
	}
	fixture.task.request = saved
}
