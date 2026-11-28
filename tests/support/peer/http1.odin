package saba_test_peer

import "core:fmt"
import "core:strconv"
import "core:strings"

Header :: struct {
	name, value: string,
}

// A parsed HTTP/1.1 response; every string and the body are in the
// temporary allocator.
Response :: struct {
	status:         int,
	headers:        [dynamic]Header,
	body:           [dynamic]u8,
	// The Content-Length header, or -1.
	content_length: int,
	chunked:        bool,
}

// Writes a request with a Content-Length body, as a plain HTTP/1.1 client does.
request :: proc(conn: ^Conn, method, path: string, body := "", close := false) -> bool {
	text := fmt.tprintf(
		"%s %s HTTP/1.1\r\nHost: synthetic.invalid\r\nConnection: %s\r\nContent-Length: %d\r\n\r\n%s",
		method,
		path,
		"close" if close else "keep-alive",
		len(body),
		body,
	)
	return write_string(conn, text)
}

header :: proc(response: Response, name: string) -> (string, bool) {
	for field in response.headers {
		if strings.equal_fold(field.name, name) {
			return field.value, true
		}
	}
	return "", false
}

// Reads the status line and the header fields only.
read_head :: proc(conn: ^Conn) -> (response: Response, status: Status) {
	response.headers.allocator = context.temp_allocator
	response.body.allocator = context.temp_allocator
	response.content_length = -1
	line := read_line(conn) or_return
	if !strings.has_prefix(line, "HTTP/1.1 ") || len(line) < 12 {
		return response, .Error
	}
	code, valid := strconv.parse_int(line[9:12])
	if !valid {
		return response, .Error
	}
	response.status = code
	for {
		field := read_line(conn) or_return
		if field == "" {
			break
		}
		colon := strings.index_byte(field, ':')
		if colon <= 0 {
			return response, .Error
		}
		name := field[:colon]
		value := strings.trim_space(field[colon + 1:])
		append(&response.headers, Header{name, value})
		if strings.equal_fold(name, "content-length") {
			length, ok := strconv.parse_int(value)
			if !ok {
				return response, .Error
			}
			response.content_length = length
		}
		if strings.equal_fold(name, "transfer-encoding") && strings.contains(strings.to_lower(value, context.temp_allocator), "chunked") {
			response.chunked = true
		}
	}
	return response, .Ok
}

// Reads one response to a request with method. A response without a length
// reads until the connection closes; limit bounds the body.
read_response :: proc(conn: ^Conn, method := "GET", limit := 16 * 1024 * 1024) -> (response: Response, status: Status) {
	response = read_head(conn) or_return
	if method == "HEAD" || response.status < 200 || response.status == 204 || response.status == 304 {
		return response, .Ok
	}
	if response.chunked {
		for {
			size_line := read_line(conn) or_return
			if semicolon := strings.index_byte(size_line, ';'); semicolon >= 0 {
				size_line = size_line[:semicolon]
			}
			size, ok := strconv.parse_int(strings.trim_space(size_line), 16)
			if !ok || len(response.body) + size > limit {
				return response, .Error
			}
			if size == 0 {
				// Trailer fields, then the empty line.
				for {
					trailer := read_line(conn) or_return
					if trailer == "" {
						return response, .Ok
					}
				}
			}
			data := read_exact(conn, size) or_return
			append(&response.body, ..data)
			crlf := read_exact(conn, 2) or_return
			if string(crlf) != "\r\n" {
				return response, .Error
			}
		}
	}
	if response.content_length >= 0 {
		if response.content_length > limit {
			return response, .Error
		}
		data := read_exact(conn, response.content_length) or_return
		append(&response.body, ..data)
		return response, .Ok
	}
	for len(response.body) <= limit {
		buffer: [DEFAULT_CHUNK]u8
		n, ended := read(conn, buffer[:])
		if ended == .Closed {
			return response, .Ok
		}
		if ended != .Ok {
			return response, ended
		}
		append(&response.body, ..buffer[:n])
	}
	return response, .Error
}
