package saba_test_h3_peer

import nghttp3 "../../../support/c/nghttp3"
import ngtcp2 "../../../support/c/ngtcp2"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:time"

Field :: struct {
	name, value: string,
}

// A request stream: what was sent on it and what came back.
Stream :: struct {
	client:        ^Client,
	id:            i64,
	// Written and read outside nghttp3: body holds the raw bytes received.
	raw:           bool,
	headers:       [dynamic]Field,
	trailers:      [dynamic]Field,
	// The header sections that arrived before the trailers.
	sections:      int,
	body:          [dynamic]u8,
	// The response is complete (the stream ended).
	ended:         bool,
	closed:        bool,
	// The QUIC stream closed before nghttp3 delivered the response.
	close_pending: bool,
	close_code:    u64,
	// The application error codes of the server's RESET_STREAM and
	// STOP_SENDING, or -1.
	reset:         i64,
	stopped:       i64,
	// The highest stream offset the server sent, and the sizes of the first
	// stream frames that arrived.
	received:      u64,
	chunks:        [dynamic]int,
	// The client never extends this stream's credit; withheld counts the
	// bytes it consumed without returning credit for them.
	withhold:      bool,
	withheld:      u64,
	// Request body chunks, kept until the stream is freed (nghttp3 refers to
	// them until they are acknowledged).
	outgoing:      [dynamic][]u8,
	submitted:     int,
	eof:           bool,
	reader:        nghttp3.Data_Reader,
}

// The status of the response, or 0.
status :: proc(s: ^Stream) -> int {
	value := header(s, ":status")
	n := 0
	for ch in value {
		n = n * 10 + int(ch - '0')
	}
	return n
}

header :: proc(s: ^Stream, name: string) -> string {
	for f in s.headers {
		if f.name == name {
			return f.value
		}
	}
	return ""
}

stream_new :: proc(cl: ^Client, id: i64) -> ^Stream {
	s := new(Stream, cl.allocator)
	s.client = cl
	s.id = id
	s.reset = -1
	s.stopped = -1
	s.headers = make([dynamic]Field, cl.allocator)
	s.trailers = make([dynamic]Field, cl.allocator)
	s.body = make([dynamic]u8, cl.allocator)
	s.chunks = make([dynamic]int, cl.allocator)
	s.outgoing = make([dynamic][]u8, cl.allocator)
	cl.streams[id] = s
	return s
}

stream_free :: proc(s: ^Stream) {
	allocator := s.client.allocator
	for f in s.headers {
		delete(f.name, allocator)
		delete(f.value, allocator)
	}
	for f in s.trailers {
		delete(f.name, allocator)
		delete(f.value, allocator)
	}
	for chunk in s.outgoing {
		delete(chunk, allocator)
	}
	delete(s.headers)
	delete(s.trailers)
	delete(s.body)
	delete(s.chunks)
	delete(s.outgoing)
	free(s, allocator)
}

open_http3 :: proc(cl: ^Client) -> bool {
	callbacks := nghttp3.Callbacks {
		stream_close     = h3_stream_close,
		recv_data        = h3_recv_data,
		deferred_consume = h3_deferred_consume,
		recv_header      = h3_recv_header,
		begin_trailers   = h3_begin_trailers,
		recv_trailer     = h3_recv_header,
		stop_sending     = h3_stop_sending,
		end_stream       = h3_end_stream,
		reset_stream     = h3_reset_stream,
		shutdown         = h3_shutdown,
	}
	settings: nghttp3.Settings
	nghttp3.settings_default_versioned(nghttp3.SETTINGS_V1, &settings)
	settings.qpack_max_dtable_capacity = 4096
	settings.qpack_encoder_max_dtable_capacity = 4096
	settings.qpack_blocked_streams = 16
	if rv := nghttp3.conn_client_new_versioned(
		&cl.h3,
		nghttp3.CALLBACKS_V1,
		&callbacks,
		nghttp3.SETTINGS_V1,
		&settings,
		nil,
		cl,
	); rv != 0 {
		return fail(cl, fmt.tprintf("nghttp3_conn_client_new: %s", nghttp3.strerror(rv)))
	}
	control, encoder, decoder: i64
	if ngtcp2.conn_open_uni_stream(cl.conn, &control, nil) != 0 ||
	   ngtcp2.conn_open_uni_stream(cl.conn, &encoder, nil) != 0 ||
	   ngtcp2.conn_open_uni_stream(cl.conn, &decoder, nil) != 0 {
		return fail(cl, "could not open the HTTP/3 unidirectional streams")
	}
	if nghttp3.conn_bind_control_stream(cl.h3, control) != 0 ||
	   nghttp3.conn_bind_qpack_streams(cl.h3, encoder, decoder) != 0 {
		return fail(cl, "could not bind the HTTP/3 control streams")
	}
	return true
}

