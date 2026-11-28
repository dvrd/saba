// HTTP requests through libcurl, the independent client of the interop suites.
// One Client is one curl easy handle: its connections are kept between
// requests, as a browser or a command-line client keeps them.
package saba_test_fetch

import "base:runtime"
import "core:c"
import "core:c/libc"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"
import curl "../c/curl"
import openssl "../c/openssl"
import harness "../harness"

Client :: struct {
	handle: ^curl.CURL,
}

Request :: struct {
	url:          string,
	// A host:port:address entry, so a name in the URL reaches loopback.
	resolve:      string,
	// GET when empty, POST when body is set.
	method:       string,
	body:         Maybe(string),
	headers:      []string,
	// One of the curl.CURL_HTTP_VERSION_ values; 0 is curl's default.
	http_version: c.long,
	// The PEM file of trusted anchors. Empty: the certificate is not verified.
	ca_file:      string,
	// A client certificate and its key.
	cert, key:    string,
	// The verification time in Unix seconds; 0 is now.
	verify_time:  i64,
	timeout:      time.Duration,
}

Response :: struct {
	code:          curl.CURLcode,
	message:       string,
	status:        int,
	// curl.CURL_HTTP_VERSION_1_1 or curl.CURL_HTTP_VERSION_2_0.
	version:       int,
	body:          []u8,
	// The header lines as received, without CRLF.
	headers:       []string,
	verify_result: int,
	// Connections the request opened: 0 when it reused one.
	connects:      int,
}

@(private)
global: sync.Once

client_make :: proc() -> Client {
	sync.once_do(&global, proc() {
		code := curl.curl_global_init(curl.CURL_GLOBAL_DEFAULT)
		assert(code == curl.CURLE_OK)
	})
	return {handle = curl.curl_easy_init()}
}

client_destroy :: proc(client: ^Client) {
	if client.handle != nil {
		curl.curl_easy_cleanup(client.handle)
		client.handle = nil
	}
}

@(private)
Sink :: struct {
	body:    [dynamic]u8,
	headers: [dynamic]string,
	line:    [dynamic]u8,
}

@(private)
write_body :: proc "c" (buffer: [^]u8, size, count: c.size_t, user: rawptr) -> c.size_t {
	context = runtime.default_context()
	sink := cast(^Sink)user
	append(&sink.body, ..buffer[:size * count])
	return size * count
}

@(private)
write_header :: proc "c" (buffer: [^]u8, size, count: c.size_t, user: rawptr) -> c.size_t {
	context = runtime.default_context()
	sink := cast(^Sink)user
	text := strings.trim_right(string(buffer[:size * count]), "\r\n")
	append(&sink.headers, strings.clone(text, sink.headers.allocator))
	return size * count
}

// curl's sockets are created under the harness's descriptor lock and marked
// close-on-exec, so no program a suite starts inherits one.
@(private)
open_socket :: proc "c" (user: rawptr, purpose: curl.curlsocktype, address: ^curl.curl_sockaddr) -> curl.curl_socket_t {
	context = runtime.default_context()
	fd := harness.socket(posix.AF(address.family), posix.Sock(address.socktype), posix.Protocol(address.protocol))
	if fd == -1 {
		return curl.CURL_SOCKET_BAD
	}
	return curl.curl_socket_t(fd)
}

@(private)
set_time :: proc "c" (handle: ^curl.CURL, ctx: rawptr, user: rawptr) -> curl.CURLcode {
	at := (cast(^i64)user)^
	openssl.X509_VERIFY_PARAM_set_time(openssl.SSL_CTX_get0_param(cast(^openssl.SSL_CTX)ctx), libc.time_t(at))
	return curl.CURLE_OK
}

// Runs one request on client. Everything in the response is in the temporary
// allocator.
perform :: proc(client: ^Client, request: Request) -> Response {
	return transfer(client, request, false)
}

