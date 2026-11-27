package saba_test_fetch

import "core:c"
import "core:time"
import curl "../c/curl"

// A WebSocket through curl: the upgrade with CURLOPT_CONNECT_ONLY, then frames
// with curl_ws_send and curl_ws_recv on the same handle. curl answers pings
// itself.

websocket_open :: proc(client: ^Client, request: Request) -> Response {
	return transfer(client, request, true)
}

// Sends one frame (flags is a curl.CURLWS_ kind).
websocket_send :: proc(client: ^Client, payload: []u8, flags: c.uint, timeout := 10 * time.Second) -> curl.CURLcode {
	deadline := time.tick_add(time.tick_now(), timeout)
	rest := payload
	for {
		sent: c.size_t
		code := curl.curl_ws_send(client.handle, raw_data(rest), len(rest), &sent, 0, flags)
		if code == curl.CURLE_AGAIN {
			if time.tick_since(deadline) >= 0 {
				return code
			}
			time.sleep(time.Millisecond)
			continue
		}
		if code != curl.CURLE_OK || int(sent) == len(rest) {
			return code
		}
		rest = rest[sent:]
	}
}

// Receives one whole frame: its curl.CURLWS_ flags and its payload, in the
// temporary allocator.
websocket_receive :: proc(client: ^Client, timeout := 10 * time.Second) -> (flags: c.int, payload: []u8, code: curl.CURLcode) {
	deadline := time.tick_add(time.tick_now(), timeout)
	data := make([dynamic]u8, context.temp_allocator)
	for {
		buffer: [4096]u8
		received: c.size_t
		meta: ^curl.curl_ws_frame
		code = curl.curl_ws_recv(client.handle, &buffer, len(buffer), &received, &meta)
		if code == curl.CURLE_AGAIN {
			if time.tick_since(deadline) >= 0 {
				return
			}
			time.sleep(time.Millisecond)
			continue
		}
		if code != curl.CURLE_OK {
			return
		}
		append(&data, ..buffer[:received])
		if meta != nil {
			flags = meta.flags
			if meta.bytesleft == 0 {
				return flags, data[:], code
			}
		}
	}
}
