// The parts of OpenSSL (libssl and libcrypto, 3.5 or later) the interop suites
// call: a TLS client whose records the test moves between memory BIOs and a
// socket itself, so it can split, stall or truncate the bytes on the wire.
package openssl

import "core:c"
import "core:c/libc"

foreign import libssl "system:ssl"
foreign import libcrypto "system:crypto"

SSL_CTX :: struct {}
SSL :: struct {}
SSL_METHOD :: struct {}
BIO :: struct {}
BIO_METHOD :: struct {}
X509_VERIFY_PARAM :: struct {}
X509_STORE_CTX :: struct {}

SSL_verify_cb :: #type proc "c" (preverify_ok: c.int, x509_ctx: ^X509_STORE_CTX) -> c.int

TLS1_3_VERSION :: 0x0304
SSL_VERIFY_NONE :: 0x00
SSL_VERIFY_PEER :: 0x01

SSL_ERROR_NONE :: 0
SSL_ERROR_SSL :: 1
SSL_ERROR_WANT_READ :: 2
SSL_ERROR_WANT_WRITE :: 3
SSL_ERROR_SYSCALL :: 5
SSL_ERROR_ZERO_RETURN :: 6

SSL_CTRL_SET_TLSEXT_HOSTNAME :: 55
SSL_CTRL_SET_MIN_PROTO_VERSION :: 123
SSL_CTRL_SET_MAX_PROTO_VERSION :: 124
TLSEXT_NAMETYPE_host_name :: 0
BIO_CTRL_PENDING :: 10

X509_V_OK :: 0
X509_V_ERR_CERT_NOT_YET_VALID :: 9
X509_V_ERR_CERT_HAS_EXPIRED :: 10
X509_V_ERR_DEPTH_ZERO_SELF_SIGNED_CERT :: 18
X509_V_ERR_HOSTNAME_MISMATCH :: 62

@(default_calling_convention = "c")
foreign libssl {
	TLS_client_method :: proc() -> ^SSL_METHOD ---
	SSL_CTX_new :: proc(meth: ^SSL_METHOD) -> ^SSL_CTX ---
	SSL_CTX_free :: proc(ctx: ^SSL_CTX) ---
	SSL_CTX_ctrl :: proc(ctx: ^SSL_CTX, cmd: c.int, larg: c.long, parg: rawptr) -> c.long ---
	SSL_CTX_set_ciphersuites :: proc(ctx: ^SSL_CTX, str: cstring) -> c.int ---
	SSL_CTX_set_verify :: proc(ctx: ^SSL_CTX, mode: c.int, callback: SSL_verify_cb) ---
	SSL_CTX_load_verify_locations :: proc(ctx: ^SSL_CTX, CAfile: cstring, CApath: cstring) -> c.int ---
	SSL_CTX_get0_param :: proc(ctx: ^SSL_CTX) -> ^X509_VERIFY_PARAM ---
	SSL_CTX_set_alpn_protos :: proc(ctx: ^SSL_CTX, protos: [^]u8, protos_len: c.uint) -> c.int ---
	SSL_new :: proc(ctx: ^SSL_CTX) -> ^SSL ---
	SSL_free :: proc(ssl: ^SSL) ---
	SSL_ctrl :: proc(ssl: ^SSL, cmd: c.int, larg: c.long, parg: rawptr) -> c.long ---
	SSL_get0_param :: proc(ssl: ^SSL) -> ^X509_VERIFY_PARAM ---
	SSL_set_bio :: proc(s: ^SSL, rbio: ^BIO, wbio: ^BIO) ---
	SSL_set_connect_state :: proc(s: ^SSL) ---
	SSL_do_handshake :: proc(s: ^SSL) -> c.int ---
	SSL_read_ex :: proc(ssl: ^SSL, buf: rawptr, num: c.size_t, readbytes: ^c.size_t) -> c.int ---
	SSL_write_ex :: proc(s: ^SSL, buf: rawptr, num: c.size_t, written: ^c.size_t) -> c.int ---
	SSL_get_error :: proc(s: ^SSL, ret_code: c.int) -> c.int ---
	SSL_shutdown :: proc(s: ^SSL) -> c.int ---
	SSL_get_verify_result :: proc(ssl: ^SSL) -> c.long ---
	SSL_get0_alpn_selected :: proc(ssl: ^SSL, data: ^[^]u8, len: ^c.uint) ---
}

@(default_calling_convention = "c")
foreign libcrypto {
	BIO_s_mem :: proc() -> ^BIO_METHOD ---
	BIO_new :: proc(type: ^BIO_METHOD) -> ^BIO ---
	BIO_read :: proc(b: ^BIO, data: rawptr, dlen: c.int) -> c.int ---
	BIO_write :: proc(b: ^BIO, data: rawptr, dlen: c.int) -> c.int ---
	BIO_ctrl :: proc(bp: ^BIO, cmd: c.int, larg: c.long, parg: rawptr) -> c.long ---
	X509_VERIFY_PARAM_set_time :: proc(param: ^X509_VERIFY_PARAM, t: libc.time_t) ---
	X509_VERIFY_PARAM_set1_host :: proc(param: ^X509_VERIFY_PARAM, name: cstring, namelen: c.size_t) -> c.int ---
	ERR_get_error :: proc() -> c.ulong ---
	ERR_error_string_n :: proc(e: c.ulong, buf: [^]u8, len: c.size_t) ---
}

// The macros of ssl.h and bio.h over the calls above.
SSL_CTX_set_min_proto_version :: proc(ctx: ^SSL_CTX, version: c.long) -> bool {
	return SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, version, nil) == 1
}

SSL_CTX_set_max_proto_version :: proc(ctx: ^SSL_CTX, version: c.long) -> bool {
	return SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MAX_PROTO_VERSION, version, nil) == 1
}

SSL_set_tlsext_host_name :: proc(ssl: ^SSL, name: cstring) -> bool {
	return SSL_ctrl(ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_host_name, rawptr(name)) == 1
}

BIO_pending :: proc(b: ^BIO) -> int {
	return int(BIO_ctrl(b, BIO_CTRL_PENDING, 0, nil))
}
