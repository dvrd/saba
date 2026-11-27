// Saba's HTTP/3 server against faults in the Initial and Handshake packet
// number spaces. The client is ngtcp2; around it, the suite seals packets of
// its own with the client's genuine keys (Initial keys from the first
// Destination Connection ID, Handshake keys from the TLS secrets) and sends
// them next to, or instead of, what ngtcp2 wrote. ngtcp2 starts every packet
// number space at 1, so the crafted packet takes number 0 and never collides
// with a genuine one, and an acknowledgement of it is one ngtcp2 ignores.
//
// A malformed or forbidden payload makes Saba close the connection with the
// QUIC error code the case names, before the client's Finished. The others
// must not hurt the handshake: a forged tag, an Initial from a foreign
// source connection ID, non-ack-eliciting packets (which Saba must not
// acknowledge on their own) and a CRYPTO stream split into 33 one-byte gaps.
// After every case a fresh connection is served by the same one-slot server.
package handshake_test

import ngtcp2 "../../../support/c/ngtcp2"
import peer "../peer"
import "core:fmt"
import "core:testing"
import "core:time"

PROBE :: "tests/fixtures/apps/http3_probe"
// The packet number every crafted packet uses: below ngtcp2's first.
CRAFTED_PN :: 0

PROTOCOL_VIOLATION :: 0x0a
FRAME_ENCODING_ERROR :: 0x07
CRYPTO_BUFFER_EXCEEDED :: 0x0d

Case :: enum {
	Empty,
	Nonminimal,
	Appclose,
	Ack_Unsent,
	Ack_Malformed,
	Crypto_Truncated,
	Crypto_Overflow,
	Crypto_Resource,
	Close_Truncated,
	Close_Valid,
	Bad_Tag,
	Invalid_Initial,
	Padding_Only,
	Ack_Only,
	Sparse_Crypto,
}

// The connection survives these.
POSITIVE :: bit_set[Case]{.Bad_Tag, .Invalid_Initial, .Padding_Only, .Ack_Only, .Sparse_Crypto}
// Non-ack-eliciting packets: the genuine flight is held back until ngtcp2's
// loss timer fires, so any acknowledgement in that window would be one of
// the crafted packet alone.
CONTROLS :: bit_set[Case]{.Padding_Only, .Ack_Only}

// The Handshake payload of each fault and the error code Saba closes with
// (0 for Close_Valid: Saba closes nothing, the client's idle timer ends it).
fault :: proc(c: Case) -> (payload: []u8, code: u64) {
	out := make([dynamic]u8, context.temp_allocator)
	switch c {
	case .Empty:
		code = PROTOCOL_VIOLATION
	case .Nonminimal:
		// PING with a two-byte frame type.
		append(&out, 0x40, 0x01)
		code = FRAME_ENCODING_ERROR
	case .Appclose:
		// CONNECTION_CLOSE of the application kind is not allowed here.
		append(&out, 0x1d, 0x00, 0x00)
		code = PROTOCOL_VIOLATION
	case .Ack_Unsent:
		append(&out, 0x02)
		peer.varint(&out, 1 << 30)
		append(&out, 0x00, 0x00, 0x00)
		code = PROTOCOL_VIOLATION
	case .Ack_Malformed:
		append(&out, 0x02, 0x00)
		code = FRAME_ENCODING_ERROR
	case .Crypto_Truncated:
		append(&out, 0x06, 0x00, 0x05, 'x')
		code = FRAME_ENCODING_ERROR
	case .Crypto_Overflow:
		append(&out, 0x06)
		peer.varint(&out, (1 << 62) - 1)
		append(&out, 0x01, 'x')
		code = FRAME_ENCODING_ERROR
	case .Crypto_Resource:
		append(&out, 0x06)
		peer.varint(&out, 70000)
		append(&out, 0x01, 'x')
		code = CRYPTO_BUFFER_EXCEEDED
	case .Close_Truncated:
		append(&out, 0x1c, 0x00, 0x00, 0x03, 'x')
		code = FRAME_ENCODING_ERROR
	case .Close_Valid:
		// A CRYPTO byte, then a well-formed CONNECTION_CLOSE (NO_ERROR) and
		// a stray byte after it: Saba must enter draining and stay silent.
		append(&out, 0x06, 0x00, 0x01, 0xff, 0x1c, 0x00, 0x00, 0x00, 0x06)
	case .Bad_Tag:
		append(&out, 0x01)
	case .Invalid_Initial:
		append(&out, 0x40, 0x01)
	case .Padding_Only:
		append(&out, 0x00, 0x00, 0x00, 0x00)
	case .Ack_Only:
		append(&out, 0x02, 0x00, 0x00, 0x00, 0x00)
	case .Sparse_Crypto:
	}
	return out[:], code
}

