// Saba's HTTP/3 server against ngtcp2 and nghttp3 at the QUIC version and
// transport parameter rules: a corrupted Initial coalesced before the genuine
// one, invalid and oversized client transport parameters, and Version
// Negotiation for connection IDs longer than QUIC v1 allows.
package conformance_test

import peer "../peer"
import "core:bytes"
import "core:fmt"
import "core:testing"
import "core:time"

PROBE :: "tests/fixtures/apps/http3_probe"

// QUIC transport error codes (RFC 9000 section 20.1).
TRANSPORT_PARAMETER_ERROR :: 0x08
CRYPTO_BUFFER_EXCEEDED :: 0x0d

// The probe request on a fresh connection: GET /probe answers wire-ok.
probe :: proc(t: ^testing.T, port: int, loc := #caller_location) -> bool {
	cl: peer.Client
	defer peer.destroy(&cl)
	if !testing.expect(t, peer.connect(&cl, {port = port, roots = peer.CERTIFICATE}), loc = loc) {
		return false
	}
	s := peer.get(&cl, "/probe")
	ok := testing.expectf(
		t,
		s != nil && peer.status(s) == 200 && string(s.body[:]) == "wire-ok",
		"GET /probe: status %d, %s",
		peer.status(s) if s != nil else 0,
		peer.describe(&cl),
		loc = loc,
	)
	peer.close(&cl)
	return ok
}

Bad_First :: struct {
	injected: bool,
	size:     int,
	failure:  string,
}

// The client's first datagram arrives twice in one: first with the last byte
// of its Initial (the AEAD tag) flipped, then as it was. The invariant header
// and both connection IDs are unchanged, so only packet protection can tell
// them apart: Saba discards the forgery and completes the genuine handshake.
@(test)
corrupted_initial_before_genuine :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 60 * time.Second)
	server, ok := peer.serve(t, PROBE, peer.CERTIFICATE, peer.KEY)
	if !ok {
		return
	}
	defer peer.stop(t, &server)
	state: Bad_First
	cl: peer.Client
	defer peer.destroy(&cl)
	config := peer.Config {
		port = server.port,
		roots = peer.CERTIFICATE,
		user = &state,
		send = proc(cl: ^peer.Client, datagram: []u8) {
			state := cast(^Bad_First)cl.config.user
			if state.injected {
				peer.transmit(cl, datagram)
				return
			}
			state.injected = true
			found := peer.packets(datagram, 0)
			if len(found) != 1 ||
			   found[0].type != .Initial ||
			   len(datagram) < 1200 ||
			   len(found[0].bytes) != len(datagram) {
				state.failure = fmt.tprintf(
					"the first datagram is not one padded Initial: %d bytes, %v",
					len(datagram),
					found,
				)
				peer.transmit(cl, datagram)
				return
			}
			bad := make([]u8, len(datagram), context.temp_allocator)
			copy(bad, datagram)
			bad[len(bad) - 1] ~= 1
			forged := peer.packets(bad, 0)
			if !bytes.equal(forged[0].dcid, found[0].dcid) ||
			   !bytes.equal(forged[0].scid, found[0].scid) {
				state.failure = "the forgery changed a connection ID"
			}
			combined := make([dynamic]u8, context.temp_allocator)
			append(&combined, ..bad)
			append(&combined, ..datagram)
			state.size = len(combined)
			peer.transmit(cl, combined[:])
		},
	}
	if !testing.expect(t, peer.connect(&cl, config)) {
		return
	}
	s := peer.get(&cl, "/probe")
	testing.expectf(
		t,
		s != nil && peer.status(s) == 200 && string(s.body[:]) == "wire-ok",
		"GET /probe: %s",
		peer.describe(&cl),
	)
	testing.expect(t, state.injected && state.failure == "", state.failure)
	testing.expectf(
		t,
		2400 <= state.size && state.size <= 4096,
		"coalesced datagram of %d bytes",
		state.size,
	)
	peer.close(&cl)
	testing.expect_value(t, peer.stop(t, &server), "RESULT calls=1")
}

Parameters :: struct {
	extra: []u8,
	sent:  bool,
	clash: bool,
}

// The transport parameters ngtcp2 encoded, followed by extra.
append_parameters :: proc(cl: ^peer.Client, encoded: []u8) -> []u8 {
	state := cast(^Parameters)cl.config.user
	at := 0
	for at < len(encoded) {
		id, ok := peer.read_varint(encoded, &at)
		length, ok2 := peer.read_varint(encoded, &at)
		if !ok || !ok2 {
			break
		}
		at += int(length)
		// The extra parameter must be the only one of its ID.
		probe := 0
		extra, _ := peer.read_varint(state.extra, &probe)
		state.clash ||= id == extra
	}
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, ..encoded)
	append(&out, ..state.extra)
	state.sent = true
	return out[:]
}

