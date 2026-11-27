// A raw HTTP/1 client over core:net for suites that need to control the bytes
// on the wire: what is sent, how it is split, and what comes back. It decodes
// nothing it is not asked to. Every read is bounded by the socket's timeout.
package saba_test_harness

import "core:net"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"

HEAD_LIMIT :: 8192

// A request as keep-alive tests write it: Content-Length for any body (and
// always for POST), fields appended verbatim before the blank line.
request_wire :: proc(path := "/id", method := "GET", body := "", fields := "", allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, method)
	strings.write_byte(&b, ' ')
	strings.write_string(&b, path)
	strings.write_string(&b, " HTTP/1.1\r\nHost: localhost\r\n")
	if body != "" || method == "POST" {
		strings.write_string(&b, "Content-Length: ")
		strings.write_int(&b, len(body))
		strings.write_string(&b, "\r\n")
	}
	strings.write_string(&b, fields)
	strings.write_string(&b, "\r\n")
	strings.write_string(&b, body)
	return strings.to_string(b)
}

// A blocking loopback connection whose reads and writes give up after
// timeout, for a test that expects the connection may be refused.
dial :: proc(port: int, timeout := 5 * time.Second) -> (net.TCP_Socket, net.Network_Error) {
	socket, error := net.dial_tcp(net.Endpoint{net.IP4_Loopback, port})
	if error != nil {
		return {}, error
	}
	_ = net.set_option(socket, .Receive_Timeout, timeout)
	_ = net.set_option(socket, .Send_Timeout, timeout)
	return socket, nil
}

// Like dial, failing the test when the connection is refused.
connect :: proc(t: ^testing.T, port: int, timeout := 5 * time.Second, loc := #caller_location) -> (net.TCP_Socket, bool) {
	socket, error := dial(port, timeout)
	return socket, testing.expectf(t, error == nil, "could not connect to port %d: %v", port, error, loc = loc)
}

// Sends every byte. A peer that already closed is not a failure here; the
// read that follows reports what happened.
send_text :: proc(socket: net.TCP_Socket, data: string) -> bool {
	_, error := net.send_tcp(socket, transmute([]u8)data)
	return error == nil
}

send_bytes :: proc(socket: net.TCP_Socket, data: []u8) -> bool {
	_, error := net.send_tcp(socket, data)
	return error == nil
}

// Half-closes the connection: the server reads EOF, the client still reads.
shutdown_write :: proc(socket: net.TCP_Socket) {
	_ = net.shutdown(socket, .Send)
}

// Closes with a reset instead of a FIN (SO_LINGER with a zero timeout).
reset :: proc(socket: net.TCP_Socket) {
	_ = net.set_option(socket, .Linger, time.Duration(0))
	net.close(socket)
}

Read_Result :: enum {
	Ok,
	Eof,
	Reset,
	Timeout,
	Failed,
}

// Reads exactly len(buffer) bytes.
read_exact :: proc(socket: net.TCP_Socket, buffer: []u8) -> Read_Result {
	at := 0
	for at < len(buffer) {
		n, error := net.recv_tcp(socket, buffer[at:])
		if error != nil {
			return read_failure(error)
		}
		if n == 0 {
			return .Eof
		}
		at += n
	}
	return .Ok
}

@(private)
read_failure :: proc(error: net.TCP_Recv_Error) -> Read_Result {
	#partial switch error {
	case .Connection_Closed:
		return .Reset
	case .Timeout, .Would_Block:
		return .Timeout
	}
	return .Failed
}

// n bytes, allocated with allocator.
read_n :: proc(
	t: ^testing.T,
	socket: net.TCP_Socket,
	n: int,
	allocator := context.temp_allocator,
	loc := #caller_location,
) -> ([]u8, bool) {
	buffer := make([]u8, n, allocator)
	result := read_exact(socket, buffer)
	return buffer, testing.expectf(t, result == .Ok, "reading %d bytes: %v", n, result, loc = loc)
}

// A response head up to and including its blank line, read a byte at a time so
// nothing after it is consumed.
read_head :: proc(t: ^testing.T, socket: net.TCP_Socket, loc := #caller_location) -> (string, bool) {
	b := strings.builder_make(context.temp_allocator)
	one: [1]u8
	for !strings.has_suffix(strings.to_string(b), "\r\n\r\n") {
		if result := read_exact(socket, one[:]); result != .Ok {
			return strings.to_string(b), testing.expectf(
				t,
				false,
				"reading a response head: %v after %q",
				result,
				strings.to_string(b),
				loc = loc,
			)
		}
		strings.write_byte(&b, one[0])
		if strings.builder_len(b) > HEAD_LIMIT {
			return strings.to_string(b), testing.expectf(t, false, "a response head over %d bytes", HEAD_LIMIT, loc = loc)
		}
	}
	return strings.to_string(b), true
}

// The status code of a head, or 0.
status_of :: proc(head: string) -> int {
	space := strings.index_byte(head, ' ')
	if space < 0 || len(head) < space + 4 {
		return 0
	}
	code, _ := strconv.parse_int(head[space + 1:space + 4])
	return code
}

