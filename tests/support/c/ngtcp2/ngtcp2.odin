// The parts of ngtcp2 (QUIC) the interop suites use. Versioned structs are
// declared at the version these bindings pass (SETTINGS_V1, CALLBACKS_V1,
// TRANSPORT_PARAMS_V1, PKT_INFO_V1): ngtcp2 reads only the fields of the
// version it is told, so a newer library accepts them unchanged.
package ngtcp2

import "core:c"
import "core:sys/posix"

foreign import lib "system:ngtcp2"

PROTO_VER_V1 :: u32(0x00000001)
MAX_CIDLEN :: 20
STATELESS_RESET_TOKENLEN :: 16
MAX_UDP_PAYLOAD_SIZE :: 1200

SETTINGS_V1 :: 1
CALLBACKS_V1 :: 1
TRANSPORT_PARAMS_V1 :: 1
PKT_INFO_V1 :: 1

WRITE_STREAM_FLAG_MORE :: u32(0x01)
WRITE_STREAM_FLAG_FIN :: u32(0x02)

STREAM_DATA_FLAG_FIN :: u32(0x01)
STREAM_CLOSE_FLAG_APP_ERROR_CODE_SET :: u32(0x01)

ERR_STREAM_DATA_BLOCKED :: -208
ERR_STREAM_SHUT_WR :: -219
ERR_STREAM_NOT_FOUND :: -220
ERR_CLOSING :: -223
ERR_DRAINING :: -224
ERR_WRITE_MORE :: -230
ERR_IDLE_CLOSE :: -238
ERR_CALLBACK_FAILURE :: -502

Tstamp :: u64
Duration :: u64
Ssize :: int

Conn :: struct {}
Pkt_Hd :: struct {}

Cid :: struct {
	datalen: c.size_t,
	data:    [MAX_CIDLEN]u8,
}

Vec :: struct {
	base: [^]u8,
	len:  c.size_t,
}

Addr :: struct {
	addr:    ^posix.sockaddr,
	addrlen: posix.socklen_t,
}

Path :: struct {
	local:     Addr,
	remote:    Addr,
	user_data: rawptr,
}

Pkt_Info :: struct #align (8) {
	ecn: u8,
}

Encryption_Level :: enum c.int {
	Initial,
	Handshake,
	One_RTT,
	Zero_RTT,
}

Ccerr_Type :: enum c.int {
	Transport,
	Application,
	Version_Negotiation,
	Idle_Close,
	Drop_Conn,
	Retry,
}

Ccerr :: struct {
	type:       Ccerr_Type,
	error_code: u64,
	frame_type: u64,
	reason:     [^]u8,
	reasonlen:  c.size_t,
}

Rand_Ctx :: struct {
	native_handle: rawptr,
}

Settings :: struct {
	qlog_write:                     rawptr,
	cc_algo:                        c.int,
	initial_ts:                     Tstamp,
	initial_rtt:                    Duration,
	log_printf:                     rawptr,
	max_tx_udp_payload_size:        c.size_t,
	token:                          [^]u8,
	tokenlen:                       c.size_t,
	token_type:                     c.int,
	rand_ctx:                       Rand_Ctx,
	max_window:                     u64,
	max_stream_window:              u64,
	ack_thresh:                     c.size_t,
	no_tx_udp_payload_size_shaping: u8,
	handshake_timeout:              Duration,
	preferred_versions:             [^]u32,
	preferred_versionslen:          c.size_t,
	available_versions:             [^]u32,
	available_versionslen:          c.size_t,
	original_version:               u32,
	no_pmtud:                       u8,
	initial_pkt_num:                u32,
}

Preferred_Addr :: struct {
	cid:                   Cid,
	ipv4:                  posix.sockaddr_in,
	ipv6:                  posix.sockaddr_in6,
	ipv4_present:          u8,
	ipv6_present:          u8,
	stateless_reset_token: [STATELESS_RESET_TOKENLEN]u8,
}

Version_Info :: struct {
	chosen_version:        u32,
	available_versions:    [^]u8,
	available_versionslen: c.size_t,
}

