package ngtcp2

import "core:c"

foreign import ssl_lib "system:ssl"
foreign import libcrypto "system:crypto"

// The OpenSSL calls a client of ngtcp2_crypto_ossl makes: a TLS context and
// session to hand to ngtcp2, and AES-ECB for header protection of packets a
// suite builds itself.
SSL_CTX :: struct {}
SSL :: struct {}
SSL_METHOD :: struct {}
EVP_CIPHER :: struct {}
EVP_CIPHER_CTX :: struct {}

SSL_VERIFY_PEER :: 0x01
SSL_CB_HANDSHAKE_START :: 0x10
SSL_CTRL_SET_TLSEXT_HOSTNAME :: 55
TLSEXT_NAMETYPE_host_name :: 0

Keylog_Callback :: #type proc "c" (ssl: ^SSL, line: cstring)
Info_Callback :: #type proc "c" (ssl: ^SSL, type: c.int, value: c.int)

@(default_calling_convention = "c")
foreign ssl_lib {
	TLS_client_method :: proc() -> ^SSL_METHOD ---
	SSL_CTX_new :: proc(method: ^SSL_METHOD) -> ^SSL_CTX ---
	SSL_CTX_free :: proc(ctx: ^SSL_CTX) ---
	SSL_CTX_load_verify_locations :: proc(ctx: ^SSL_CTX, ca_file: cstring, ca_path: cstring) -> c.int ---
	SSL_CTX_set_verify :: proc(ctx: ^SSL_CTX, mode: c.int, callback: rawptr) ---
	SSL_CTX_set_keylog_callback :: proc(ctx: ^SSL_CTX, callback: Keylog_Callback) ---
	SSL_new :: proc(ctx: ^SSL_CTX) -> ^SSL ---
	SSL_free :: proc(ssl: ^SSL) ---
	SSL_set_ex_data :: proc(ssl: ^SSL, index: c.int, data: rawptr) -> c.int ---
	SSL_get_ex_data :: proc(ssl: ^SSL, index: c.int) -> rawptr ---
	SSL_set_connect_state :: proc(ssl: ^SSL) ---
	SSL_set_alpn_protos :: proc(ssl: ^SSL, protos: [^]u8, protos_len: c.uint) -> c.int ---
	SSL_ctrl :: proc(ssl: ^SSL, command: c.int, larg: c.long, parg: rawptr) -> c.long ---
	SSL_set1_host :: proc(ssl: ^SSL, host: cstring) -> c.int ---
	SSL_set_ciphersuites :: proc(ssl: ^SSL, suites: cstring) -> c.int ---
	SSL_set_info_callback :: proc(ssl: ^SSL, callback: Info_Callback) ---
	SSL_set_quic_tls_transport_params :: proc(ssl: ^SSL, params: [^]u8, params_len: c.size_t) -> c.int ---
}

@(default_calling_convention = "c")
foreign libcrypto {
	EVP_aes_128_ecb :: proc() -> ^EVP_CIPHER ---
	EVP_CIPHER_CTX_new :: proc() -> ^EVP_CIPHER_CTX ---
	EVP_CIPHER_CTX_free :: proc(ctx: ^EVP_CIPHER_CTX) ---
	EVP_EncryptInit_ex :: proc(
		ctx: ^EVP_CIPHER_CTX,
		cipher: ^EVP_CIPHER,
		engine: rawptr,
		key: [^]u8,
		iv: [^]u8,
	) -> c.int ---
	EVP_EncryptUpdate :: proc(
		ctx: ^EVP_CIPHER_CTX,
		out: [^]u8,
		outl: ^c.int,
		input: [^]u8,
		inl: c.int,
	) -> c.int ---
}

// SSL_set_app_data and SSL_get_app_data, macros over ex_data index 0.
SSL_set_app_data :: proc "contextless" (ssl: ^SSL, data: rawptr) -> c.int {
	return SSL_set_ex_data(ssl, 0, data)
}

SSL_get_app_data :: proc "contextless" (ssl: ^SSL) -> rawptr {
	return SSL_get_ex_data(ssl, 0)
}

// SSL_set_tlsext_host_name, a macro over SSL_ctrl.
SSL_set_tlsext_host_name :: proc "contextless" (ssl: ^SSL, name: cstring) -> c.long {
	return SSL_ctrl(ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_host_name, rawptr(name))
}
