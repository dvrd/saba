package saba_websocket

import "core:time"

DEFAULT_FRAME_BYTES :: 64 << 10
DEFAULT_MESSAGE_BYTES :: 1 << 20
MAX_MESSAGE_BYTES :: 64 << 20
MAX_OUTPUT_CAPACITY :: 1024
MAX_SUBPROTOCOLS :: 32

@(private)
config_normalize :: proc(config: Config) -> (Config, Error) {
	result := config
	if result.max_frame_bytes == 0 do result.max_frame_bytes = DEFAULT_FRAME_BYTES
	if result.max_message_bytes == 0 do result.max_message_bytes = DEFAULT_MESSAGE_BYTES
	if result.max_output_bytes == 0 do result.max_output_bytes = DEFAULT_MESSAGE_BYTES
	if result.output_capacity == 0 do result.output_capacity = 4
	if result.max_fragments == 0 do result.max_fragments = 1024
	if result.idle_timeout == 0 do result.idle_timeout = 60 * time.Second
	if result.frame_timeout == 0 do result.frame_timeout = 5 * time.Second
	if result.message_timeout == 0 do result.message_timeout = 30 * time.Second
	if result.write_timeout == 0 do result.write_timeout = 5 * time.Second
	if result.close_timeout == 0 do result.close_timeout = time.Second
	if result.max_frame_bytes < 1 || result.max_frame_bytes > MAX_MESSAGE_BYTES ||
	   result.max_message_bytes < 1 || result.max_message_bytes > MAX_MESSAGE_BYTES ||
	   result.max_output_bytes < 1 || result.max_output_bytes > MAX_MESSAGE_BYTES ||
	   result.output_capacity < 1 || result.output_capacity > MAX_OUTPUT_CAPACITY ||
	   result.max_fragments < 1 || result.max_fragments > 65536 {return {}, {kind = .Invalid_Config}}
	for duration in ([5]time.Duration{result.idle_timeout, result.frame_timeout,
		result.message_timeout, result.write_timeout, result.close_timeout}) {
		if duration <= 0 || duration > 24 * time.Hour do return {}, {kind = .Invalid_Config}
	}
	return result, {}
}
