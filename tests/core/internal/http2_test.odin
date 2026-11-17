package saba_core

import "core:testing"
import h2 "shared:http/v2"

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
h2_concurrency_policy_is_explicit_and_resource_bounded :: proc(t:^testing.T) {
 testing.expect(t,http2_config_valid({}) && http2_config_valid({256}))
 testing.expect(t,!http2_config_valid({-1}) && !http2_config_valid({257}))
 fixture:Resource_Test
 resource_test_init(&fixture)
 defer resource_test_finish(&fixture)
 testing.expect_value(t,h2_stream_allowance(&fixture.task),32)
 fixture.runtime.config.http2.max_concurrent_streams=12
 testing.expect_value(t,h2_stream_allowance(&fixture.task),12)
 fixture.runtime.config.http2.max_concurrent_streams=256
 testing.expect_value(t,h2_stream_allowance(&fixture.task),64)
}

@(test)
h2_zero_stream_budget_advertises_zero_without_fallback :: proc(t:^testing.T) {
 limits:=DEFAULT_CONNECTION_RESOURCES;limits.streams=0
 fixture:Resource_Test
 resource_test_init(&fixture,{connection_limits=limits})
 defer resource_test_finish(&fixture)
 testing.expect_value(t,h2_stream_allowance(&fixture.task),0)
 assert(h2_begin(&fixture.task))
 defer h2_destroy(&fixture.task)
 controls,valid:=h2.connection_control_stats(&fixture.task.http2.engine)
 grant,present:=controls.advertised.max_concurrent_streams.?
 testing.expect(t,valid && present && grant==0)
 testing.expect(t,len(fixture.task.http2.requests)==0 && len(fixture.task.http2.upgrades)==0)
}
