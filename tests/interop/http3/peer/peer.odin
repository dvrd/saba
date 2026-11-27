// An HTTP/3 client over ngtcp2 and nghttp3, the independent peer of the
// tests/interop/http3 suites. It runs on the calling thread: run drives the
// connection (writes, timers, reads) until a condition holds or time is up.
// Every datagram passes through Config.send and Config.receive, so a suite can
// drop, hold, rewrite or add packets around a genuine QUIC stack; packet.odin
// builds and opens the packets such a suite crafts itself.
package saba_test_h3_peer

import nghttp3 "../../../support/c/nghttp3"
import ngtcp2 "../../../support/c/ngtcp2"
import "base:runtime"
import "core:c"
import "core:crypto"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

// Sends a datagram ngtcp2 wrote (with transmit, changed, later, or not at all).
Send_Hook :: #type proc(cl: ^Client, datagram: []u8)
// Returns the datagram ngtcp2 reads instead (the same one, a rewritten one,
// or nil to drop it).
Receive_Hook :: #type proc(cl: ^Client, datagram: []u8) -> []u8
// Called when ngtcp2's timer fires, before ngtcp2 handles it.
Expiry_Hook :: #type proc(cl: ^Client)
// Replaces the transport parameters the ClientHello carries: encoded is
// ngtcp2's own encoding; the result is copied.
Transport_Params_Hook :: #type proc(cl: ^Client, encoded: []u8) -> []u8

Config :: struct {
	port:            int,
	server_name:     string,
	// A PEM file of trusted roots. Empty skips verification.
	roots:           string,
	// The negotiated idle timeout is the smaller of this and the server's.
	idle_timeout:    time.Duration,
	// initial_max_stream_data_bidi_local: the credit each request stream
	// starts with.
	stream_window:   u64,
	// The first packet number of every packet number space.
	initial_pkt_num: u32,
	// An OpenSSL TLS 1.3 cipher suite list; empty keeps OpenSSL's.
	ciphersuites:    string,
	send:            Send_Hook,
	receive:         Receive_Hook,
	expiry:          Expiry_Hook,
	params:          Transport_Params_Hook,
	user:            rawptr,
}

Client :: struct {
	config:        Config,
	fd:            posix.FD,
	local, remote: posix.sockaddr_in,
	path:          ngtcp2.Path,
	conn:          ^ngtcp2.Conn,
	ssl_ctx:       ^ngtcp2.SSL_CTX,
	ssl:           ^ngtcp2.SSL,
	ossl:          ^ngtcp2.Crypto_Ossl_Ctx,
	conn_ref:      ngtcp2.Crypto_Conn_Ref,
	h3:            ^nghttp3.Conn,
	// The Destination Connection ID of the first Initial.
	dcid, scid:    ngtcp2.Cid,
	// The Initial cipher, kept after ngtcp2 discards the Initial space.
	initial_ctx:   ngtcp2.Crypto_Ctx,
	streams:       map[i64]^Stream,
	raw:           [dynamic]Raw_Write,
	// The stream IDs of every GOAWAY the server sent, in order.
	goaways:       [dynamic]i64,
	secrets:       Secrets,
	handshaken:    bool,
	// The connection ended: closed by either side, idle, or failed.
	closed:        bool,
	idle_closed:   bool,
	// The server's CONNECTION_CLOSE, when it sent one.
	peer_close:    Maybe(ngtcp2.Ccerr),
	failure:       string,
	datagrams_out: int,
	tp_buffer:     [dynamic]u8,
	allocator:     runtime.Allocator,
}

// The TLS secrets the keylog reports, for packets a suite builds itself.
Secrets :: struct {
	client_handshake, server_handshake: [dynamic]u8,
	client_traffic, server_traffic:     [dynamic]u8,
}

// Bytes for a stream nghttp3 does not know, written as they are.
Raw_Write :: struct {
	stream:   i64,
	data:     []u8,
	at:       int,
	fin:      bool,
	fin_sent: bool,
	blocked:  bool,
}

ALPN :: "\x02h3"

@(private)
crypto_init: struct {
	once: sync.Once,
	ok:   bool,
}

timestamp :: proc() -> ngtcp2.Tstamp {
	return ngtcp2.Tstamp(time.tick_now()._nsec)
}

