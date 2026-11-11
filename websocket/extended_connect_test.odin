package saba_websocket

import core "../core"
import "core:testing"

@(test)
extended_connect_uses_protocol_and_version_without_http1_key :: proc(t:^testing.T) {
 headers:=[]core.Header{{"host","example.test"},{"sec-websocket-version","13"},{"sec-websocket-protocol","chat"}}
 request:=core.Request{method="CONNECT",version="HTTP/2",protocol="websocket",path="/chat",headers=headers}
 fields,error:=request_fields(&request)
 testing.expect_value(t,error.kind,.None)
 testing.expect_value(t,fields.version,"13")
 testing.expect_value(t,fields.key,"")
 testing.expect_value(t,fields.offered_count,1)
 for extra in ([]core.Header{{"sec-websocket-key","dGhlIHNhbXBsZSBub25jZQ=="},{"upgrade","websocket"},{"connection","upgrade"},{"sec-websocket-version","13"}}) {
  combined:[4]core.Header;copy(combined[:],headers);combined[3]=extra;request.headers=combined[:]
  _,rejected:=request_fields(&request)
  testing.expect_value(t,rejected.kind,.Invalid_Request)
 }
 request.headers=headers;request.protocol="other"
 _,wrong_protocol:=request_fields(&request)
 testing.expect_value(t,wrong_protocol.kind,.Invalid_Request)
 request.protocol="websocket";request.method="GET"
 _,wrong_method:=request_fields(&request)
 testing.expect_value(t,wrong_method.kind,.Invalid_Request)
}

@(test)
extended_connect_preserves_origin_policy_before_owner_transfer :: proc(t:^testing.T) {
 headers:=[]core.Header{{"host","example.test"},{"sec-websocket-version","13"},{"origin","https://example.test"}}
 request:=core.Request{method="CONNECT",version="HTTP/2",protocol="websocket",path="/chat",headers=headers}
 probe:=WS79_Policy_Probe{reject_origin=true}
 owner:WS79_Application_Probe
 response,error:=upgrade(&request,{check_origin=ws79_origin_policy,policy_data=&probe},ws79_application(&owner))
 testing.expect_value(t,error.kind,.Origin_Rejected)
 testing.expect_value(t,probe.origins,1)
 testing.expect_value(t,owner.drops,0)
 testing.expect(t,response.upgrade.data==nil)
 core.discard_response(&response)
}
