package saba_core

import http3 "../../http/v3"
import "core:crypto/tls"
import credential_store "core:crypto/tls/credentials/store"
import "core:net"
import "core:testing"
import "core:time"

@(test)
http3_inherits_client_auth_policy_and_requires_explicit_disable :: proc(t: ^testing.T) {
	identity := https80_make_store(t)
	defer credential_store.destroy(&identity)
	roots: tls.Root_Pool
	assert(tls.root_pool_parse(&roots, transmute([]u8)string(HTTPS80_TEST_CERT)).kind == .None)
	defer tls.root_pool_destroy(&roots)
	require := tls.Client_Auth_Config {
		mode  = .Require,
		roots = roots.roots[:roots.count],
	}

	keys: tls.Server_Ticket_Keys
	assert(tls.server_ticket_keys_init(&keys) == .None)
	defer tls.server_ticket_keys_close(&keys)
	tickets := tls.Server_Ticket_Config {
		keys         = &keys,
		lifetime     = time.Hour,
		policy_epoch = 1,
	}

	tcp := TLS_Config {
		store       = identity,
		client_auth = &require,
		tickets     = &tickets,
	}

	runtime: Server_Runtime
	owner: Http3
	probe: H3_Probe
	h3_unit_init(&runtime, &owner, &probe)
	defer h3_unit_destroy(&runtime)
	runtime.config.tls = &tcp
	owner.config.credentials = identity
	owner.config.endpoint = {net.IP4_Loopback, 0}
	_, ok := http3_listen(&owner)
	testing.expect(t, ok)
	testing.expect(t, owner.live.config.client_auth == &require)
	testing.expect(t, owner.live.config.tickets == &tickets)
	http3.listener_close(&owner.live)
	// Different policies are explicit. Merely enabling UDP cannot silently turn
	// off a TLS client-certificate requirement on the same application handler.
	disabled := tls.Client_Auth_Config {
		mode = .Disabled,
	}

	owner.config.client_auth = &disabled
	owner.config.endpoint.port = 0
	owner.config.disable_tickets = true
	_, ok = http3_listen(&owner)
	testing.expect(t, ok)
	testing.expect(t, owner.live.config.client_auth == &disabled)
	testing.expect(t, owner.live.config.tickets == nil)
	http3.listener_close(&owner.live)
	invalid := tls.Client_Auth_Config {
		mode = .Require,
	}

	owner.config.client_auth = &invalid
	owner.config.endpoint.port = 0
	_, ok = http3_listen(&owner)
	testing.expect(t, !ok && !owner.live.have_socket)
}