// Opens a UDP socket and a QUIC connection to 127.0.0.1:config.port. Nothing
// is sent before run.
connect :: proc(cl: ^Client, config: Config, allocator := context.allocator) -> bool {
	sync.once_do(&crypto_init.once, proc() {crypto_init.ok = ngtcp2.crypto_ossl_init() == 0})
	if !crypto_init.ok {
		return fail(cl, "ngtcp2_crypto_ossl_init failed")
	}
	cl.config = config
	cl.allocator = allocator
	cl.streams = make(map[i64]^Stream, allocator)
	cl.raw = make([dynamic]Raw_Write, allocator)
	cl.goaways = make([dynamic]i64, allocator)
	cl.tp_buffer = make([dynamic]u8, allocator)
	if cl.config.server_name == "" {
		cl.config.server_name = "localhost"
	}
	if cl.config.idle_timeout == 0 {
		cl.config.idle_timeout = 30 * time.Second
	}
	if cl.config.stream_window == 0 {
		cl.config.stream_window = 1 << 20
	}

	if !open_socket(cl) {
		return false
	}
	if !open_tls(cl) {
		return false
	}

	crypto.rand_bytes(cl.dcid.data[:18])
	cl.dcid.datalen = 18
	crypto.rand_bytes(cl.scid.data[:8])
	cl.scid.datalen = 8

	callbacks := ngtcp2.Callbacks {
		client_initial           = client_initial,
		recv_crypto_data         = ngtcp2.crypto_recv_crypto_data_cb,
		handshake_completed      = handshake_completed,
		encrypt                  = ngtcp2.crypto_encrypt_cb,
		decrypt                  = ngtcp2.crypto_decrypt_cb,
		hp_mask                  = ngtcp2.crypto_hp_mask_cb,
		recv_stream_data         = recv_stream_data,
		acked_stream_data_offset = acked_stream_data_offset,
		stream_close             = stream_close,
		recv_retry               = ngtcp2.crypto_recv_retry_cb,
		rand                     = random,
		get_new_connection_id    = new_connection_id,
		update_key               = ngtcp2.crypto_update_key_cb,
		stream_reset             = stream_reset,
		extend_max_stream_data   = extend_max_stream_data,
		delete_crypto_aead_ctx   = ngtcp2.crypto_delete_crypto_aead_ctx_cb,
		delete_crypto_cipher_ctx = ngtcp2.crypto_delete_crypto_cipher_ctx_cb,
		get_path_challenge_data  = ngtcp2.crypto_get_path_challenge_data_cb,
		stream_stop_sending      = stream_stop_sending,
		version_negotiation      = ngtcp2.crypto_version_negotiation_cb,
	}
	settings: ngtcp2.Settings
	ngtcp2.settings_default_versioned(ngtcp2.SETTINGS_V1, &settings)
	settings.initial_ts = timestamp()
	settings.initial_pkt_num = cl.config.initial_pkt_num
	settings.handshake_timeout = ngtcp2.Duration(10 * time.Second)

	params: ngtcp2.Transport_Params
	ngtcp2.transport_params_default_versioned(ngtcp2.TRANSPORT_PARAMS_V1, &params)
	params.initial_max_stream_data_bidi_local = cl.config.stream_window
	params.initial_max_stream_data_bidi_remote = 1 << 20
	params.initial_max_stream_data_uni = 1 << 20
	params.initial_max_data = 16 << 20
	params.initial_max_streams_bidi = 0
	params.initial_max_streams_uni = 16
	params.max_idle_timeout = ngtcp2.Duration(cl.config.idle_timeout)
	params.active_connection_id_limit = 7

	cl.path = {
		local = {addr = cast(^posix.sockaddr)&cl.local, addrlen = size_of(cl.local)},
		remote = {addr = cast(^posix.sockaddr)&cl.remote, addrlen = size_of(cl.remote)},
	}
	rv := ngtcp2.conn_client_new_versioned(
		&cl.conn,
		&cl.dcid,
		&cl.scid,
		&cl.path,
		ngtcp2.PROTO_VER_V1,
		ngtcp2.CALLBACKS_V1,
		&callbacks,
		ngtcp2.SETTINGS_V1,
		&settings,
		ngtcp2.TRANSPORT_PARAMS_V1,
		&params,
		nil,
		cl,
	)
	if rv != 0 {
		return fail(cl, fmt.tprintf("ngtcp2_conn_client_new: %s", ngtcp2.strerror(rv)))
	}
	ngtcp2.conn_set_tls_native_handle(cl.conn, cl.ossl)
	return true
}