Injector :: struct {
	fault:          Case,
	injected:       bool,
	injected_at:    time.Tick,
	bytes:          int,
	types:          [dynamic]peer.Packet_Type,
	held:           [dynamic][]u8,
	released:       bool,
	released_after: time.Duration,
	pto:            time.Duration,
	// The packet number space whose acknowledgements are watched.
	watched:        Maybe(peer.Packet_Type),
	// The server's keys, to open its packets and seal them again.
	initial:        Space,
	handshake:      Space,
	observed_acks:  int,
	sparse_acked:   bool,
	unexpected:     u64,
	failure:        string,
}

Space :: struct {
	open, seal: peer.Keys,
}

injector_destroy :: proc(st: ^Injector) {
	for space in ([]^Space{&st.initial, &st.handshake}) {
		peer.keys_destroy(&space.open)
		peer.keys_destroy(&space.seal)
	}
	delete(st.types)
	for datagram in st.held {
		delete(datagram)
	}
	delete(st.held)
}

positive :: proc(c: Case) -> bool {
	return c in POSITIVE
}

send :: proc(cl: ^peer.Client, data: []u8) {
	st := cast(^Injector)cl.config.user
	if st.injected {
		if len(st.held) > 0 && !st.released {
			if len(st.held) >= 8 {
				st.failure = "more than eight datagrams were held"
				return
			}
			append(&st.held, clone(data))
			return
		}
		if positive(st.fault) {
			peer.transmit(cl, data)
		}
		return
	}
	initial_fault := st.fault == .Invalid_Initial || st.fault == .Sparse_Crypto
	if !initial_fault && len(cl.secrets.client_handshake) == 0 {
		peer.transmit(cl, data)
		return
	}
	items := peer.packets(data, 0)
	genuine: Maybe(peer.Packet)
	for p in items {
		if p.type == .Initial && initial_fault || p.type == .Handshake && !initial_fault {
			genuine = p
			break
		}
	}
	template, found := genuine.?
	if !found {
		peer.transmit(cl, data)
		return
	}
	payload, _ := fault(st.fault)
	combined := make([dynamic]u8, context.temp_allocator)
	switch st.fault {
	case .Sparse_Crypto:
		keys, ok := peer.initial_keys(cl, false, false)
		defer peer.keys_destroy(&keys)
		_, plain, opened := peer.open(&keys, template)
		hello: []u8
		if frames, parsed := peer.frames(plain); ok && opened && parsed {
			for f in frames {
				if f.kind == .Crypto && f.offset == 0 {
					hello = f.data
				}
			}
		}
		if len(hello) < 66 {
			st.failure = fmt.tprintf("the ClientHello is %d bytes", len(hello))
			peer.transmit(cl, data)
			return
		}
		// Genuine TLS bytes, separated before the real flight fills the
		// gaps: 33 one-byte CRYPTO frames at offsets 1, 3, ..., 65.
		sparse := make([dynamic]u8, context.temp_allocator)
		for offset := 1; offset < 66; offset += 2 {
			append(&sparse, 0x06)
			peer.varint(&sparse, u64(offset))
			append(&sparse, 0x01, hello[offset])
		}
		payload = sparse[:]
		append(&combined, ..seal(cl, .Initial, template.dcid, template.scid, payload))
		append(&combined, ..data)
		st.watched = .Initial
	case .Padding_Only, .Ack_Only:
		append(&combined, ..seal(cl, .Handshake, template.dcid, template.scid, payload))
		append(&st.held, clone(data))
		st.watched = .Handshake
	case .Invalid_Initial:
		append(
			&combined,
			..seal(cl, .Initial, template.dcid, transmute([]u8)string("badcid!!"), payload),
		)
		append(&combined, ..data)
	case .Bad_Tag:
		bad := seal(cl, .Handshake, template.dcid, template.scid, payload)
		bad[len(bad) - 1] ~= 1
		append(&combined, ..bad)
		append(&combined, ..data)
	case .Empty,
	     .Nonminimal,
	     .Appclose,
	     .Ack_Unsent,
	     .Ack_Malformed,
	     .Crypto_Truncated,
	     .Crypto_Overflow,
	     .Crypto_Resource,
	     .Close_Truncated,
	     .Close_Valid:
		// The fault replaces the client's flight: nothing genuine follows.
		append(&combined, ..seal(cl, .Handshake, template.dcid, template.scid, payload))
	}
	if len(combined) > 4096 {
		st.failure = fmt.tprintf("the crafted datagram is %d bytes", len(combined))
	}
	st.injected = true
	st.injected_at = time.tick_now()
	st.bytes = len(combined)
	for p in peer.packets(combined[:], 0) {
		append(&st.types, p.type)
	}
	peer.transmit(cl, combined[:])
}

