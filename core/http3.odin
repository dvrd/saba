package saba_core

import http3 "../../http/v3"

// Optional HTTP/3 listener. TCP stays on the normal Saba listener.
// QPACK and QUIC stay in shared/http/v3 and core:net/quic. 0-RTT is not enabled.
// enabled must be set. Discovery does not upgrade an HTTP/1 port.

Http3_Config :: struct {
	enabled:      bool,
	handler:      Handler,
	handler_data: rawptr,
	// Zero uses http3.REPLY_CAP. Larger values clamp to that cap.
	max_body:     int,
}

Http3 :: struct {
	live:     http3.Live,
	config:   Http3_Config,
	body:     [http3.REPLY_CAP]u8,
	body_len: int,
	calls:    int,
	rejected: bool,
}

@(private)
http3_too_big: [http3.REPLY_CAP + 1]u8

http3_listen :: proc(state: ^Http3) -> (port: int, ok: bool) {
	if state == nil || !state.config.enabled || state.config.handler == nil {
		return 0, false
	}
	limit := state.config.max_body
	if limit <= 0 || limit > http3.REPLY_CAP {
		limit = http3.REPLY_CAP
	}
	state.live.reply_cap = limit
	state.live.on_path = http3_on_path
	state.live.on_path_user = state
	return http3.live_listen(&state.live)
}

http3_step :: proc(state: ^Http3) -> bool {
	if state == nil do return false
	return http3.live_step(&state.live)
}

// Drops new datagrams until a request is already in progress.
http3_drain :: proc(state: ^Http3) {
	if state == nil do return
	state.live.draining = true
}

http3_close :: proc(state: ^Http3) {
	if state == nil do return
	http3.live_close(&state.live)
}

@(private)
http3_on_path :: proc(path: string, user: rawptr) -> string {
	state := cast(^Http3)user
	if state == nil || state.config.handler == nil {
		return string(http3_too_big[:])
	}
	state.calls += 1
	request := Request {
		method  = "GET",
		path    = path,
		version = "HTTP/3",
	}
	if state.live.method_len > 0 {
		request.method = string(state.live.method_buf[:state.live.method_len])
	}
	response := state.config.handler(state.config.handler_data, nil, &request)
	limit := state.live.reply_cap
	if limit <= 0 || limit > http3.REPLY_CAP {
		limit = http3.REPLY_CAP
	}
	if len(response.body) > limit {
		state.rejected = true
		return string(http3_too_big[:])
	}
	n := copy(state.body[:], response.body)
	state.body_len = n
	return string(state.body[:n])
}
