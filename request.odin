package server

import "core:log"
import "core:strings"
import "core:time"

REQUEST_HEADER_LIMIT :: 8192
REQUEST_HEADER_COUNT_LIMIT :: 128
REQUEST_BODY_LIMIT :: 4096
REQUEST_BODY_TIMEOUT :: 5 * time.Second

http_token :: proc(value: string) -> bool {
	if value == "" do return false

	for character in value {
		if character >= 'a' && character <= 'z' do continue
		if character >= 'A' && character <= 'Z' do continue
		if character >= '0' && character <= '9' do continue
		if strings.contains_rune("!#$%&'*+-.^_`|~", character) do continue

		return false
	}

	return true
}

// Parses headers only; handle_connection reads the body before calling the router.
// The caller owns both raw and header_storage for the lifetime of the request.
parse_request :: proc(
	raw: string,
	header_storage: []Header,
) -> (
	request: Request,
	status: HTTP_Status,
) {
	status = .Bad_Request
	header_end := strings.index(raw, HTTP_HEADERS_END)
	if header_end < 0 do return

	line_end := strings.index(raw, CRLF)
	line := raw[:line_end]
	first_space := strings.index(line, " ")
	last_space := strings.last_index(line, " ")

	if first_space <= 0 || last_space <= first_space + 1 do return
	if !http_token(line[:first_space]) do return
	if line[last_space + 1:] != HTTP_VERSION do return

	target := line[first_space + 1:last_space]
	if !strings.has_prefix(target, "/") do return

	for character in target {
		if character <= ' ' || character == 127 || character == '#' do return
	}

	request.method = line[:first_space]
	request.path = target
	request.version = line[last_space + 1:]

	if separator := strings.index(target, "?"); separator >= 0 {
		request.path = target[:separator]
		request.query = target[separator + 1:]
	}

	has_transfer_encoding := false
	has_expect := false
	remaining := raw[line_end + len(CRLF):header_end + len(CRLF)]
	count := 0

	for line in strings.split_iterator(&remaining, CRLF) {
		if line == "" do break

		colon := strings.index(line, ":")
		if colon <= 0 || !http_token(line[:colon]) do return

		name := line[:colon]
		value := strings.trim(line[colon + 1:], " \t")

		for character in value {
			if (character < ' ' && character != '\t') || character == 127 do return
		}

		if count == len(header_storage) {
			status = .Request_Header_Fields_Too_Large

			return
		}

		header_storage[count] = {name, value}
		count += 1

		if strings.equal_fold(name, "Content-Length") {
			if request.has_content_length || value == "" do return

			length := 0

			for character in value {
				if character < '0' || character > '9' do return

				digit := int(character - '0')
				if length > (max(int) - digit) / 10 do return

				length = length * 10 + digit
			}

			request.content_length = length
			request.has_content_length = true
		}

		if strings.equal_fold(name, "Transfer-Encoding") {
			has_transfer_encoding = true
		}

		if strings.equal_fold(name, "Expect") && value != "" {
			has_expect = true
		}
	}

	if has_transfer_encoding {
		if !request.has_content_length do status = .Not_Implemented

		return
	}

	if has_expect {
		status = .Expectation_Failed

		return
	}

	request.headers = header_storage[:count]
	status = .None

	return
}

// A read failure may have no HTTP status when the connection itself failed.
read_request_body :: proc(
	conn: ^Connection,
	request: ^Request,
	buffer: []u8,
) -> (
	HTTP_Status,
	bool,
) {
	if request.content_length > len(buffer) {
		return .Content_Too_Large, false
	}

	request.body = buffer[:request.content_length]
	previous_deadline := conn.read_deadline
	conn.read_deadline = time.tick_add(time.tick_now(), REQUEST_BODY_TIMEOUT)
	if request.content_length > REQUEST_BODY_LIMIT do conn.read_deadline = time.tick_add(time.tick_now(), 30 * time.Second)
	defer conn.read_deadline = previous_deadline
	used := 0

	for used < len(request.body) {
		n, err := read_connection(conn, request.body[used:])

		if err == .Timeout {
			log.error("Request body timed out | socket:", conn.socket)
			return .Request_Timeout, false
		}

		if err != nil {
			log.error("Could not read request body:", err, "| socket:", conn.socket)

			return .None, false
		}

		if n == 0 {
			return .Bad_Request, false
		}

		used += n
	}

	if deadline_expired(conn.read_deadline) {
		return .Request_Timeout, false
	}

	return .None, true
}