Request :: struct {
	method:    string,
	path:      string,
	authority: string,
	// :protocol, for an extended CONNECT.
	protocol:  string,
	headers:   []Field,
	body:      []u8,
	// Leave the request stream open after the body (more with send).
	open:      bool,
	trailers:  []Field,
	withhold:  bool,
}

// Submits a request on a new stream, after the handshake when it has not
// completed yet. The body is sent after the headers; unless request.open the
// stream ends after it (or after the trailers).
request :: proc(cl: ^Client, request: Request) -> ^Stream {
	if cl.h3 == nil && !cl.closed {
		handshake(cl)
	}
	if cl.h3 == nil {
		fail(cl, "HTTP/3 is not open")
		return nil
	}
	id: i64
	if rv := ngtcp2.conn_open_bidi_stream(cl.conn, &id, nil); rv != 0 {
		fail(cl, fmt.tprintf("ngtcp2_conn_open_bidi_stream: %s", ngtcp2.strerror(rv)))
		return nil
	}
	s := stream_new(cl, id)
	s.withhold = request.withhold
	fields := make([dynamic]Field, context.temp_allocator)
	method := request.method if request.method != "" else "GET"
	append(&fields, Field{":method", method})
	if request.protocol != "" {
		append(&fields, Field{":protocol", request.protocol})
	}
	authority := request.authority if request.authority != "" else cl.config.server_name
	append(
		&fields,
		Field{":scheme", "https"},
		Field{":authority", authority},
		Field{":path", request.path},
	)
	append(&fields, ..request.headers)
	nva := name_values(fields[:])
	if len(request.body) > 0 {
		send(s, request.body)
	}
	s.eof = !request.open
	reader: ^nghttp3.Data_Reader
	if request.open || len(request.body) > 0 || len(request.trailers) > 0 || method == "CONNECT" {
		s.reader = {
			read_data = h3_read_data,
		}
		reader = &s.reader
	}
	if rv := nghttp3.conn_submit_request(cl.h3, id, raw_data(nva), len(nva), reader, s); rv != 0 {
		fail(cl, fmt.tprintf("nghttp3_conn_submit_request: %s", nghttp3.strerror(rv)))
		return s
	}
	if len(request.trailers) > 0 {
		tail := name_values(request.trailers)
		if rv := nghttp3.conn_submit_trailers(cl.h3, id, raw_data(tail), len(tail)); rv != 0 {
			fail(cl, fmt.tprintf("nghttp3_conn_submit_trailers: %s", nghttp3.strerror(rv)))
		}
	}
	return s
}

name_values :: proc(fields: []Field) -> []nghttp3.Nv {
	nva := make([]nghttp3.Nv, len(fields), context.temp_allocator)
	for f, i in fields {
		nva[i] = {
			name     = raw_data(f.name),
			namelen  = len(f.name),
			value    = raw_data(f.value),
			valuelen = len(f.value),
		}
	}
	return nva
}