seal :: proc(cl: ^peer.Client, type: peer.Packet_Type, dcid, scid: []u8, payload: []u8) -> []u8 {
	keys: peer.Keys
	ok: bool
	if type == .Initial {
		keys, ok = peer.initial_keys(cl, false, true)
	} else {
		keys, ok = peer.handshake_keys(cl, false, true)
	}
	defer peer.keys_destroy(&keys)
	if !ok {
		return nil
	}
	return peer.protect(&keys, type, dcid, scid, CRAFTED_PN, payload)
}

clone :: proc(data: []u8) -> []u8 {
	out := make([]u8, len(data))
	copy(out, data)
	return out
}

// The server's keys for a packet number space, once they exist.
server_space :: proc(cl: ^peer.Client, st: ^Injector, type: peer.Packet_Type) -> ^Space {
	space := &st.initial if type == .Initial else &st.handshake
	if !space.open.valid {
		if type == .Initial {
			space.open, _ = peer.initial_keys(cl, true, false)
			space.seal, _ = peer.initial_keys(cl, true, true)
		} else {
			space.open, _ = peer.handshake_keys(cl, true, false)
			space.seal, _ = peer.handshake_keys(cl, true, true)
		}
	}
	return space if space.open.valid && space.seal.valid else nil
}

// Watches the server's packets of the watched space for acknowledgements,
// and takes the crafted packet out of every acknowledgement before ngtcp2
// reads it: ngtcp2 never sent that packet number and drops a packet that
// acknowledges it.
receive :: proc(cl: ^peer.Client, data: []u8) -> []u8 {
	st := cast(^Injector)cl.config.user
	if !st.injected {
		return data
	}
	watched, watching := st.watched.?
	out := make([dynamic]u8, context.temp_allocator)
	changed := false
	for p in peer.packets(data, 0) {
		space: ^Space
		if p.type == .Initial || p.type == .Handshake {
			space = server_space(cl, st, p.type)
		}
		if space == nil {
			append(&out, ..p.bytes)
			continue
		}
		pn, plain, opened := peer.open(&space.open, p)
		if !opened {
			append(&out, ..p.bytes)
			continue
		}
		if watching && p.type == watched && !st.released {
			frames, ok := peer.frames(plain)
			for f in frames {
				#partial switch f.kind {
				case .Ack:
					st.observed_acks += 1
					st.sparse_acked ||= peer.acknowledges(f, CRAFTED_PN)
				case .Other:
					st.unexpected = f.type
				}
			}
			if !ok && st.unexpected == 0 {
				st.failure = "the server sent a malformed frame"
			}
		}
		stripped, acknowledged := peer.unacknowledge(plain, CRAFTED_PN)
		if !acknowledged {
			append(&out, ..p.bytes)
			continue
		}
		changed = true
		append(&out, ..peer.protect(&space.seal, p.type, p.dcid, p.scid, pn, stripped))
	}
	return out[:] if changed else data
}

// ngtcp2's loss timer fired: the held flight goes out, and ngtcp2 probes.
expiry :: proc(cl: ^peer.Client) {
	st := cast(^Injector)cl.config.user
	if len(st.held) == 0 || st.released {
		return
	}
	st.released = true
	st.released_after = time.tick_since(st.injected_at)
	// The Handshake space probe timeout leaves out max_ack_delay (RFC 9002
	// section 6.2.1); ngtcp2 reports the application one.
	st.pto = time.Duration(ngtcp2.conn_get_pto2(cl.conn))
	if remote := ngtcp2.conn_get_remote_transport_params2(cl.conn); remote != nil {
		st.pto -= time.Duration(remote.max_ack_delay)
	}
	for datagram in st.held {
		peer.transmit(cl, datagram)
	}
}

