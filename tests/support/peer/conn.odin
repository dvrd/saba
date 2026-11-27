// The client side of the interop suites when the test writes the bytes itself:
// a loopback TCP connection, optionally under an OpenSSL TLS client. OpenSSL
// reads and writes memory BIOs and this package moves their bytes to the
// socket, so a test decides how the wire is cut: short writes, short reads, or
// a handshake left half sent.
package saba_test_peer

import "core:c"
import "core:c/libc"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:time"
import openssl "../c/openssl"
import harness "../harness"

DEFAULT_TIMEOUT :: 10 * time.Second
DEFAULT_CHUNK :: 16384

Dial :: struct {
	// Wrap the connection in TLS 1.3.
	tls:          bool,
	// SNI, and the name the certificate is verified against unless
	// verify_name is set.
	server_name:  string,
	verify_name:  string,
	// The PEM file of trusted anchors. Empty: the certificate is not verified.
	ca_file:      string,
	// The verification time in Unix seconds; 0 is now.
	verify_time:  i64,
	alpn:         []string,
	// TLS 1.3 cipher suites (OpenSSL syntax); empty keeps the defaults.
	ciphersuites: string,
	// When positive, the most bytes one socket write or read moves.
	fragment:     int,
	// The receive and send timeout of the socket.
	timeout:      time.Duration,
}

Status :: enum {
	Ok,
	// The peer closed in order: a TCP FIN, or a TLS close_notify.
	Closed,
	// The TCP connection ended without a close_notify.
	Truncated,
	Timeout,
	Error,
}

Conn :: struct {
	socket:   net.TCP_Socket,
	ctx:      ^openssl.SSL_CTX,
	ssl:      ^openssl.SSL,
	rbio:     ^openssl.BIO,
	wbio:     ^openssl.BIO,
	fragment: int,
	// The most bytes one read from the socket takes.
	chunk:    int,
	// Bytes read from the connection that a caller has not taken yet.
	pending:  [dynamic]u8,
}

Dial_Result :: struct {
	ok:            bool,
	// SSL_get_verify_result after a TLS handshake.
	verify_result: c.long,
	message:       string,
}

dial :: proc(port: int, options: Dial) -> (^Conn, Dial_Result) {
	// Close-on-exec, made under the harness's descriptor lock: no program a
	// suite starts holds the connection open after the peer closes it.
	timeout := options.timeout if options.timeout > 0 else DEFAULT_TIMEOUT
	socket, error := harness.dial_loopback(port, timeout)
	if error != nil {
		return nil, {message = fmt.tprintf("dial: %v", error)}
	}
	conn := new(Conn)
	conn.socket = socket
	conn.fragment = options.fragment
	conn.chunk = options.fragment if options.fragment > 0 else DEFAULT_CHUNK
	if !options.tls {
		return conn, {ok = true}
	}
	result := handshake(conn, options)
	if !result.ok {
		close(conn)
		return nil, result
	}
	return conn, result
}