open_socket :: proc(cl: ^Client) -> bool {
	cl.fd = posix.socket(.INET, .DGRAM)
	if cl.fd < 0 {
		return fail(cl, "socket failed")
	}
	loopback := posix.in_addr {
		s_addr = transmute(posix.in_addr_t)u32be(0x7f000001),
	}
	cl.local = {
		sin_family = .INET,
		sin_addr   = loopback,
	}
	when ODIN_OS == .Darwin {
		cl.local.sin_len = size_of(cl.local)
	}
	if posix.bind(cl.fd, cast(^posix.sockaddr)&cl.local, size_of(cl.local)) != .OK {
		return fail(cl, "bind failed")
	}
	length := posix.socklen_t(size_of(cl.local))
	if posix.getsockname(cl.fd, cast(^posix.sockaddr)&cl.local, &length) != .OK {
		return fail(cl, "getsockname failed")
	}
	flags := posix.fcntl(cl.fd, .GETFL)
	posix.fcntl(cl.fd, .SETFL, flags | posix.O_NONBLOCK)
	cl.remote = {
		sin_family = .INET,
		sin_addr   = loopback,
		sin_port   = u16be(u16(cl.config.port)),
	}
	when ODIN_OS == .Darwin {
		cl.remote.sin_len = size_of(cl.remote)
	}
	return true
}

open_tls :: proc(cl: ^Client) -> bool {
	cl.ssl_ctx = ngtcp2.SSL_CTX_new(ngtcp2.TLS_client_method())
	if cl.ssl_ctx == nil {
		return fail(cl, "SSL_CTX_new failed")
	}
	if cl.config.roots != "" {
		roots := strings.clone_to_cstring(cl.config.roots, context.temp_allocator)
		if ngtcp2.SSL_CTX_load_verify_locations(cl.ssl_ctx, roots, nil) != 1 {
			return fail(cl, fmt.tprintf("could not load %s", cl.config.roots))
		}
		ngtcp2.SSL_CTX_set_verify(cl.ssl_ctx, ngtcp2.SSL_VERIFY_PEER, nil)
	}
	ngtcp2.SSL_CTX_set_keylog_callback(cl.ssl_ctx, keylog)
	cl.ssl = ngtcp2.SSL_new(cl.ssl_ctx)
	if cl.ssl == nil {
		return fail(cl, "SSL_new failed")
	}
	if ngtcp2.crypto_ossl_ctx_new(&cl.ossl, cl.ssl) != 0 {
		return fail(cl, "ngtcp2_crypto_ossl_ctx_new failed")
	}
	if ngtcp2.crypto_ossl_configure_client_session(cl.ssl) != 0 {
		return fail(cl, "ngtcp2_crypto_ossl_configure_client_session failed")
	}
	cl.conn_ref = {
		get_conn = proc "c" (ref: ^ngtcp2.Crypto_Conn_Ref) -> ^ngtcp2.Conn {
			return (cast(^Client)ref.user_data).conn
		},
		user_data = cl,
	}
	ngtcp2.SSL_set_app_data(cl.ssl, &cl.conn_ref)
	ngtcp2.SSL_set_connect_state(cl.ssl)
	alpn := ALPN
	ngtcp2.SSL_set_alpn_protos(cl.ssl, raw_data(alpn), c.uint(len(alpn)))
	name := strings.clone_to_cstring(cl.config.server_name, context.temp_allocator)
	ngtcp2.SSL_set_tlsext_host_name(cl.ssl, name)
	if cl.config.roots != "" {
		ngtcp2.SSL_set1_host(cl.ssl, name)
	}
	if cl.config.ciphersuites != "" {
		suites := strings.clone_to_cstring(cl.config.ciphersuites, context.temp_allocator)
		if ngtcp2.SSL_set_ciphersuites(cl.ssl, suites) != 1 {
			return fail(cl, "SSL_set_ciphersuites failed")
		}
	}
	if cl.config.params != nil {
		ngtcp2.SSL_set_info_callback(cl.ssl, tls_info)
	}
	return true
}

