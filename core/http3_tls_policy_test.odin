package saba_core

import "core:crypto/tls"
import credential_store "core:crypto/tls/credentials/store"
import "core:net"
import "core:testing"

@(test)
http3_inherits_client_auth_policy_and_requires_explicit_disable :: proc(t:^testing.T) {
 identity:=https80_make_store(t);defer credential_store.destroy(&identity)
 roots:tls.Root_Pool
 assert(tls.root_pool_parse(&roots,transmute([]u8)string(HTTPS80_TEST_CERT)).kind==.None)
 defer tls.root_pool_destroy(&roots)
 require:=tls.Client_Auth_Config{mode=.Require,roots=roots.roots[:roots.count]}
 tcp:=TLS_Config{store=identity,client_auth=&require}
 runtime:Server_Runtime;owner:Http3;probe:H3_Probe
 h3_unit_init(&runtime,&owner,&probe);defer h3_unit_destroy(&runtime)
 runtime.config.tls=&tcp
 owner.config.credentials=identity;owner.config.endpoint={net.IP4_Loopback,0}
 _,ok:=http3_listen(&owner)
 testing.expect(t,ok)
 testing.expect(t,owner.live.config.client_auth==&require)
 http3_close(&owner)
 // Different policies are explicit. Merely enabling UDP cannot silently turn
 // off a TLS client-certificate requirement on the same application handler.
 disabled:=tls.Client_Auth_Config{mode=.Disabled}
 owner.config.client_auth=&disabled;owner.config.endpoint.port=0
 _,ok=http3_listen(&owner)
 testing.expect(t,ok)
 testing.expect(t,owner.live.config.client_auth==&disabled)
 http3_close(&owner)
 invalid:=tls.Client_Auth_Config{mode=.Require}
 owner.config.client_auth=&invalid;owner.config.endpoint.port=0
 _,ok=http3_listen(&owner)
 testing.expect(t,!ok && !owner.live.have_socket)
}