@(private)
handshake :: proc(conn: ^Conn, options: Dial) -> Dial_Result {
	conn.ctx = openssl.SSL_CTX_new(openssl.TLS_client_method())
	if conn.ctx == nil {
		return {message = errors("SSL_CTX_new")}
	}
	_ = openssl.SSL_CTX_set_min_proto_version(conn.ctx, openssl.TLS1_3_VERSION)
	_ = openssl.SSL_CTX_set_max_proto_version(conn.ctx, openssl.TLS1_3_VERSION)
	if options.ciphersuites != "" {
		if openssl.SSL_CTX_set_ciphersuites(conn.ctx, strings.clone_to_cstring(options.ciphersuites, context.temp_allocator)) != 1 {
			return {message = errors("cipher suites")}
		}
	}
	if options.ca_file != "" {
		openssl.SSL_CTX_set_verify(conn.ctx, openssl.SSL_VERIFY_PEER, nil)
		if openssl.SSL_CTX_load_verify_locations(conn.ctx, strings.clone_to_cstring(options.ca_file, context.temp_allocator), nil) != 1 {
			return {message = errors("trust anchors")}
		}
		if options.verify_time != 0 {
			openssl.X509_VERIFY_PARAM_set_time(openssl.SSL_CTX_get0_param(conn.ctx), libc.time_t(options.verify_time))
		}
	} else {
		openssl.SSL_CTX_set_verify(conn.ctx, openssl.SSL_VERIFY_NONE, nil)
	}
	if len(options.alpn) > 0 {
		wire := make([dynamic]u8, context.temp_allocator)
		for protocol in options.alpn {
			append(&wire, u8(len(protocol)))
			append(&wire, ..transmute([]u8)protocol)
		}
		if openssl.SSL_CTX_set_alpn_protos(conn.ctx, raw_data(wire), c.uint(len(wire))) != 0 {
			return {message = errors("ALPN offer")}
		}
	}
	conn.ssl = openssl.SSL_new(conn.ctx)
	conn.rbio = openssl.BIO_new(openssl.BIO_s_mem())
	conn.wbio = openssl.BIO_new(openssl.BIO_s_mem())
	openssl.SSL_set_bio(conn.ssl, conn.rbio, conn.wbio)
	if options.server_name != "" {
		name := strings.clone_to_cstring(options.server_name, context.temp_allocator)
		_ = openssl.SSL_set_tlsext_host_name(conn.ssl, name)
		if options.ca_file != "" {
			verify := options.verify_name if options.verify_name != "" else options.server_name
			_ = openssl.X509_VERIFY_PARAM_set1_host(
				openssl.SSL_get0_param(conn.ssl),
				strings.clone_to_cstring(verify, context.temp_allocator),
				0,
			)
		}
	}
	openssl.SSL_set_connect_state(conn.ssl)
	for {
		done := openssl.SSL_do_handshake(conn.ssl)
		if !flush(conn) {
			return {verify_result = openssl.SSL_get_verify_result(conn.ssl), message = "handshake write failed"}
		}
		if done == 1 {
			return {ok = true, verify_result = openssl.SSL_get_verify_result(conn.ssl)}
		}
		if openssl.SSL_get_error(conn.ssl, done) != openssl.SSL_ERROR_WANT_READ {
			return {verify_result = openssl.SSL_get_verify_result(conn.ssl), message = errors("handshake")}
		}
		if status := receive(conn); status != .Ok {
			return {verify_result = openssl.SSL_get_verify_result(conn.ssl), message = fmt.tprintf("handshake read: %v", status)}
		}
	}
}

// The protocol ALPN selected, or "".
alpn :: proc(conn: ^Conn) -> string {
	if conn.ssl == nil {
		return ""
	}
	data: [^]u8
	size: c.uint
	openssl.SSL_get0_alpn_selected(conn.ssl, &data, &size)
	return strings.clone(string(data[:size]), context.temp_allocator) if size > 0 else ""
}

// Writes every byte of data, in fragment-sized socket writes when set.
write :: proc(conn: ^Conn, data: []u8) -> bool {
	if conn.ssl == nil {
		return send(conn, data)
	}
	if len(data) == 0 {
		return true
	}
	written: c.size_t
	if openssl.SSL_write_ex(conn.ssl, raw_data(data), c.size_t(len(data)), &written) != 1 || int(written) != len(data) {
		return false
	}
	return flush(conn)
}

write_string :: proc(conn: ^Conn, text: string) -> bool {
	return write(conn, transmute([]u8)text)
}

// Writes data to the socket as it is, under any TLS layer.
write_raw :: proc(conn: ^Conn, data: []u8) -> bool {
	return send(conn, data)
}

// Reads what is there, at most len(buffer) bytes.
read :: proc(conn: ^Conn, buffer: []u8) -> (int, Status) {
	if len(conn.pending) == 0 {
		if status := fill(conn); status != .Ok {
			return 0, status
		}
	}
	n := copy(buffer, conn.pending[:])
	remove_range(&conn.pending, 0, n)
	return n, .Ok
}

// Waits until at least one byte can be read, without taking it.
peek :: proc(conn: ^Conn) -> Status {
	if len(conn.pending) > 0 {
		return .Ok
	}
	return fill(conn)
}

// Reads exactly n bytes; the slice is in the temporary allocator.
read_exact :: proc(conn: ^Conn, n: int) -> ([]u8, Status) {
	for len(conn.pending) < n {
		if status := fill(conn); status != .Ok {
			return nil, status
		}
	}
	result := make([]u8, n, context.temp_allocator)
	copy(result, conn.pending[:n])
	remove_range(&conn.pending, 0, n)
	return result, .Ok
}

// Reads one line ending in CRLF and returns it without the CRLF.
read_line :: proc(conn: ^Conn, limit := 16384) -> (string, Status) {
	searched := 0
	for {
		for i in max(searched, 1) ..< len(conn.pending) {
			if conn.pending[i - 1] == '\r' && conn.pending[i] == '\n' {
				line := strings.clone(string(conn.pending[:i - 1]), context.temp_allocator)
				remove_range(&conn.pending, 0, i + 1)
				return line, .Ok
			}
		}
		searched = len(conn.pending)
		if searched > limit {
			return "", .Error
		}
		if status := fill(conn); status != .Ok {
			return "", status
		}
	}
}

