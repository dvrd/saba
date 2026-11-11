package saba_core

import "core:testing"
import h2 "shared:http/v2"

@(test)
h2_protocol_token_is_exact :: proc(t: ^testing.T) {
	testing.expect(t, h2_selected_protocol("h2"))
	testing.expect(t, !h2_selected_protocol(""))
	testing.expect(t, !h2_selected_protocol("http/1.1"))
	testing.expect(t, !h2_selected_protocol("h2c"))
	testing.expect(t, !h2_selected_protocol("h3"))
}

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