destroy :: proc(cl: ^Client) {
	for _, s in cl.streams {
		stream_free(s)
	}
	delete(cl.streams)
	for w in cl.raw {
		delete(w.data, cl.allocator)
	}
	delete(cl.raw)
	delete(cl.goaways)
	delete(cl.tp_buffer)
	delete(cl.failure, cl.allocator)
	for secret in ([]^[dynamic]u8 {
			&cl.secrets.client_handshake,
			&cl.secrets.server_handshake,
			&cl.secrets.client_traffic,
			&cl.secrets.server_traffic,
		}) {
		delete(secret^)
	}
	if cl.h3 != nil {
		nghttp3.conn_del(cl.h3)
	}
	if cl.conn != nil {
		ngtcp2.conn_del(cl.conn)
	}
	if cl.ossl != nil {
		ngtcp2.crypto_ossl_ctx_del(cl.ossl)
	}
	if cl.ssl != nil {
		ngtcp2.SSL_free(cl.ssl)
	}
	if cl.ssl_ctx != nil {
		ngtcp2.SSL_CTX_free(cl.ssl_ctx)
	}
	if cl.fd > 0 {
		posix.close(cl.fd)
	}
	cl^ = {}
}

fail :: proc(cl: ^Client, reason: string) -> bool {
	if cl.failure == "" {
		if cl.allocator.procedure == nil {
			cl.allocator = context.allocator
		}
		cl.failure = strings.clone(reason, cl.allocator)
	}
	cl.closed = true
	return false
}

// Drives the connection until done returns true (true) or timeout passes
// (false). A nil done runs for the whole timeout and returns true.
run :: proc(
	cl: ^Client,
	timeout: time.Duration,
	done: proc(cl: ^Client, data: rawptr) -> bool = nil,
	data: rawptr = nil,
) -> bool {
	deadline := time.tick_add(time.tick_now(), timeout)
	for {
		if done != nil && done(cl, data) {
			return true
		}
		remaining := time.tick_diff(time.tick_now(), deadline)
		if remaining <= 0 {
			return done == nil
		}
		step(cl, remaining)
	}
}

// One round: write what is pending, wait for a datagram or the next timer
// (at most limit), read, and handle an expired timer.
step :: proc(cl: ^Client, limit: time.Duration) {
	if !cl.closed {
		if cl.h3 != nil {
			close_pending(cl)
		}
		flush(cl)
	}
	wait := limit
	if !cl.closed {
		expiry := ngtcp2.conn_get_expiry2(cl.conn)
		now := timestamp()
		until := time.Duration(expiry - now) if expiry > now else 0
		wait = min(wait, until)
	}
	wait = min(wait, 100 * time.Millisecond)
	descriptor := posix.pollfd {
		fd     = cl.fd,
		events = {.IN},
	}
	milliseconds := c.int((wait + time.Millisecond - 1) / time.Millisecond)
	if posix.poll(&descriptor, 1, milliseconds) > 0 {
		receive(cl)
	}
	if !cl.closed && timestamp() >= ngtcp2.conn_get_expiry2(cl.conn) {
		if cl.config.expiry != nil {
			cl.config.expiry(cl)
		}
		rv := ngtcp2.conn_handle_expiry(cl.conn, timestamp())
		if rv == ngtcp2.ERR_IDLE_CLOSE {
			cl.idle_closed = true
			cl.closed = true
		} else if rv != 0 {
			fail(cl, fmt.tprintf("ngtcp2_conn_handle_expiry: %s", ngtcp2.strerror(rv)))
		}
	}
}

receive :: proc(cl: ^Client) {
	buffer: [65536]u8
	for {
		from: posix.sockaddr_in
		length := posix.socklen_t(size_of(from))
		n := posix.recvfrom(
			cl.fd,
			raw_data(buffer[:]),
			len(buffer),
			{},
			cast(^posix.sockaddr)&from,
			&length,
		)
		if n <= 0 {
			return
		}
		datagram := buffer[:n]
		if cl.config.receive != nil {
			datagram = cl.config.receive(cl, datagram)
			if datagram == nil {
				continue
			}
		}
		if cl.closed {
			continue
		}
		info: ngtcp2.Pkt_Info
		rv := ngtcp2.conn_read_pkt_versioned(
			cl.conn,
			&cl.path,
			ngtcp2.PKT_INFO_V1,
			&info,
			raw_data(datagram),
			len(datagram),
			timestamp(),
		)
		switch rv {
		case 0:
		case ngtcp2.ERR_DRAINING, ngtcp2.ERR_CLOSING:
			ended(cl)
		case:
			fail(cl, fmt.tprintf("ngtcp2_conn_read_pkt: %s", ngtcp2.strerror(rv)))
		}
		if !cl.closed && ngtcp2.conn_in_draining_period2(cl.conn) != 0 {
			ended(cl)
		}
	}
}