// Reads until the peer closes and returns how the connection ended and how
// many bytes came first (at most limit are kept in pending).
read_to_end :: proc(conn: ^Conn, limit := 1 << 30) -> (int, Status) {
	total := len(conn.pending)
	clear(&conn.pending)
	for total <= limit {
		status := fill(conn)
		if status != .Ok {
			return total, status
		}
		total += len(conn.pending)
		clear(&conn.pending)
	}
	return total, .Ok
}

// Sends close_notify when TLS is up, then closes the socket and frees conn.
close :: proc(conn: ^Conn) {
	if conn == nil {
		return
	}
	if conn.ssl != nil {
		_ = openssl.SSL_shutdown(conn.ssl)
		_ = flush(conn)
		// The SSL owns both BIOs.
		openssl.SSL_free(conn.ssl)
	}
	if conn.ctx != nil {
		openssl.SSL_CTX_free(conn.ctx)
	}
	net.close(conn.socket)
	delete(conn.pending)
	free(conn)
}

// Closes the socket without a close_notify.
abort :: proc(conn: ^Conn) {
	if conn == nil {
		return
	}
	if conn.ssl != nil {
		openssl.SSL_free(conn.ssl)
	}
	if conn.ctx != nil {
		openssl.SSL_CTX_free(conn.ctx)
	}
	net.close(conn.socket)
	delete(conn.pending)
	free(conn)
}

// Appends what the connection has next to pending.
@(private)
fill :: proc(conn: ^Conn) -> Status {
	if conn.ssl == nil {
		buffer: [DEFAULT_CHUNK]u8
		n, status := recv(conn, buffer[:min(conn.chunk, len(buffer))])
		if status == .Ok {
			append(&conn.pending, ..buffer[:n])
		}
		return status
	}
	buffer: [DEFAULT_CHUNK]u8
	for {
		count: c.size_t
		result := openssl.SSL_read_ex(conn.ssl, &buffer, len(buffer), &count)
		_ = flush(conn)
		if result == 1 {
			append(&conn.pending, ..buffer[:count])
			return .Ok
		}
		switch openssl.SSL_get_error(conn.ssl, result) {
		case openssl.SSL_ERROR_WANT_READ:
			if status := receive(conn); status != .Ok {
				return .Truncated if status == .Closed else status
			}
		case openssl.SSL_ERROR_ZERO_RETURN:
			return .Closed
		case:
			return .Error
		}
	}
}

// Moves one socket read into the read BIO.
@(private)
receive :: proc(conn: ^Conn) -> Status {
	buffer: [DEFAULT_CHUNK]u8
	n, status := recv(conn, buffer[:min(conn.chunk, len(buffer))])
	if status != .Ok {
		return status
	}
	if openssl.BIO_write(conn.rbio, &buffer, c.int(n)) != c.int(n) {
		return .Error
	}
	return .Ok
}

// Sends what OpenSSL wrote to the write BIO.
@(private)
flush :: proc(conn: ^Conn) -> bool {
	buffer: [DEFAULT_CHUNK]u8
	for openssl.BIO_pending(conn.wbio) > 0 {
		n := openssl.BIO_read(conn.wbio, &buffer, len(buffer))
		if n <= 0 {
			return false
		}
		if !send(conn, buffer[:n]) {
			return false
		}
	}
	return true
}

@(private)
send :: proc(conn: ^Conn, data: []u8) -> bool {
	rest := data
	for len(rest) > 0 {
		n := len(rest) if conn.fragment <= 0 else min(conn.fragment, len(rest))
		written, error := net.send_tcp(conn.socket, rest[:n])
		if error != nil || written != n {
			return false
		}
		rest = rest[n:]
	}
	return true
}

@(private)
recv :: proc(conn: ^Conn, buffer: []u8) -> (int, Status) {
	n, error := net.recv_tcp(conn.socket, buffer)
	if error == .Timeout || error == .Would_Block {
		return 0, .Timeout
	}
	if error != nil {
		return 0, .Error
	}
	if n == 0 {
		return 0, .Closed
	}
	return n, .Ok
}

// The OpenSSL error queue as text, emptied.
@(private)
errors :: proc(what: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, what)
	for {
		code := openssl.ERR_get_error()
		if code == 0 {
			break
		}
		text: [256]u8
		openssl.ERR_error_string_n(code, &text[0], len(text))
		fmt.sbprintf(&b, ": %s", cstring(&text[0]))
	}
	return strings.to_string(b)
}