Transport_Params :: struct {
	preferred_addr:                      Preferred_Addr,
	original_dcid:                       Cid,
	initial_scid:                        Cid,
	retry_scid:                          Cid,
	initial_max_stream_data_bidi_local:  u64,
	initial_max_stream_data_bidi_remote: u64,
	initial_max_stream_data_uni:         u64,
	initial_max_data:                    u64,
	initial_max_streams_bidi:            u64,
	initial_max_streams_uni:             u64,
	max_idle_timeout:                    Duration,
	max_udp_payload_size:                u64,
	active_connection_id_limit:          u64,
	ack_delay_exponent:                  u64,
	max_ack_delay:                       Duration,
	max_datagram_frame_size:             u64,
	stateless_reset_token_present:       u8,
	disable_active_migration:            u8,
	original_dcid_present:               u8,
	initial_scid_present:                u8,
	retry_scid_present:                  u8,
	preferred_addr_present:              u8,
	stateless_reset_token:               [STATELESS_RESET_TOKENLEN]u8,
	grease_quic_bit:                     u8,
	version_info:                        Version_Info,
	version_info_present:                u8,
}

Crypto_Aead :: struct {
	native_handle: rawptr,
	max_overhead:  c.size_t,
}

Crypto_Md :: struct {
	native_handle: rawptr,
}

Crypto_Cipher :: struct {
	native_handle: rawptr,
}

Crypto_Aead_Ctx :: struct {
	native_handle: rawptr,
}

Crypto_Cipher_Ctx :: struct {
	native_handle: rawptr,
}

Crypto_Ctx :: struct {
	aead:                   Crypto_Aead,
	md:                     Crypto_Md,
	hp:                     Crypto_Cipher,
	max_encryption:         u64,
	max_decryption_failure: u64,
}

Client_Initial :: #type proc "c" (conn: ^Conn, user_data: rawptr) -> c.int
Recv_Crypto_Data :: #type proc "c" (
	conn: ^Conn,
	level: Encryption_Level,
	offset: u64,
	data: [^]u8,
	datalen: c.size_t,
	user_data: rawptr,
) -> c.int
Handshake_Completed :: #type proc "c" (conn: ^Conn, user_data: rawptr) -> c.int
Encrypt :: #type proc "c" (
	dest: [^]u8,
	aead: ^Crypto_Aead,
	aead_ctx: ^Crypto_Aead_Ctx,
	plaintext: [^]u8,
	plaintextlen: c.size_t,
	nonce: [^]u8,
	noncelen: c.size_t,
	aad: [^]u8,
	aadlen: c.size_t,
) -> c.int
Decrypt :: Encrypt
Hp_Mask :: #type proc "c" (
	dest: [^]u8,
	hp: ^Crypto_Cipher,
	hp_ctx: ^Crypto_Cipher_Ctx,
	sample: [^]u8,
) -> c.int
Recv_Stream_Data :: #type proc "c" (
	conn: ^Conn,
	flags: u32,
	stream_id: i64,
	offset: u64,
	data: [^]u8,
	datalen: c.size_t,
	user_data: rawptr,
	stream_user_data: rawptr,
) -> c.int
Acked_Stream_Data_Offset :: #type proc "c" (
	conn: ^Conn,
	stream_id: i64,
	offset: u64,
	datalen: u64,
	user_data: rawptr,
	stream_user_data: rawptr,
) -> c.int
Stream_Close :: #type proc "c" (
	conn: ^Conn,
	flags: u32,
	stream_id: i64,
	app_error_code: u64,
	user_data: rawptr,
	stream_user_data: rawptr,
) -> c.int
Recv_Retry :: #type proc "c" (conn: ^Conn, hd: ^Pkt_Hd, user_data: rawptr) -> c.int
Extend_Max_Streams :: #type proc "c" (conn: ^Conn, max_streams: u64, user_data: rawptr) -> c.int
Rand :: #type proc "c" (dest: [^]u8, destlen: c.size_t, rand_ctx: ^Rand_Ctx)
Get_New_Connection_Id :: #type proc "c" (
	conn: ^Conn,
	cid: ^Cid,
	token: [^]u8,
	cidlen: c.size_t,
	user_data: rawptr,
) -> c.int
Update_Key :: #type proc "c" (
	conn: ^Conn,
	rx_secret, tx_secret: [^]u8,
	rx_aead_ctx: ^Crypto_Aead_Ctx,
	rx_iv: [^]u8,
	tx_aead_ctx: ^Crypto_Aead_Ctx,
	tx_iv: [^]u8,
	current_rx_secret, current_tx_secret: [^]u8,
	secretlen: c.size_t,
	user_data: rawptr,
) -> c.int
Stream_Reset :: #type proc "c" (
	conn: ^Conn,
	stream_id: i64,
	final_size: u64,
	app_error_code: u64,
	user_data: rawptr,
	stream_user_data: rawptr,
) -> c.int
Extend_Max_Stream_Data :: #type proc "c" (
	conn: ^Conn,
	stream_id: i64,
	max_data: u64,
	user_data: rawptr,
	stream_user_data: rawptr,
) -> c.int
Delete_Crypto_Aead_Ctx :: #type proc "c" (
	conn: ^Conn,
	aead_ctx: ^Crypto_Aead_Ctx,
	user_data: rawptr,
)
Delete_Crypto_Cipher_Ctx :: #type proc "c" (
	conn: ^Conn,
	cipher_ctx: ^Crypto_Cipher_Ctx,
	user_data: rawptr,
)
Get_Path_Challenge_Data :: #type proc "c" (conn: ^Conn, data: [^]u8, user_data: rawptr) -> c.int
Stream_Stop_Sending :: #type proc "c" (
	conn: ^Conn,
	stream_id: i64,
	app_error_code: u64,
	user_data: rawptr,
	stream_user_data: rawptr,
) -> c.int
Version_Negotiation :: #type proc "c" (
	conn: ^Conn,
	version: u32,
	client_dcid: ^Cid,
	user_data: rawptr,
) -> c.int