// ngtcp2 closed the connection: in draining, the server's CONNECTION_CLOSE
// is what it received.
ended :: proc(cl: ^Client) {
	if ngtcp2.conn_in_draining_period2(cl.conn) != 0 {
		cl.peer_close = ngtcp2.conn_get_ccerr2(cl.conn)^
	}
	cl.closed = true
}

// Writes every packet ngtcp2 and nghttp3 have ready.
flush :: proc(cl: ^Client) {
	buffer: [ngtcp2.MAX_UDP_PAYLOAD_SIZE]u8
	info: ngtcp2.Pkt_Info
	for !cl.closed {
		id := i64(-1)
		fin: c.int
		vectors: [16]nghttp3.Vec
		count := 0
		raw_index := -1
		if cl.h3 != nil {
			n := nghttp3.conn_writev_stream(cl.h3, &id, &fin, &vectors[0], len(vectors))
			if n < 0 {
				fail(cl, fmt.tprintf("nghttp3_conn_writev_stream: %s", nghttp3.strerror(c.int(n))))
				return
			}
			count = n
		}
		if id < 0 {
			for w, i in cl.raw {
				if !w.blocked && (w.at < len(w.data) || w.fin && !w.fin_sent) {
					raw_index = i
					id = w.stream
					vectors[0] = {raw_data(w.data[w.at:]), c.size_t(len(w.data)) - c.size_t(w.at)}
					count = 1
					fin = 1 if w.fin else 0
					break
				}
			}
		}
		flags := ngtcp2.WRITE_STREAM_FLAG_MORE
		if fin != 0 {
			flags |= ngtcp2.WRITE_STREAM_FLAG_FIN
		}
		accepted: ngtcp2.Ssize = -1
		written := ngtcp2.conn_writev_stream_versioned(
			cl.conn,
			&cl.path,
			ngtcp2.PKT_INFO_V1,
			&info,
			raw_data(buffer[:]),
			len(buffer),
			&accepted,
			flags,
			id,
			cast([^]ngtcp2.Vec)&vectors[0],
			c.size_t(count),
			timestamp(),
		)
		if accepted >= 0 {
			if raw_index >= 0 {
				w := &cl.raw[raw_index]
				w.at += accepted
				w.fin_sent ||= w.at == len(w.data) && w.fin
			} else if id >= 0 && cl.h3 != nil {
				nghttp3.conn_add_write_offset(cl.h3, id, c.size_t(accepted))
			}
		}
		if written < 0 {
			switch written {
			case ngtcp2.ERR_WRITE_MORE:
				continue
			case ngtcp2.ERR_STREAM_DATA_BLOCKED:
				if raw_index >= 0 {
					cl.raw[raw_index].blocked = true
					continue
				}
				nghttp3.conn_block_stream(cl.h3, id)
				continue
			case ngtcp2.ERR_STREAM_SHUT_WR, ngtcp2.ERR_STREAM_NOT_FOUND:
				if raw_index >= 0 {
					delete(cl.raw[raw_index].data, cl.allocator)
					ordered_remove(&cl.raw, raw_index)
					continue
				}
				nghttp3.conn_shutdown_stream_write(cl.h3, id)
				continue
			case ngtcp2.ERR_CLOSING, ngtcp2.ERR_DRAINING:
				ended(cl)
				return
			}
			fail(cl, fmt.tprintf("ngtcp2_conn_writev_stream: %s", ngtcp2.strerror(c.int(written))))
			return
		}
		if written == 0 {
			return
		}
		datagram := buffer[:written]
		if cl.config.send != nil {
			cl.config.send(cl, datagram)
		} else {
			transmit(cl, datagram)
		}
	}
}

// Sends datagram to the server as it is.
transmit :: proc(cl: ^Client, datagram: []u8) {
	cl.datagrams_out += 1
	posix.sendto(
		cl.fd,
		raw_data(datagram),
		len(datagram),
		{},
		cast(^posix.sockaddr)&cl.remote,
		size_of(cl.remote),
	)
}