// Queues more request body on an open stream.
send :: proc(s: ^Stream, data: []u8) {
	chunk := make([]u8, len(data), s.client.allocator)
	copy(chunk, data)
	append(&s.outgoing, chunk)
	if s.client.h3 != nil && s.reader.read_data != nil {
		nghttp3.conn_resume_stream(s.client.h3, s.id)
	}
}

// Ends the request body of an open stream.
finish :: proc(s: ^Stream) {
	s.eof = true
	if s.client.h3 != nil {
		nghttp3.conn_resume_stream(s.client.h3, s.id)
	}
}

// Resets the stream and asks the server to stop sending, both with code.
cancel :: proc(s: ^Stream, code: u64 = nghttp3.H3_REQUEST_CANCELLED) {
	ngtcp2.conn_shutdown_stream(s.client.conn, 0, s.id, code)
}

// Opens a bidirectional stream nghttp3 does not know and queues data on it as
// it is (an HTTP/3 frame sequence the suite wrote).
raw_stream :: proc(cl: ^Client, data: []u8, fin: bool) -> ^Stream {
	id: i64
	if rv := ngtcp2.conn_open_bidi_stream(cl.conn, &id, nil); rv != 0 {
		fail(cl, fmt.tprintf("ngtcp2_conn_open_bidi_stream: %s", ngtcp2.strerror(rv)))
		return nil
	}
	s := stream_new(cl, id)
	s.raw = true
	bytes := make([]u8, len(data), cl.allocator)
	copy(bytes, data)
	append(&cl.raw, Raw_Write{stream = id, data = bytes, fin = fin})
	return s
}

// A HEADERS frame whose field section uses only QPACK literals (no table).
headers_frame :: proc(fields: []Field, allocator := context.temp_allocator) -> []u8 {
	section := make([dynamic]u8, allocator)
	// Required Insert Count 0, Base 0.
	append(&section, 0, 0)
	for f in fields {
		// Literal Field Line with Literal Name, no Huffman: 001N H len(3+).
		qpack_integer(&section, 0x20, 3, len(f.name))
		append(&section, f.name)
		qpack_integer(&section, 0x00, 7, len(f.value))
		append(&section, f.value)
	}
	frame := make([dynamic]u8, allocator)
	varint(&frame, 0x01)
	varint(&frame, u64(len(section)))
	append(&frame, ..section[:])
	return frame[:]
}

qpack_integer :: proc(out: ^[dynamic]u8, flags: u8, prefix: uint, value: int) {
	limit := (1 << prefix) - 1
	if value < limit {
		append(out, flags | u8(value))
		return
	}
	append(out, flags | u8(limit))
	rest := value - limit
	for rest >= 128 {
		append(out, u8(rest % 128 + 128))
		rest /= 128
	}
	append(out, u8(rest))
}

// --- nghttp3 callbacks ---

stream_of :: proc "contextless" (data: rawptr) -> ^Stream {
	return cast(^Stream)data
}

h3_read_data :: proc "c" (
	conn: ^nghttp3.Conn,
	id: i64,
	vec: [^]nghttp3.Vec,
	veccnt: c.size_t,
	pflags: ^u32,
	conn_user_data, stream_user_data: rawptr,
) -> nghttp3.Ssize {
	s := stream_of(stream_user_data)
	n := 0
	for s.submitted < len(s.outgoing) && n < int(veccnt) {
		chunk := s.outgoing[s.submitted]
		vec[n] = {raw_data(chunk), len(chunk)}
		s.submitted += 1
		n += 1
	}
	if s.submitted == len(s.outgoing) && s.eof {
		pflags^ |= nghttp3.DATA_FLAG_EOF
		return n
	}
	if n == 0 {
		return nghttp3.ERR_WOULDBLOCK
	}
	return n
}

