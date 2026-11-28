package saba_websocket

import "core:mem"
import "core:testing"
import "core:time"

@(test)
configuration_resolves_finite_independent_bounds_without_allocation :: proc(t: ^testing.T) {
	context.allocator = mem.panic_allocator()
	context.temp_allocator = mem.panic_allocator()
	config, error := config_normalize({})
	testing.expect_value(t, error.kind, .None)
	testing.expect(t, config.max_frame_bytes > 0 && config.max_message_bytes > 0)
	testing.expect(t, config.max_output_bytes > 0 && config.output_capacity > 0)
	testing.expect(t, config.max_fragments > 0)

	for timeout in ([5]time.Duration {
			config.idle_timeout,
			config.frame_timeout,
			config.message_timeout,
			config.write_timeout,
			config.close_timeout,
		}) {
		testing.expect(t, timeout > 0 && timeout <= 24 * time.Hour)
	}
}

@(test)
configuration_rejects_negative_and_overflow_limits_before_session_allocation :: proc(t: ^testing.T) {
	cases := [14]Config {
		{max_frame_bytes = -1},
		{max_message_bytes = -1},
		{max_output_bytes = -1},
		{output_capacity = -1},
		{max_fragments = -1},
		{max_frame_bytes = MAX_MESSAGE_BYTES + 1},
		{max_message_bytes = MAX_MESSAGE_BYTES + 1},
		{max_output_bytes = MAX_MESSAGE_BYTES + 1},
		{output_capacity = MAX_OUTPUT_CAPACITY + 1},
		{max_fragments = 65537},
		{idle_timeout = -time.Nanosecond},
		{frame_timeout = -time.Nanosecond},
		{message_timeout = 24 * time.Hour + time.Nanosecond},
		{write_timeout = -time.Nanosecond},
	}

	for config in cases {
		_, error := config_normalize(config)
		testing.expect_value(t, error.kind, .Invalid_Config)
	}

	_, error := config_normalize({close_timeout = 24 * time.Hour + time.Nanosecond})
	testing.expect_value(t, error.kind, .Invalid_Config)
}

// A zero field selects the default, not the ceiling: an application that sets
// nothing must not let one peer message reserve MAX_MESSAGE_BYTES.
@(test)
zero_configuration_selects_the_defaults_not_the_ceilings :: proc(t: ^testing.T) {
	config, error := config_normalize({})
	testing.expect_value(t, error.kind, .None)
	testing.expect_value(t, config.max_frame_bytes, DEFAULT_FRAME_BYTES)
	testing.expect_value(t, config.max_message_bytes, DEFAULT_MESSAGE_BYTES)
	testing.expect_value(t, config.max_output_bytes, DEFAULT_MESSAGE_BYTES)
	testing.expect(t, DEFAULT_MESSAGE_BYTES < MAX_MESSAGE_BYTES)
	testing.expect_value(t, config.output_capacity, 4)
	testing.expect_value(t, config.max_fragments, 1024)
	testing.expect_value(t, config.idle_timeout, 60 * time.Second)
	testing.expect_value(t, config.frame_timeout, 5 * time.Second)
	testing.expect_value(t, config.message_timeout, 30 * time.Second)
	testing.expect_value(t, config.write_timeout, 5 * time.Second)
	testing.expect_value(t, config.close_timeout, time.Second)
}