// Closes the connection with an HTTP/3 application error and sends the
// CONNECTION_CLOSE.
close :: proc(cl: ^Client, code: u64 = nghttp3.H3_NO_ERROR) {
	if cl.closed {
		return
	}
	error: ngtcp2.Ccerr
	ngtcp2.ccerr_default(&error)
	ngtcp2.ccerr_set_application_error(&error, code, nil, 0)
	buffer: [ngtcp2.MAX_UDP_PAYLOAD_SIZE]u8
	info: ngtcp2.Pkt_Info
	n := ngtcp2.conn_write_connection_close_versioned(
		cl.conn,
		&cl.path,
		ngtcp2.PKT_INFO_V1,
		&info,
		raw_data(buffer[:]),
		len(buffer),
		&error,
		timestamp(),
	)
	if n > 0 {
		datagram := buffer[:n]
		if cl.config.send != nil {
			cl.config.send(cl, datagram)
		} else {
			transmit(cl, datagram)
		}
	}
	cl.closed = true
}

handshake :: proc(cl: ^Client, timeout: time.Duration = 5 * time.Second) -> bool {
	return(
		run(
			cl,
			timeout,
			proc(cl: ^Client, _: rawptr) -> bool {return cl.handshaken || cl.closed},
		) &&
		cl.handshaken \
	)
}

// What went wrong, for failure messages.
describe :: proc(cl: ^Client) -> string {
	state := "the connection is open"
	if close, ok := cl.peer_close.?; ok {
		state = fmt.tprintf(
			"the server closed the connection: %v 0x%x",
			close.type,
			close.error_code,
		)
	} else if cl.idle_closed {
		state = "the connection timed out (idle)"
	} else if cl.closed {
		state = "the connection is closed"
	}
	if cl.failure != "" {
		return fmt.tprintf("%s (%s)", cl.failure, state)
	}
	return state
}

// --- ngtcp2 callbacks ---

client_initial :: proc "c" (conn: ^ngtcp2.Conn, user_data: rawptr) -> c.int {
	cl := cast(^Client)user_data
	if rv := ngtcp2.crypto_client_initial_cb(conn, user_data); rv != 0 {
		return rv
	}
	cl.initial_ctx = ngtcp2.conn_get_initial_crypto_ctx2(conn)^
	return 0
}

// Before OpenSSL writes the ClientHello, the transport parameters hook may
// replace what ngtcp2 configured.
tls_info :: proc "c" (ssl: ^ngtcp2.SSL, type: c.int, value: c.int) {
	if type & ngtcp2.SSL_CB_HANDSHAKE_START == 0 {
		return
	}
	ref := cast(^ngtcp2.Crypto_Conn_Ref)ngtcp2.SSL_get_app_data(ssl)
	cl := cast(^Client)ref.user_data
	context = runtime.default_context()
	encoded: [1024]u8
	n := ngtcp2.conn_encode_local_transport_params2(cl.conn, raw_data(encoded[:]), len(encoded))
	if n < 0 {
		return
	}
	params := cl.config.params(cl, encoded[:n])
	clear(&cl.tp_buffer)
	append(&cl.tp_buffer, ..params)
	ngtcp2.SSL_set_quic_tls_transport_params(ssl, raw_data(cl.tp_buffer[:]), len(cl.tp_buffer))
}

keylog :: proc "c" (ssl: ^ngtcp2.SSL, line: cstring) {
	ref := cast(^ngtcp2.Crypto_Conn_Ref)ngtcp2.SSL_get_app_data(ssl)
	cl := cast(^Client)ref.user_data
	context = runtime.default_context()
	text := string(line)
	fields := strings.fields(text, context.temp_allocator)
	if len(fields) != 3 {
		return
	}
	target: ^[dynamic]u8
	switch fields[0] {
	case "CLIENT_HANDSHAKE_TRAFFIC_SECRET":
		target = &cl.secrets.client_handshake
	case "SERVER_HANDSHAKE_TRAFFIC_SECRET":
		target = &cl.secrets.server_handshake
	case "CLIENT_TRAFFIC_SECRET_0":
		target = &cl.secrets.client_traffic
	case "SERVER_TRAFFIC_SECRET_0":
		target = &cl.secrets.server_traffic
	case:
		return
	}
	target.allocator = cl.allocator
	clear(target)
	hex := fields[2]
	for i := 0; i + 1 < len(hex); i += 2 {
		append(target, nibble(hex[i]) << 4 | nibble(hex[i + 1]))
	}
}

