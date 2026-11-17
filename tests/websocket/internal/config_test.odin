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
