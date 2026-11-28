// The parts of nghttp3 (HTTP/3 over a QUIC stack of the caller's) the interop
// suites use. Versioned structs are declared at the version these bindings
// pass (CALLBACKS_V1, SETTINGS_V1); nghttp3 reads only the fields of that
// version.
package nghttp3

import "core:c"

foreign import lib "system:nghttp3"

CALLBACKS_V1 :: 1
SETTINGS_V1 :: 1

ERR_WOULDBLOCK :: -103
ERR_STREAM_NOT_FOUND :: -110

DATA_FLAG_EOF :: u32(0x01)

H3_NO_ERROR :: 0x0100
H3_INTERNAL_ERROR :: 0x0102
H3_REQUEST_REJECTED :: 0x010b
H3_REQUEST_CANCELLED :: 0x010c
H3_MESSAGE_ERROR :: 0x010e

Ssize :: int

Conn :: struct {}
Rcbuf :: struct {}

Vec :: struct {
	base: [^]u8,
	len:  c.size_t,
}

Nv :: struct {
	name:     [^]u8,
	value:    [^]u8,
	namelen:  c.size_t,
	valuelen: c.size_t,
	flags:    u8,
}

Settings :: struct {
	max_field_section_size:            u64,
	qpack_max_dtable_capacity:         c.size_t,
	qpack_encoder_max_dtable_capacity: c.size_t,
	qpack_blocked_streams:             c.size_t,
	enable_connect_protocol:           u8,
	h3_datagram:                       u8,
}

Acked_Stream_Data :: #type proc "c" (
	conn: ^Conn,
	stream_id: i64,
	datalen: u64,
	conn_user_data, stream_user_data: rawptr,
) -> c.int
Stream_Close :: #type proc "c" (
	conn: ^Conn,
	stream_id: i64,
	app_error_code: u64,
	conn_user_data, stream_user_data: rawptr,
) -> c.int
Recv_Data :: #type proc "c" (
	conn: ^Conn,
	stream_id: i64,
	data: [^]u8,
	datalen: c.size_t,
	conn_user_data, stream_user_data: rawptr,
) -> c.int
Deferred_Consume :: #type proc "c" (
	conn: ^Conn,
	stream_id: i64,
	consumed: c.size_t,
	conn_user_data, stream_user_data: rawptr,
) -> c.int
Begin_Headers :: #type proc "c" (
	conn: ^Conn,
	stream_id: i64,
	conn_user_data, stream_user_data: rawptr,
) -> c.int
Recv_Header :: #type proc "c" (
	conn: ^Conn,
	stream_id: i64,
	token: i32,
	name, value: ^Rcbuf,
	flags: u8,
	conn_user_data, stream_user_data: rawptr,
) -> c.int
End_Headers :: #type proc "c" (
	conn: ^Conn,
	stream_id: i64,
	fin: c.int,
	conn_user_data, stream_user_data: rawptr,
) -> c.int
End_Stream :: #type proc "c" (
	conn: ^Conn,
	stream_id: i64,
	conn_user_data, stream_user_data: rawptr,
) -> c.int
Stop_Sending :: #type proc "c" (
	conn: ^Conn,
	stream_id: i64,
	app_error_code: u64,
	conn_user_data, stream_user_data: rawptr,
) -> c.int
Reset_Stream :: Stop_Sending
Shutdown :: #type proc "c" (conn: ^Conn, id: i64, conn_user_data: rawptr) -> c.int
Recv_Settings :: #type proc "c" (conn: ^Conn, settings: ^Settings, conn_user_data: rawptr) -> c.int

// NGHTTP3_CALLBACKS_V1.
Callbacks :: struct {
	acked_stream_data: Acked_Stream_Data,
	stream_close:      Stream_Close,
	recv_data:         Recv_Data,
	deferred_consume:  Deferred_Consume,
	begin_headers:     Begin_Headers,
	recv_header:       Recv_Header,
	end_headers:       End_Headers,
	begin_trailers:    Begin_Headers,
	recv_trailer:      Recv_Header,
	end_trailers:      End_Headers,
	stop_sending:      Stop_Sending,
	end_stream:        End_Stream,
	reset_stream:      Reset_Stream,
	shutdown:          Shutdown,
	recv_settings:     Recv_Settings,
}

Read_Data_Callback :: #type proc "c" (
	conn: ^Conn,
	stream_id: i64,
	vec: [^]Vec,
	veccnt: c.size_t,
	pflags: ^u32,
	conn_user_data, stream_user_data: rawptr,
) -> Ssize

Data_Reader :: struct {
	read_data: Read_Data_Callback,
}

@(default_calling_convention = "c", link_prefix = "nghttp3_")
foreign lib {
	settings_default_versioned :: proc(settings_version: c.int, settings: ^Settings) ---
	conn_client_new_versioned :: proc(
		pconn: ^^Conn,
		callbacks_version: c.int,
		callbacks: ^Callbacks,
		settings_version: c.int,
		settings: ^Settings,
		mem: rawptr,
		conn_user_data: rawptr,
	) -> c.int ---
	conn_del :: proc(conn: ^Conn) ---
	conn_bind_control_stream :: proc(conn: ^Conn, stream_id: i64) -> c.int ---
	conn_bind_qpack_streams :: proc(conn: ^Conn, qenc_stream_id, qdec_stream_id: i64) -> c.int ---
	conn_read_stream :: proc(conn: ^Conn, stream_id: i64, src: [^]u8, srclen: c.size_t, fin: c.int) -> Ssize ---
	conn_writev_stream :: proc(
		conn: ^Conn,
		pstream_id: ^i64,
		pfin: ^c.int,
		vec: [^]Vec,
		veccnt: c.size_t,
	) -> Ssize ---
	conn_add_write_offset :: proc(conn: ^Conn, stream_id: i64, n: c.size_t) -> c.int ---
	conn_add_ack_offset :: proc(conn: ^Conn, stream_id: i64, n: u64) -> c.int ---
	conn_block_stream :: proc(conn: ^Conn, stream_id: i64) ---
	conn_unblock_stream :: proc(conn: ^Conn, stream_id: i64) -> c.int ---
	conn_shutdown_stream_write :: proc(conn: ^Conn, stream_id: i64) ---
	conn_shutdown_stream_read :: proc(conn: ^Conn, stream_id: i64) -> c.int ---
	conn_resume_stream :: proc(conn: ^Conn, stream_id: i64) -> c.int ---
	conn_close_stream :: proc(conn: ^Conn, stream_id: i64, app_error_code: u64) -> c.int ---
	conn_submit_request :: proc(
		conn: ^Conn,
		stream_id: i64,
		nva: [^]Nv,
		nvlen: c.size_t,
		dr: ^Data_Reader,
		stream_user_data: rawptr,
	) -> c.int ---
	conn_submit_trailers :: proc(conn: ^Conn, stream_id: i64, nva: [^]Nv, nvlen: c.size_t) -> c.int ---
	conn_submit_shutdown_notice :: proc(conn: ^Conn) -> c.int ---
	conn_shutdown :: proc(conn: ^Conn) -> c.int ---
	rcbuf_get_buf :: proc(rcbuf: ^Rcbuf) -> Vec ---
	strerror :: proc(liberr: c.int) -> cstring ---
}