// NGTCP2_CALLBACKS_V1. The fields left rawptr are not used here.
Callbacks :: struct {
	client_initial:                 Client_Initial,
	recv_client_initial:            rawptr,
	recv_crypto_data:               Recv_Crypto_Data,
	handshake_completed:            Handshake_Completed,
	recv_version_negotiation:       rawptr,
	encrypt:                        Encrypt,
	decrypt:                        Decrypt,
	hp_mask:                        Hp_Mask,
	recv_stream_data:               Recv_Stream_Data,
	acked_stream_data_offset:       Acked_Stream_Data_Offset,
	stream_open:                    rawptr,
	stream_close:                   Stream_Close,
	recv_stateless_reset:           rawptr,
	recv_retry:                     Recv_Retry,
	extend_max_local_streams_bidi:  Extend_Max_Streams,
	extend_max_local_streams_uni:   Extend_Max_Streams,
	rand:                           Rand,
	get_new_connection_id:          Get_New_Connection_Id,
	remove_connection_id:           rawptr,
	update_key:                     Update_Key,
	path_validation:                rawptr,
	select_preferred_addr:          rawptr,
	stream_reset:                   Stream_Reset,
	extend_max_remote_streams_bidi: Extend_Max_Streams,
	extend_max_remote_streams_uni:  Extend_Max_Streams,
	extend_max_stream_data:         Extend_Max_Stream_Data,
	dcid_status:                    rawptr,
	handshake_confirmed:            Handshake_Completed,
	recv_new_token:                 rawptr,
	delete_crypto_aead_ctx:         Delete_Crypto_Aead_Ctx,
	delete_crypto_cipher_ctx:       Delete_Crypto_Cipher_Ctx,
	recv_datagram:                  rawptr,
	ack_datagram:                   rawptr,
	lost_datagram:                  rawptr,
	get_path_challenge_data:        Get_Path_Challenge_Data,
	stream_stop_sending:            Stream_Stop_Sending,
	version_negotiation:            Version_Negotiation,
	recv_rx_key:                    rawptr,
	recv_tx_key:                    rawptr,
	tls_early_data_rejected:        rawptr,
}