nibble :: proc "contextless" (b: u8) -> u8 {
	switch b {
	case '0' ..= '9':
		return b - '0'
	case 'a' ..= 'f':
		return b - 'a' + 10
	case 'A' ..= 'F':
		return b - 'A' + 10
	}
	return 0
}

handshake_completed :: proc "c" (conn: ^ngtcp2.Conn, user_data: rawptr) -> c.int {
	cl := cast(^Client)user_data
	context = runtime.default_context()
	cl.handshaken = true
	return 0 if open_http3(cl) else ngtcp2.ERR_CALLBACK_FAILURE
}

random :: proc "c" (dest: [^]u8, destlen: c.size_t, _: ^ngtcp2.Rand_Ctx) {
	context = runtime.default_context()
	crypto.rand_bytes(dest[:destlen])
}

new_connection_id :: proc "c" (
	conn: ^ngtcp2.Conn,
	cid: ^ngtcp2.Cid,
	token: [^]u8,
	cidlen: c.size_t,
	user_data: rawptr,
) -> c.int {
	context = runtime.default_context()
	crypto.rand_bytes(cid.data[:cidlen])
	cid.datalen = cidlen
	crypto.rand_bytes(token[:ngtcp2.STATELESS_RESET_TOKENLEN])
	return 0
}

recv_stream_data :: proc "c" (
	conn: ^ngtcp2.Conn,
	flags: u32,
	id: i64,
	offset: u64,
	data: [^]u8,
	datalen: c.size_t,
	user_data, stream_user_data: rawptr,
) -> c.int {
	cl := cast(^Client)user_data
	context = runtime.default_context()
	fin := flags & ngtcp2.STREAM_DATA_FLAG_FIN != 0
	s := cl.streams[id]
	if s != nil {
		s.received = max(s.received, offset + u64(datalen))
		if len(s.chunks) < 16 {
			append(&s.chunks, int(datalen))
		}
	}
	if s != nil && s.raw {
		append(&s.body, ..data[:datalen])
		s.ended ||= fin
		consume(cl, id, u64(datalen))
		return 0
	}
	if cl.h3 == nil {
		return 0
	}
	n := nghttp3.conn_read_stream(cl.h3, id, data, datalen, 1 if fin else 0)
	if n < 0 {
		fail(cl, fmt.tprintf("nghttp3_conn_read_stream: %s", nghttp3.strerror(c.int(n))))
		return ngtcp2.ERR_CALLBACK_FAILURE
	}
	consume(cl, id, u64(n))
	return 0
}

// Gives the server back credit for n bytes of stream id, unless the suite
// withholds it on that stream.
consume :: proc(cl: ^Client, id: i64, n: u64) {
	if n == 0 {
		return
	}
	if s := cl.streams[id]; s != nil && s.withhold {
		s.withheld += n
	} else {
		ngtcp2.conn_extend_max_stream_offset(cl.conn, id, n)
	}
	ngtcp2.conn_extend_max_offset(cl.conn, n)
}

acked_stream_data_offset :: proc "c" (
	conn: ^ngtcp2.Conn,
	id: i64,
	offset, datalen: u64,
	user_data, stream_user_data: rawptr,
) -> c.int {
	cl := cast(^Client)user_data
	if cl.h3 != nil && !is_raw(cl, id) {
		if nghttp3.conn_add_ack_offset(cl.h3, id, datalen) != 0 {
			return ngtcp2.ERR_CALLBACK_FAILURE
		}
	}
	return 0
}

is_raw :: proc "contextless" (cl: ^Client, id: i64) -> bool {
	context = runtime.default_context()
	s := cl.streams[id]
	return s != nil && s.raw
}

stream_close :: proc "c" (
	conn: ^ngtcp2.Conn,
	flags: u32,
	id: i64,
	code: u64,
	user_data, stream_user_data: rawptr,
) -> c.int {
	cl := cast(^Client)user_data
	context = runtime.default_context()
	s := cl.streams[id]
	if s != nil {
		s.closed = true
	}
	if cl.h3 == nil || s != nil && s.raw {
		return 0
	}
	error :=
		code if flags & ngtcp2.STREAM_CLOSE_FLAG_APP_ERROR_CODE_SET != 0 else nghttp3.H3_NO_ERROR
	if s != nil && !s.ended && s.reset < 0 {
		// Every byte arrived, but nghttp3 may still hold the response back
		// for QPACK encoder instructions on another stream: it is closed
		// once nghttp3 delivered the end of the response.
		s.close_pending = true
		s.close_code = error
		return 0
	}
	return 0 if close_stream(cl, id, error) else ngtcp2.ERR_CALLBACK_FAILURE
}