exercise :: proc(t: ^testing.T, c: Case) {
	testing.set_fail_timeout(t, 60 * time.Second)
	server, ok := peer.serve(t, PROBE, peer.CERTIFICATE, peer.KEY)
	if !ok {
		return
	}
	defer peer.stop(t, &server)
	st := Injector {
		fault = c,
	}
	defer injector_destroy(&st)
	cl: peer.Client
	defer peer.destroy(&cl)
	config := peer.Config {
		port            = server.port,
		roots           = peer.CERTIFICATE,
		// Header protection of crafted packets is AES-ECB.
		ciphersuites    = "TLS_AES_128_GCM_SHA256",
		initial_pkt_num = CRAFTED_PN + 1,
		idle_timeout    = time.Second if c == .Close_Valid else 60 * time.Second,
		send            = send,
		receive         = receive,
		expiry          = expiry,
		user            = &st,
	}
	if !testing.expect(t, peer.connect(&cl, config)) {
		return
	}
	_, code := fault(c)
	if positive(c) {
		s := peer.get(&cl, "/probe")
		testing.expectf(
			t,
			s != nil && peer.status(s) == 200 && string(s.body[:]) == "wire-ok",
			"%v: GET /probe: %s (crafted datagram: %d bytes, %v)",
			c,
			peer.describe(&cl),
			st.bytes,
			st.types[:],
		)
		peer.close(&cl)
	} else {
		peer.run(
			cl = &cl,
			timeout = 8 * time.Second,
			done = proc(cl: ^peer.Client, _: rawptr) -> bool {return cl.closed},
		)
		close, closed := cl.peer_close.?
		if c == .Close_Valid {
			testing.expectf(
				t,
				cl.idle_closed && !closed,
				"%v: want the client's idle timeout and no close: %s",
				c,
				peer.describe(&cl),
			)
		} else {
			testing.expectf(
				t,
				closed && close.type == .Transport && close.error_code == code,
				"%v: want a transport CONNECTION_CLOSE 0x%x: %s",
				c,
				code,
				peer.describe(&cl),
			)
		}
	}
	testing.expectf(
		t,
		st.injected && st.failure == "",
		"%v: injected=%v %s",
		c,
		st.injected,
		st.failure,
	)
	testing.expectf(t, st.unexpected == 0, "%v: the server sent frame type 0x%x", c, st.unexpected)
	if c in CONTROLS {
		testing.expectf(
			t,
			st.released && st.observed_acks == 0,
			"%v: released=%v acknowledgements=%d",
			c,
			st.released,
			st.observed_acks,
		)
		// The release was ngtcp2's probe timeout, not an earlier timer.
		testing.expectf(
			t,
			st.released_after + time.Millisecond >= st.pto,
			"%v: released after %v, PTO %v",
			c,
			st.released_after,
			st.pto,
		)
	}
	if c == .Sparse_Crypto {
		// A normal handshake alone would hide a silently discarded
		// injection: the server acknowledged that exact packet.
		testing.expectf(t, st.sparse_acked, "%v: the sparse Initial was not acknowledged", c)
	}
	// The same one-slot server takes fresh work.
	fresh: peer.Client
	defer peer.destroy(&fresh)
	if testing.expect(t, peer.connect(&fresh, {port = server.port, roots = peer.CERTIFICATE})) {
		s := peer.get(&fresh, "/probe")
		testing.expectf(
			t,
			s != nil && peer.status(s) == 200,
			"%v: fresh GET /probe: %s",
			c,
			peer.describe(&fresh),
		)
		peer.close(&fresh)
	}
	testing.expect_value(
		t,
		peer.stop(t, &server),
		fmt.tprintf("RESULT calls=%d", 2 if positive(c) else 1),
	)
}

@(test)
empty :: proc(t: ^testing.T) {exercise(t, .Empty)}
@(test)
nonminimal :: proc(t: ^testing.T) {exercise(t, .Nonminimal)}
@(test)
appclose :: proc(t: ^testing.T) {exercise(t, .Appclose)}
@(test)
ack_unsent :: proc(t: ^testing.T) {exercise(t, .Ack_Unsent)}
@(test)
ack_malformed :: proc(t: ^testing.T) {exercise(t, .Ack_Malformed)}
@(test)
crypto_truncated :: proc(t: ^testing.T) {exercise(t, .Crypto_Truncated)}
@(test)
crypto_overflow :: proc(t: ^testing.T) {exercise(t, .Crypto_Overflow)}
@(test)
crypto_resource :: proc(t: ^testing.T) {exercise(t, .Crypto_Resource)}
@(test)
close_truncated :: proc(t: ^testing.T) {exercise(t, .Close_Truncated)}
@(test)
close_valid :: proc(t: ^testing.T) {exercise(t, .Close_Valid)}
@(test)
bad_tag :: proc(t: ^testing.T) {exercise(t, .Bad_Tag)}
@(test)
invalid_initial :: proc(t: ^testing.T) {exercise(t, .Invalid_Initial)}
@(test)
padding_only :: proc(t: ^testing.T) {exercise(t, .Padding_Only)}
@(test)
ack_only :: proc(t: ^testing.T) {exercise(t, .Ack_Only)}
@(test)
sparse_crypto :: proc(t: ^testing.T) {exercise(t, .Sparse_Crypto)}