// The value of the first field called name (any case), trimmed.
field :: proc(head: string, name: string) -> (string, bool) {
	text := head
	first := true
	for line in strings.split_lines_iterator(&text) {
		if first {
			first = false
			continue
		}
		colon := strings.index_byte(line, ':')
		if colon < 0 {
			continue
		}
		if strings.equal_fold(line[:colon], name) {
			return strings.trim_space(strings.trim_right(line[colon + 1:], "\r")), true
		}
	}
	return "", false
}

// Whether head carries the exact line "name: value".
has_field :: proc(head: string, line: string) -> bool {
	return strings.contains(head, strings.concatenate({"\r\n", line, "\r\n"}, context.temp_allocator))
}

Response :: struct {
	status: int,
	head:   string,
	body:   []u8,
}

// A head and its Content-Length body (none when head_only, as for HEAD and
// 304). Chunked bodies are read with read_chunk.
read_response :: proc(
	t: ^testing.T,
	socket: net.TCP_Socket,
	head_only := false,
	loc := #caller_location,
) -> (
	response: Response,
	ok: bool,
) {
	response.head = read_head(t, socket, loc) or_return
	response.status = status_of(response.head)
	if head_only {
		return response, true
	}
	length := 0
	if value, found := field(response.head, "Content-Length"); found {
		length, _ = strconv.parse_int(value)
	}
	response.body = read_n(t, socket, length, loc = loc) or_return
	return response, true
}

// The payload of the next chunk; done at the last chunk, whose trailer section
// must be empty.
read_chunk :: proc(t: ^testing.T, socket: net.TCP_Socket, loc := #caller_location) -> (payload: []u8, done: bool, ok: bool) {
	b := strings.builder_make(context.temp_allocator)
	one: [1]u8
	for !strings.has_suffix(strings.to_string(b), "\r\n") {
		if result := read_exact(socket, one[:]); result != .Ok {
			return nil, false, testing.expectf(t, false, "reading a chunk size: %v", result, loc = loc)
		}
		strings.write_byte(&b, one[0])
		if strings.builder_len(b) >= 32 {
			return nil, false, testing.expectf(t, false, "chunk size line too long: %q", strings.to_string(b), loc = loc)
		}
	}
	line := strings.to_string(b)
	size, parsed := strconv.parse_int(line[:len(line) - 2], 16)
	if !testing.expectf(t, parsed, "bad chunk size line %q", line, loc = loc) {
		return nil, false, false
	}
	if size > 0 {
		payload = read_n(t, socket, size, loc = loc) or_return
	}
	crlf := read_n(t, socket, 2, loc = loc) or_return
	if !testing.expectf(t, string(crlf) == "\r\n", "chunk not followed by CRLF: %q", crlf, loc = loc) {
		return nil, false, false
	}
	return payload, size == 0, true
}

// Every chunk of a chunked body, concatenated, and how many chunks carried it.
read_chunked :: proc(t: ^testing.T, socket: net.TCP_Socket, loc := #caller_location) -> (body: []u8, chunks: int, ok: bool) {
	all := make([dynamic]u8, context.temp_allocator)
	for {
		payload, done := read_chunk(t, socket, loc) or_return
		if done {
			return all[:], chunks, true
		}
		append(&all, ..payload)
		chunks += 1
	}
}

// Everything until the peer closes (a reset ends it too), at most limit bytes.
read_to_close :: proc(socket: net.TCP_Socket, limit := 1024 * 1024) -> (data: []u8, result: Read_Result) {
	all := make([dynamic]u8, context.temp_allocator)
	buffer: [65536]u8
	for len(all) <= limit {
		n, error := net.recv_tcp(socket, buffer[:])
		if error != nil {
			result = read_failure(error)
			return all[:], .Eof if result == .Reset else result
		}
		if n == 0 {
			return all[:], .Eof
		}
		append(&all, ..buffer[:n])
	}
	return all[:], .Failed
}

// Waits for the peer to close (FIN or reset), discarding what it still sends.
// false when a read waited longer than timeout.
await_close :: proc(socket: net.TCP_Socket, timeout := 4 * time.Second) -> bool {
	_ = net.set_option(socket, .Receive_Timeout, timeout)
	buffer: [65536]u8
	for {
		n, error := net.recv_tcp(socket, buffer[:])
		if error != nil {
			return read_failure(error) == .Reset
		}
		if n == 0 {
			return true
		}
	}
}

// Expects the peer to close (FIN or reset) with nothing more sent. message
// says what failed.
expect_closed :: proc(
	t: ^testing.T,
	socket: net.TCP_Socket,
	message := "expected the server to close",
	loc := #caller_location,
) -> bool {
	one: [1]u8
	n, error := net.recv_tcp(socket, one[:])
	if error != nil {
		return testing.expectf(t, error == .Connection_Closed, "%s, got %v", message, error, loc = loc)
	}
	return testing.expectf(t, n == 0, "%s, got %q", message, one[:n], loc = loc)
}

// Whether no byte arrives within wait. The receive timeout is timeout again
// afterwards.
quiet :: proc(socket: net.TCP_Socket, wait: time.Duration, timeout := 5 * time.Second) -> bool {
	_ = net.set_option(socket, .Receive_Timeout, wait)
	defer _ = net.set_option(socket, .Receive_Timeout, timeout)
	one: [1]u8
	_, error := net.recv_tcp(socket, one[:])
	return error == .Would_Block || error == .Timeout
}