// A client whose ClientHello carries extra after its genuine transport
// parameters. Saba closes the connection with code before any request.
refused_parameters :: proc(t: ^testing.T, extra: []u8, code: u64) {
	testing.set_fail_timeout(t, 60 * time.Second)
	server, ok := peer.serve(t, PROBE, peer.CERTIFICATE, peer.KEY)
	if !ok {
		return
	}
	defer peer.stop(t, &server)
	state := Parameters {
		extra = extra,
	}
	cl: peer.Client
	defer peer.destroy(&cl)
	if !testing.expect(
		t,
		peer.connect(
			&cl,
			{
				port = server.port,
				roots = peer.CERTIFICATE,
				params = append_parameters,
				user = &state,
			},
		),
	) {
		return
	}
	peer.run(
		cl = &cl,
		timeout = 8 * time.Second,
		done = proc(cl: ^peer.Client, _: rawptr) -> bool {return cl.closed},
	)
	testing.expect(t, state.sent && !state.clash, "the parameter was not sent alone")
	close, closed := cl.peer_close.?
	testing.expectf(
		t,
		closed && close.type == .Transport && close.error_code == code,
		"want a transport CONNECTION_CLOSE 0x%x: %s",
		code,
		peer.describe(&cl),
	)
	testing.expect(t, !cl.handshaken, "the handshake completed")
	testing.expect_value(t, peer.stop(t, &server), "RESULT calls=0")
}

// ack_delay_exponent above 20 is invalid (RFC 9000 section 18.2).
@(test)
invalid_transport_parameter :: proc(t: ^testing.T) {
	refused_parameters(t, {0x0a, 0x01, 21}, TRANSPORT_PARAMETER_ERROR)
}

// A well-formed unknown parameter of 1200 bytes takes the transport
// parameters past Saba's bound on them.
@(test)
oversized_transport_parameters :: proc(t: ^testing.T) {
	extra := make([dynamic]u8, context.temp_allocator)
	peer.varint(&extra, 0x1234)
	peer.varint(&extra, 1200)
	for _ in 0 ..< 1200 {
		append(&extra, 0)
	}
	refused_parameters(t, extra[:], CRYPTO_BUFFER_EXCEEDED)
}

// A long header packet of an unknown version with connection IDs of 21 and
// 255 bytes: the version-independent invariants (RFC 8999) allow them, so
// Saba answers with Version Negotiation that echoes both IDs swapped and lists
// only QUIC v1. It keeps no state: a normal request works afterwards.
@(test)
stateless_version_negotiation :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 60 * time.Second)
	server, ok := peer.serve(t, PROBE, peer.CERTIFICATE, peer.KEY)
	if !ok {
		return
	}
	defer peer.stop(t, &server)
	for size in ([]int{21, 255}) {
		dcid := make([]u8, size, context.temp_allocator)
		scid := make([]u8, size, context.temp_allocator)
		for i in 0 ..< size {
			dcid[i] = u8(i % 251)
			scid[i] = u8((i + 71) % 251)
		}
		packet := make([dynamic]u8, context.temp_allocator)
		append(&packet, 0xc0, 0x7a, 0x7a, 0x7a, 0x7a, u8(size))
		append(&packet, ..dcid)
		append(&packet, u8(size))
		append(&packet, ..scid)
		for len(packet) < 1200 {
			append(&packet, 0)
		}
		reply, from, answered := peer.exchange(server.port, packet[:], 3 * time.Second)
		if !testing.expectf(
			t,
			answered && from == server.port,
			"no Version Negotiation for %d-byte IDs",
			size,
		) {
			continue
		}
		valid :=
			len(reply) == 11 + 2 * size &&
			reply[0] & 0x80 != 0 &&
			bytes.equal(reply[1:5], {0, 0, 0, 0})
		if valid {
			n := int(reply[5])
			destination := reply[6:6 + n]
			m := int(reply[6 + n])
			source := reply[7 + n:7 + n + m]
			versions := reply[7 + n + m:]
			valid =
				bytes.equal(destination, scid) &&
				bytes.equal(source, dcid) &&
				bytes.equal(versions, {0, 0, 0, 1})
		}
		testing.expectf(t, valid, "Version Negotiation for %d-byte IDs: %x", size, reply)
	}
	probe(t, server.port)
	testing.expect_value(t, peer.stop(t, &server), "RESULT calls=1")
}
