// The parts of libcurl (8.x, with HTTP/2 and WebSocket) the interop suites
// call: easy transfers, their results, and WebSocket frames over a
// CURLOPT_CONNECT_ONLY transfer.
package curl

import "core:c"

foreign import lib "system:curl"

CURL :: struct {}

curl_slist :: struct {
	data: cstring,
	next: ^curl_slist,
}

curl_ws_frame :: struct {
	age:       c.int,
	flags:     c.int,
	offset:    curl_off_t,
	bytesleft: curl_off_t,
	len:       c.size_t,
}

curl_off_t :: i64
curl_socket_t :: c.int
curlsocktype :: c.int
CURLcode :: c.int
CURLoption :: c.int
CURLINFO :: c.int

// struct sockaddr follows the fixed fields; only its address is read here.
curl_sockaddr :: struct {
	family:   c.int,
	socktype: c.int,
	protocol: c.int,
	addrlen:  c.uint,
}

CURL_SOCKET_BAD :: -1

curl_opensocket_callback :: #type proc "c" (clientp: rawptr, purpose: curlsocktype, address: ^curl_sockaddr) -> curl_socket_t
curl_write_callback :: #type proc "c" (buffer: [^]u8, size: c.size_t, nitems: c.size_t, outstream: rawptr) -> c.size_t
curl_ssl_ctx_callback :: #type proc "c" (curl: ^CURL, ssl_ctx: rawptr, userptr: rawptr) -> CURLcode

CURL_GLOBAL_DEFAULT :: 3
CURL_ERROR_SIZE :: 256

CURLE_OK :: 0
CURLE_HTTP2 :: 16
CURLE_OPERATION_TIMEDOUT :: 28
CURLE_SSL_CONNECT_ERROR :: 35
CURLE_GOT_NOTHING :: 52
CURLE_RECV_ERROR :: 56
CURLE_PEER_FAILED_VERIFICATION :: 60
CURLE_AGAIN :: 81
CURLE_HTTP2_STREAM :: 92

CURLOPTTYPE_LONG :: 0
CURLOPTTYPE_OBJECTPOINT :: 10000
CURLOPTTYPE_FUNCTIONPOINT :: 20000

CURLOPT_WRITEDATA :: CURLOPTTYPE_OBJECTPOINT + 1
CURLOPT_URL :: CURLOPTTYPE_OBJECTPOINT + 2
CURLOPT_ERRORBUFFER :: CURLOPTTYPE_OBJECTPOINT + 10
CURLOPT_WRITEFUNCTION :: CURLOPTTYPE_FUNCTIONPOINT + 11
CURLOPT_POSTFIELDS :: CURLOPTTYPE_OBJECTPOINT + 15
CURLOPT_HTTPHEADER :: CURLOPTTYPE_OBJECTPOINT + 23
CURLOPT_SSLCERT :: CURLOPTTYPE_OBJECTPOINT + 25
CURLOPT_HEADERDATA :: CURLOPTTYPE_OBJECTPOINT + 29
CURLOPT_SSLVERSION :: CURLOPTTYPE_LONG + 32
CURLOPT_CUSTOMREQUEST :: CURLOPTTYPE_OBJECTPOINT + 36
CURLOPT_VERBOSE :: CURLOPTTYPE_LONG + 41
CURLOPT_POSTFIELDSIZE :: CURLOPTTYPE_LONG + 60
CURLOPT_SSL_VERIFYPEER :: CURLOPTTYPE_LONG + 64
CURLOPT_CAINFO :: CURLOPTTYPE_OBJECTPOINT + 65
CURLOPT_FRESH_CONNECT :: CURLOPTTYPE_LONG + 74
CURLOPT_FORBID_REUSE :: CURLOPTTYPE_LONG + 75
CURLOPT_HEADERFUNCTION :: CURLOPTTYPE_FUNCTIONPOINT + 79
CURLOPT_SSL_VERIFYHOST :: CURLOPTTYPE_LONG + 81
CURLOPT_HTTP_VERSION :: CURLOPTTYPE_LONG + 84
CURLOPT_SSLKEY :: CURLOPTTYPE_OBJECTPOINT + 87
CURLOPT_NOSIGNAL :: CURLOPTTYPE_LONG + 99
CURLOPT_SSL_CTX_FUNCTION :: CURLOPTTYPE_FUNCTIONPOINT + 108
CURLOPT_SSL_CTX_DATA :: CURLOPTTYPE_OBJECTPOINT + 109
CURLOPT_CONNECT_ONLY :: CURLOPTTYPE_LONG + 141
CURLOPT_OPENSOCKETFUNCTION :: CURLOPTTYPE_FUNCTIONPOINT + 163
CURLOPT_OPENSOCKETDATA :: CURLOPTTYPE_OBJECTPOINT + 164
CURLOPT_TIMEOUT_MS :: CURLOPTTYPE_LONG + 155
CURLOPT_CONNECTTIMEOUT_MS :: CURLOPTTYPE_LONG + 156
CURLOPT_RESOLVE :: CURLOPTTYPE_OBJECTPOINT + 203