h3_recv_header :: proc "c" (
	conn: ^nghttp3.Conn,
	id: i64,
	token: i32,
	name, value: ^nghttp3.Rcbuf,
	flags: u8,
	conn_user_data, stream_user_data: rawptr,
) -> c.int {
	s := stream_of(stream_user_data)
	if s == nil {
		return 0
	}
	context = runtime.default_context()
	n := nghttp3.rcbuf_get_buf(name)
	v := nghttp3.rcbuf_get_buf(value)
	f := Field {
		strings.clone(string(n.base[:n.len]), s.client.allocator),
		strings.clone(string(v.base[:v.len]), s.client.allocator),
	}
	if s.sections > 0 {
		append(&s.trailers, f)
	} else {
		append(&s.headers, f)
	}
	return 0
}

h3_begin_trailers :: proc "c" (
	conn: ^nghttp3.Conn,
	id: i64,
	conn_user_data, stream_user_data: rawptr,
) -> c.int {
	if s := stream_of(stream_user_data); s != nil {
		s.sections += 1
	}
	return 0
}

h3_recv_data :: proc "c" (
	conn: ^nghttp3.Conn,
	id: i64,
	data: [^]u8,
	datalen: c.size_t,
	conn_user_data, stream_user_data: rawptr,
) -> c.int {
	cl := cast(^Client)conn_user_data
	context = runtime.default_context()
	if s := stream_of(stream_user_data); s != nil {
		append(&s.body, ..data[:datalen])
	}
	consume(cl, id, u64(datalen))
	return 0
}

h3_deferred_consume :: proc "c" (
	conn: ^nghttp3.Conn,
	id: i64,
	consumed: c.size_t,
	conn_user_data, stream_user_data: rawptr,
) -> c.int {
	cl := cast(^Client)conn_user_data
	context = runtime.default_context()
	consume(cl, id, u64(consumed))
	return 0
}

h3_end_stream :: proc "c" (
	conn: ^nghttp3.Conn,
	id: i64,
	conn_user_data, stream_user_data: rawptr,
) -> c.int {
	if s := stream_of(stream_user_data); s != nil {
		s.ended = true
	}
	return 0
}

h3_stream_close :: proc "c" (
	conn: ^nghttp3.Conn,
	id: i64,
	code: u64,
	conn_user_data, stream_user_data: rawptr,
) -> c.int {
	if s := stream_of(stream_user_data); s != nil {
		s.closed = true
	}
	return 0
}

h3_stop_sending :: proc "c" (
	conn: ^nghttp3.Conn,
	id: i64,
	code: u64,
	conn_user_data, stream_user_data: rawptr,
) -> c.int {
	cl := cast(^Client)conn_user_data
	ngtcp2.conn_shutdown_stream_read(cl.conn, 0, id, code)
	return 0
}

h3_reset_stream :: proc "c" (
	conn: ^nghttp3.Conn,
	id: i64,
	code: u64,
	conn_user_data, stream_user_data: rawptr,
) -> c.int {
	cl := cast(^Client)conn_user_data
	ngtcp2.conn_shutdown_stream_write(cl.conn, 0, id, code)
	return 0
}

h3_shutdown :: proc "c" (conn: ^nghttp3.Conn, id: i64, conn_user_data: rawptr) -> c.int {
	cl := cast(^Client)conn_user_data
	context = runtime.default_context()
	append(&cl.goaways, id)
	return 0
}

// The stream has its whole response, was reset, or the connection ended.
settled :: proc(s: ^Stream) -> bool {
	return s.ended || s.reset >= 0 || s.client.closed
}

// Runs until the stream settled.
await :: proc(s: ^Stream, timeout: time.Duration = 8 * time.Second) -> bool {
	return run(
		s.client,
		timeout,
		proc(cl: ^Client, data: rawptr) -> bool {return settled(cast(^Stream)data)},
		s,
	)
}

// GETs path and waits for the response.
get :: proc(cl: ^Client, path: string, timeout: time.Duration = 8 * time.Second) -> ^Stream {
	s := request(cl, {path = path})
	if s != nil {
		await(s, timeout)
	}
	return s
}