@(default_calling_convention = "c", link_prefix = "ngtcp2_")
foreign lib {
	settings_default_versioned :: proc(settings_version: c.int, settings: ^Settings) ---
	transport_params_default_versioned :: proc(transport_params_version: c.int, params: ^Transport_Params) ---
	conn_client_new_versioned :: proc(
		pconn: ^^Conn,
		dcid,
		scid: ^Cid,
		path: ^Path,
		client_chosen_version: u32,
		callbacks_version: c.int,
		callbacks: ^Callbacks,
		settings_version: c.int,
		settings: ^Settings,
		transport_params_version: c.int,
		params: ^Transport_Params,
		mem: rawptr,
		user_data: rawptr,
	) -> c.int ---
	conn_del :: proc(conn: ^Conn) ---
	conn_read_pkt_versioned :: proc(
		conn: ^Conn,
		path: ^Path,
		pkt_info_version: c.int,
		pi: ^Pkt_Info,
		pkt: [^]u8,
		pktlen: c.size_t,
		ts: Tstamp,
	) -> c.int ---
	conn_writev_stream_versioned :: proc(
		conn: ^Conn,
		path: ^Path,
		pkt_info_version: c.int,
		pi: ^Pkt_Info,
		dest: [^]u8,
		destlen: c.size_t,
		pdatalen: ^Ssize,
		flags: u32,
		stream_id: i64,
		datav: [^]Vec,
		datavcnt: c.size_t,
		ts: Tstamp,
	) -> Ssize ---
	conn_write_connection_close_versioned :: proc(
		conn: ^Conn,
		path: ^Path,
		pkt_info_version: c.int,
		pi: ^Pkt_Info,
		dest: [^]u8,
		destlen: c.size_t,
		ccerr: ^Ccerr,
		ts: Tstamp,
	) -> Ssize ---
	conn_get_expiry2 :: proc(conn: ^Conn) -> Tstamp ---
	conn_get_pto2 :: proc(conn: ^Conn) -> Duration ---
	conn_handle_expiry :: proc(conn: ^Conn, ts: Tstamp) -> c.int ---
	conn_set_keep_alive_timeout :: proc(conn: ^Conn, timeout: Duration) ---
	conn_get_remote_transport_params2 :: proc(conn: ^Conn) -> ^Transport_Params ---
	conn_encode_local_transport_params2 :: proc(conn: ^Conn, dest: [^]u8, destlen: c.size_t) -> Ssize ---
	conn_open_bidi_stream :: proc(conn: ^Conn, pstream_id: ^i64, stream_user_data: rawptr) -> c.int ---
	conn_open_uni_stream :: proc(conn: ^Conn, pstream_id: ^i64, stream_user_data: rawptr) -> c.int ---
	conn_shutdown_stream :: proc(conn: ^Conn, flags: u32, stream_id: i64, app_error_code: u64) -> c.int ---
	conn_shutdown_stream_write :: proc(conn: ^Conn, flags: u32, stream_id: i64, app_error_code: u64) -> c.int ---
	conn_shutdown_stream_read :: proc(conn: ^Conn, flags: u32, stream_id: i64, app_error_code: u64) -> c.int ---
	conn_extend_max_stream_offset :: proc(conn: ^Conn, stream_id: i64, datalen: u64) -> c.int ---
	conn_extend_max_offset :: proc(conn: ^Conn, datalen: u64) ---
	conn_in_draining_period2 :: proc(conn: ^Conn) -> c.int ---
	conn_get_ccerr2 :: proc(conn: ^Conn) -> ^Ccerr ---
	conn_get_initial_crypto_ctx2 :: proc(conn: ^Conn) -> ^Crypto_Ctx ---
	conn_set_tls_native_handle :: proc(conn: ^Conn, tls_native_handle: rawptr) ---
	ccerr_set_application_error :: proc(ccerr: ^Ccerr, error_code: u64, reason: [^]u8, reasonlen: c.size_t) ---
	ccerr_default :: proc(ccerr: ^Ccerr) ---
	strerror :: proc(liberr: c.int) -> cstring ---
}