close_stream :: proc(cl: ^Client, id: i64, code: u64) -> bool {
	rv := nghttp3.conn_close_stream(cl.h3, id, code)
	return rv == 0 || rv == nghttp3.ERR_STREAM_NOT_FOUND
}

// Closes in nghttp3 the streams whose response it has now delivered.
close_pending :: proc(cl: ^Client) {
	for id, s in cl.streams {
		if s.close_pending && (s.ended || s.reset >= 0) {
			s.close_pending = false
			if !close_stream(cl, id, s.close_code) {
				fail(cl, "nghttp3_conn_close_stream failed")
			}
		}
	}
}

stream_reset :: proc "c" (
	conn: ^ngtcp2.Conn,
	id: i64,
	final_size, code: u64,
	user_data, stream_user_data: rawptr,
) -> c.int {
	cl := cast(^Client)user_data
	context = runtime.default_context()
	if s := cl.streams[id]; s != nil && s.reset < 0 {
		s.reset = i64(code)
	}
	if cl.h3 != nil && !is_raw(cl, id) {
		nghttp3.conn_shutdown_stream_read(cl.h3, id)
	}
	return 0
}

stream_stop_sending :: proc "c" (
	conn: ^ngtcp2.Conn,
	id: i64,
	code: u64,
	user_data, stream_user_data: rawptr,
) -> c.int {
	cl := cast(^Client)user_data
	context = runtime.default_context()
	if s := cl.streams[id]; s != nil && s.stopped < 0 {
		s.stopped = i64(code)
	}
	if cl.h3 != nil && !is_raw(cl, id) {
		nghttp3.conn_shutdown_stream_read(cl.h3, id)
	}
	return 0
}

extend_max_stream_data :: proc "c" (
	conn: ^ngtcp2.Conn,
	id: i64,
	max_data: u64,
	user_data, stream_user_data: rawptr,
) -> c.int {
	cl := cast(^Client)user_data
	context = runtime.default_context()
	for &w in cl.raw {
		if w.stream == id {
			w.blocked = false
		}
	}
	if cl.h3 != nil && !is_raw(cl, id) {
		nghttp3.conn_unblock_stream(cl.h3, id)
	}
	return 0
}

// Sends one datagram from a fresh socket to 127.0.0.1:port and returns the
// first datagram that comes back within timeout, with the port it came from.
exchange :: proc(
	port: int,
	datagram: []u8,
	timeout: time.Duration,
	allocator := context.temp_allocator,
) -> (
	reply: []u8,
	from: int,
	ok: bool,
) {
	fd := posix.socket(.INET, .DGRAM)
	if fd < 0 {
		return
	}
	defer posix.close(fd)
	loopback := posix.in_addr {
		s_addr = transmute(posix.in_addr_t)u32be(0x7f000001),
	}
	server := posix.sockaddr_in {
		sin_family = .INET,
		sin_addr   = loopback,
		sin_port   = u16be(u16(port)),
	}
	when ODIN_OS == .Darwin {
		server.sin_len = size_of(server)
	}
	if posix.sendto(
		   fd,
		   raw_data(datagram),
		   len(datagram),
		   {},
		   cast(^posix.sockaddr)&server,
		   size_of(server),
	   ) !=
	   len(datagram) {
		return
	}
	descriptor := posix.pollfd {
		fd     = fd,
		events = {.IN},
	}
	if posix.poll(&descriptor, 1, c.int(timeout / time.Millisecond)) <= 0 {
		return
	}
	buffer: [65536]u8
	source: posix.sockaddr_in
	length := posix.socklen_t(size_of(source))
	n := posix.recvfrom(
		fd,
		raw_data(buffer[:]),
		len(buffer),
		{},
		cast(^posix.sockaddr)&source,
		&length,
	)
	if n <= 0 {
		return
	}
	reply = make([]u8, n, allocator)
	copy(reply, buffer[:n])
	return reply, int(u16(source.sin_port)), true
}
