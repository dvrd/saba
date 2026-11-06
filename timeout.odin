package server

import "core:time"

// All budgets are total phase deadlines; progress never extends them. Zero
// selects existing defaults. Idle is first-byte wait only: HTTP/1 currently
// closes after each response and has no keep-alive idle phase.
Timeout_Config :: struct {
	header, body, response, idle: time.Duration,
}

MAX_SERVER_TIMEOUT :: 24 * time.Hour
REQUEST_HEADER_TIMEOUT :: 5 * time.Second
REQUEST_BODY_TIMEOUT :: 5 * time.Second
RESPONSE_SEND_TIMEOUT :: 5 * time.Second

@(private)
Resolved_Timeouts :: struct {
	header, body, large_body, response, idle: time.Duration,
}

// Public validation is side-effect free and safe before creating a listener.
timeouts_valid :: proc(config: Timeout_Config) -> bool {
	for value in ([4]time.Duration{config.header, config.body, config.response, config.idle}) {
		if value < 0 || value > MAX_SERVER_TIMEOUT do return false
	}
	return true
}

@(private)
resolve_timeouts :: proc(config: Timeout_Config) -> Resolved_Timeouts {
	result := Resolved_Timeouts{
		header = REQUEST_HEADER_TIMEOUT,
		body = REQUEST_BODY_TIMEOUT,
		large_body = 30 * time.Second,
		response = RESPONSE_SEND_TIMEOUT,
	}
	if config.header > 0 do result.header = config.header
	if config.body > 0 do result.body, result.large_body = config.body, config.body
	if config.response > 0 do result.response = config.response
	result.idle = result.header
	if config.idle > 0 do result.idle = min(result.header, config.idle)
	return result
}

@(private)
body_timeout :: proc(timeouts: Resolved_Timeouts, size: int) -> time.Duration {
	if size > REQUEST_BODY_LIMIT do return timeouts.large_body
	return timeouts.body
}