@(private)
transfer :: proc(client: ^Client, request: Request, connect_only: bool) -> (response: Response) {
	h := client.handle
	curl.curl_easy_reset(h)
	sink: Sink
	sink.body.allocator = context.temp_allocator
	sink.headers.allocator = context.temp_allocator
	error_text: [curl.CURL_ERROR_SIZE]u8
	cstr :: proc(s: string) -> cstring {
		return strings.clone_to_cstring(s, context.temp_allocator)
	}
	_ = curl.setopt_string(h, curl.CURLOPT_URL, cstr(request.url))
	_ = curl.setopt_pointer(h, curl.CURLOPT_ERRORBUFFER, &error_text)
	_ = curl.setopt_long(h, curl.CURLOPT_NOSIGNAL, 1)
	_ = curl.setopt_pointer(h, curl.CURLOPT_OPENSOCKETFUNCTION, rawptr(open_socket))
	_ = curl.setopt_pointer(h, curl.CURLOPT_WRITEFUNCTION, rawptr(write_body))
	_ = curl.setopt_pointer(h, curl.CURLOPT_WRITEDATA, &sink)
	_ = curl.setopt_pointer(h, curl.CURLOPT_HEADERFUNCTION, rawptr(write_header))
	_ = curl.setopt_pointer(h, curl.CURLOPT_HEADERDATA, &sink)
	_ = curl.setopt_long(h, curl.CURLOPT_SSLVERSION, curl.CURL_SSLVERSION_TLSv1_3 | curl.CURL_SSLVERSION_MAX_TLSv1_3)
	timeout := request.timeout if request.timeout > 0 else 10 * time.Second
	_ = curl.setopt_long(h, curl.CURLOPT_TIMEOUT_MS, c.long(time.duration_milliseconds(timeout)))
	resolve: ^curl.curl_slist
	if request.resolve != "" {
		resolve = curl.curl_slist_append(nil, cstr(request.resolve))
		_ = curl.setopt_pointer(h, curl.CURLOPT_RESOLVE, resolve)
	}
	defer curl.curl_slist_free_all(resolve)
	headers: ^curl.curl_slist
	for field in request.headers {
		headers = curl.curl_slist_append(headers, cstr(field))
	}
	if headers != nil {
		_ = curl.setopt_pointer(h, curl.CURLOPT_HTTPHEADER, headers)
	}
	defer curl.curl_slist_free_all(headers)
	if body, has_body := request.body.?; has_body {
		_ = curl.setopt_long(h, curl.CURLOPT_POSTFIELDSIZE, c.long(len(body)))
		_ = curl.setopt_pointer(h, curl.CURLOPT_POSTFIELDS, raw_data(body))
	}
	if request.method != "" {
		_ = curl.setopt_string(h, curl.CURLOPT_CUSTOMREQUEST, cstr(request.method))
	}
	if request.http_version != 0 {
		_ = curl.setopt_long(h, curl.CURLOPT_HTTP_VERSION, request.http_version)
	}
	if request.ca_file != "" {
		_ = curl.setopt_string(h, curl.CURLOPT_CAINFO, cstr(request.ca_file))
		_ = curl.setopt_long(h, curl.CURLOPT_SSL_VERIFYPEER, 1)
		_ = curl.setopt_long(h, curl.CURLOPT_SSL_VERIFYHOST, 2)
	} else {
		_ = curl.setopt_long(h, curl.CURLOPT_SSL_VERIFYPEER, 0)
		_ = curl.setopt_long(h, curl.CURLOPT_SSL_VERIFYHOST, 0)
	}
	if request.cert != "" {
		_ = curl.setopt_string(h, curl.CURLOPT_SSLCERT, cstr(request.cert))
		_ = curl.setopt_string(h, curl.CURLOPT_SSLKEY, cstr(request.key))
	}
	at := request.verify_time
	if at != 0 {
		_ = curl.setopt_pointer(h, curl.CURLOPT_SSL_CTX_FUNCTION, rawptr(set_time))
		_ = curl.setopt_pointer(h, curl.CURLOPT_SSL_CTX_DATA, &at)
	}

	if connect_only {
		// The upgrade, then the connection is left to curl_ws_send and
		// curl_ws_recv.
		_ = curl.setopt_long(h, curl.CURLOPT_CONNECT_ONLY, 2)
	}
	response.code = curl.curl_easy_perform(h)
	if response.code != curl.CURLE_OK {
		detail := string(cstring(&error_text[0]))
		response.message = fmt.tprintf("%s: %s", curl.curl_easy_strerror(response.code), detail)
	}
	status, _ := curl.getinfo_long(h, curl.CURLINFO_RESPONSE_CODE)
	version, _ := curl.getinfo_long(h, curl.CURLINFO_HTTP_VERSION)
	verify, _ := curl.getinfo_long(h, curl.CURLINFO_SSL_VERIFYRESULT)
	connects, _ := curl.getinfo_long(h, curl.CURLINFO_NUM_CONNECTS)
	response.status = int(status)
	response.version = int(version)
	response.verify_result = int(verify)
	response.connects = int(connects)
	response.body = sink.body[:]
	response.headers = sink.headers[:]
	return
}

// The value of the last header field called name, case-insensitively.
header :: proc(response: Response, name: string) -> (string, bool) {
	#reverse for line in response.headers {
		colon := strings.index_byte(line, ':')
		if colon > 0 && strings.equal_fold(line[:colon], name) {
			return strings.trim_space(line[colon + 1:]), true
		}
	}
	return "", false
}