CURL_HTTP_VERSION_1_1 :: 2
CURL_HTTP_VERSION_2_0 :: 3
CURL_HTTP_VERSION_2TLS :: 4
CURL_SSLVERSION_TLSv1_3 :: 7
CURL_SSLVERSION_MAX_TLSv1_3 :: CURL_SSLVERSION_TLSv1_3 << 16

CURLINFO_LONG :: 0x200000
CURLINFO_RESPONSE_CODE :: CURLINFO_LONG + 2
CURLINFO_SSL_VERIFYRESULT :: CURLINFO_LONG + 13
CURLINFO_NUM_CONNECTS :: CURLINFO_LONG + 26
CURLINFO_HTTP_VERSION :: CURLINFO_LONG + 46

CURLWS_TEXT :: 1 << 0
CURLWS_BINARY :: 1 << 1
CURLWS_CONT :: 1 << 2
CURLWS_CLOSE :: 1 << 3
CURLWS_PING :: 1 << 4
CURLWS_PONG :: 1 << 6

@(default_calling_convention = "c")
foreign lib {
	curl_global_init :: proc(flags: c.long) -> CURLcode ---
	curl_easy_init :: proc() -> ^CURL ---
	curl_easy_setopt :: proc(curl: ^CURL, option: CURLoption, #c_vararg args: ..any) -> CURLcode ---
	curl_easy_perform :: proc(curl: ^CURL) -> CURLcode ---
	curl_easy_getinfo :: proc(curl: ^CURL, info: CURLINFO, #c_vararg args: ..any) -> CURLcode ---
	curl_easy_cleanup :: proc(curl: ^CURL) ---
	curl_easy_reset :: proc(curl: ^CURL) ---
	curl_easy_strerror :: proc(code: CURLcode) -> cstring ---
	curl_slist_append :: proc(list: ^curl_slist, data: cstring) -> ^curl_slist ---
	curl_slist_free_all :: proc(list: ^curl_slist) ---
	curl_ws_recv :: proc(curl: ^CURL, buffer: rawptr, buflen: c.size_t, recv: ^c.size_t, metap: ^^curl_ws_frame) -> CURLcode ---
	curl_ws_send :: proc(curl: ^CURL, buffer_arg: rawptr, buflen: c.size_t, sent: ^c.size_t, fragsize: curl_off_t, flags: c.uint) -> CURLcode ---
}

// curl_easy_setopt with the argument type each kind of option takes.
setopt_long :: proc(curl: ^CURL, option: CURLoption, value: c.long) -> CURLcode {
	return curl_easy_setopt(curl, option, value)
}

setopt_pointer :: proc(curl: ^CURL, option: CURLoption, value: rawptr) -> CURLcode {
	return curl_easy_setopt(curl, option, value)
}

setopt_string :: proc(curl: ^CURL, option: CURLoption, value: cstring) -> CURLcode {
	return curl_easy_setopt(curl, option, value)
}

// curl_easy_getinfo for a CURLINFO_LONG result.
getinfo_long :: proc(curl: ^CURL, info: CURLINFO) -> (c.long, CURLcode) {
	value: c.long
	code := curl_easy_getinfo(curl, info, &value)
	return value, code
}
