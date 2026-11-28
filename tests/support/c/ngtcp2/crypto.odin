package ngtcp2

import "core:c"

foreign import crypto_lib "system:ngtcp2_crypto_ossl"

// The packet protection helpers of ngtcp2_crypto and its OpenSSL backend
// (ngtcp2_crypto_ossl). The callbacks are the library's own implementations
// of the Callbacks fields of the same name.
Crypto_Conn_Ref :: struct {
	get_conn:  proc "c" (conn_ref: ^Crypto_Conn_Ref) -> ^Conn,
	user_data: rawptr,
}

Crypto_Ossl_Ctx :: struct {}

@(default_calling_convention = "c", link_prefix = "ngtcp2_")
foreign crypto_lib {
	crypto_ossl_init :: proc() -> c.int ---
	crypto_ossl_ctx_new :: proc(pctx: ^^Crypto_Ossl_Ctx, ssl: ^SSL) -> c.int ---
	crypto_ossl_ctx_del :: proc(ctx: ^Crypto_Ossl_Ctx) ---
	crypto_ossl_configure_client_session :: proc(ssl: ^SSL) -> c.int ---

	crypto_ctx_tls :: proc(ctx: ^Crypto_Ctx, tls_native_handle: rawptr) -> ^Crypto_Ctx ---
	crypto_aead_keylen :: proc(aead: ^Crypto_Aead) -> c.size_t ---
	crypto_packet_protection_ivlen :: proc(aead: ^Crypto_Aead) -> c.size_t ---
	crypto_hkdf_extract :: proc(
		dest: [^]u8,
		md: ^Crypto_Md,
		secret: [^]u8,
		secretlen: c.size_t,
		salt: [^]u8,
		saltlen: c.size_t,
	) -> c.int ---
	crypto_hkdf_expand :: proc(
		dest: [^]u8,
		destlen: c.size_t,
		md: ^Crypto_Md,
		secret: [^]u8,
		secretlen: c.size_t,
		info: [^]u8,
		infolen: c.size_t,
	) -> c.int ---
	crypto_aead_ctx_encrypt_init :: proc(
		aead_ctx: ^Crypto_Aead_Ctx,
		aead: ^Crypto_Aead,
		key: [^]u8,
		noncelen: c.size_t,
	) -> c.int ---
	crypto_aead_ctx_decrypt_init :: proc(
		aead_ctx: ^Crypto_Aead_Ctx,
		aead: ^Crypto_Aead,
		key: [^]u8,
		noncelen: c.size_t,
	) -> c.int ---
	crypto_aead_ctx_free :: proc(aead_ctx: ^Crypto_Aead_Ctx) ---
	crypto_encrypt :: proc(
		dest: [^]u8,
		aead: ^Crypto_Aead,
		aead_ctx: ^Crypto_Aead_Ctx,
		plaintext: [^]u8,
		plaintextlen: c.size_t,
		nonce: [^]u8,
		noncelen: c.size_t,
		aad: [^]u8,
		aadlen: c.size_t,
	) -> c.int ---
	crypto_decrypt :: proc(
		dest: [^]u8,
		aead: ^Crypto_Aead,
		aead_ctx: ^Crypto_Aead_Ctx,
		ciphertext: [^]u8,
		ciphertextlen: c.size_t,
		nonce: [^]u8,
		noncelen: c.size_t,
		aad: [^]u8,
		aadlen: c.size_t,
	) -> c.int ---

	crypto_client_initial_cb :: proc(conn: ^Conn, user_data: rawptr) -> c.int ---
	crypto_recv_crypto_data_cb :: proc(
		conn: ^Conn,
		level: Encryption_Level,
		offset: u64,
		data: [^]u8,
		datalen: c.size_t,
		user_data: rawptr,
	) -> c.int ---
	crypto_encrypt_cb :: proc(
		dest: [^]u8,
		aead: ^Crypto_Aead,
		aead_ctx: ^Crypto_Aead_Ctx,
		plaintext: [^]u8,
		plaintextlen: c.size_t,
		nonce: [^]u8,
		noncelen: c.size_t,
		aad: [^]u8,
		aadlen: c.size_t,
	) -> c.int ---
	crypto_decrypt_cb :: proc(
		dest: [^]u8,
		aead: ^Crypto_Aead,
		aead_ctx: ^Crypto_Aead_Ctx,
		ciphertext: [^]u8,
		ciphertextlen: c.size_t,
		nonce: [^]u8,
		noncelen: c.size_t,
		aad: [^]u8,
		aadlen: c.size_t,
	) -> c.int ---
	crypto_hp_mask_cb :: proc(
		dest: [^]u8,
		hp: ^Crypto_Cipher,
		hp_ctx: ^Crypto_Cipher_Ctx,
		sample: [^]u8,
	) -> c.int ---
	crypto_recv_retry_cb :: proc(conn: ^Conn, hd: ^Pkt_Hd, user_data: rawptr) -> c.int ---
	crypto_update_key_cb :: proc(
		conn: ^Conn,
		rx_secret,
		tx_secret: [^]u8,
		rx_aead_ctx: ^Crypto_Aead_Ctx,
		rx_iv: [^]u8,
		tx_aead_ctx: ^Crypto_Aead_Ctx,
		tx_iv: [^]u8,
		current_rx_secret,
		current_tx_secret: [^]u8,
		secretlen: c.size_t,
		user_data: rawptr,
	) -> c.int ---
	crypto_delete_crypto_aead_ctx_cb :: proc(conn: ^Conn, aead_ctx: ^Crypto_Aead_Ctx, user_data: rawptr) ---
	crypto_delete_crypto_cipher_ctx_cb :: proc(
		conn: ^Conn,
		cipher_ctx: ^Crypto_Cipher_Ctx,
		user_data: rawptr,
	) ---
	crypto_get_path_challenge_data_cb :: proc(conn: ^Conn, data: [^]u8, user_data: rawptr) -> c.int ---
	crypto_version_negotiation_cb :: proc(
		conn: ^Conn,
		version: u32,
		client_dcid: ^Cid,
		user_data: rawptr,
	) -> c.int ---
}
