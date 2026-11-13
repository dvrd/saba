package saba_core

import http3 "../../http/v3"
import credential_store "core:crypto/tls/credentials/store"
import "core:crypto/tls"
import "core:log"
import "core:net"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

@(test)
http3_request_timeout_is_forwarded_without_resolving_phase_timeouts :: proc(t:^testing.T) {
 identity:=https80_make_store(t);defer credential_store.destroy(&identity)
 runtime:Server_Runtime
 runtime.config.handler=proc(_:rawptr,_:^Connection,_:^Request)->Response{return {status=.OK}}
 runtime.timeouts=resolve_timeouts({header=time.Second,body=2*time.Second,response=3*time.Second})
 for duration in ([]time.Duration{0,201*time.Millisecond,MAX_SERVER_TIMEOUT}) {
  owner:=new(Http3);defer free(owner)
  owner.runtime=&runtime
  owner.config={enabled=true,endpoint={net.IP4_Loopback,0},credentials=identity,request_timeout=duration}
  port,ok:=http3_listen(owner)
  testing.expect(t,ok&&port>0)
  testing.expect_value(t,owner.live.config.request_timeout,duration)
  http3_close(owner)
 }
}

@(test)
http3_request_timeout_invalid_values_fail_before_listener_configuration :: proc(t:^testing.T) {
 context.logger=log.nil_logger()
 identity:=https80_make_store(t);defer credential_store.destroy(&identity)
 runtime:Server_Runtime
 runtime.config.handler=proc(_:rawptr,_:^Connection,_:^Request)->Response{return {status=.OK}}
 for duration in ([]time.Duration{-1,MAX_SERVER_TIMEOUT+1}) {
  owner:=new(Http3);defer free(owner)
  owner.runtime=&runtime
  owner.config={enabled=true,endpoint={net.IP4_Loopback,0},credentials=identity,request_timeout=duration}
  owner.live.config.request_timeout=17*time.Second
  port,ok:=http3_listen(owner)
  testing.expect(t,!ok&&port==0)
  testing.expect_value(t,owner.live.config.request_timeout,17*time.Second)
  testing.expect(t,!owner.live.have_socket&&owner.live.peers==nil)
  control:Server_Control;stop_server(&control)
  // With no HTTP3 listener enabled, an omitted early validation would let the
  // remembered stop complete a successful ordinary TCP serve.
  testing.expect(t,!serve({control=&control,http3={request_timeout=duration},handler=runtime.config.handler}))
 }
}

H3_Timeout_Client :: struct {endpoint:net.Endpoint,roots:^tls.Root_Pool,result:http3.Client_Result,}
H3_Timeout_Probe :: struct {calls,polls,drops:int,forwarded:bool,}
h3_timeout_poll :: proc(data:rawptr,_:^Deferred_IO)->(Response,Deferred_Step) {
 probe:=cast(^H3_Timeout_Probe)data
 sync.atomic_add(&probe.polls,1)
 // Keep the public Saba callback pending well beyond the transport budget.
 return {},.Waiting
}
h3_timeout_drop :: proc(data:rawptr) {sync.atomic_add(&(cast(^H3_Timeout_Probe)data).drops,1)}
h3_timeout_handler :: proc(data:rawptr,connection:^Connection,_:^Request)->Response {
 probe:=cast(^H3_Timeout_Probe)data
 sync.atomic_add(&probe.calls,1)
 sync.atomic_store(&probe.forwarded,connection._task.runtime.http3.live.config.request_timeout==200*time.Millisecond)
 return {deferred={data=data,poll=h3_timeout_poll,drop=h3_timeout_drop}}
}

@(test)
http3_request_timeout_native_pending_callback_closes_and_releases_once :: proc(t:^testing.T) {
 testing.set_fail_timeout(t,15*time.Second)
 identity:=https80_make_store(t);defer credential_store.destroy(&identity)
 roots:tls.Root_Pool
 assert(tls.root_pool_parse(&roots,transmute([]u8)string(HTTPS80_TEST_CERT)).kind==.None)
 defer tls.root_pool_destroy(&roots)
 probe:H3_Timeout_Probe;fixture:H3_Server_Fixture
 fixture.config={handler=h3_timeout_handler,handler_data=&probe,control=&fixture.control,workers=2,
  timeouts={response=10*time.Second},handler_timeout=10*time.Second,
  http3={enabled=true,endpoint={net.IP4_Loopback,0},credentials=identity,request_timeout=200*time.Millisecond,idle={timeout=5*time.Second}}}
 worker:=thread.create_and_start_with_poly_data(&fixture,proc(f:^H3_Server_Fixture){f.ok=serve(f.config)})
 assert(worker!=nil);defer thread.destroy(worker)
 joined:=false
 defer if !joined {stop_server(&fixture.control);thread.join(worker)}
 until:=time.tick_add(time.tick_now(),5*time.Second)
 for !server_ready(&fixture.control)&&time.tick_diff(time.tick_now(),until)>0 {thread.yield()}
 endpoint,ready:=server_http3_endpoint(&fixture.control)
 if !testing.expect(t,ready&&endpoint.port>0) {return}
 client:=new(H3_Timeout_Client);defer free(client)
 client.endpoint=endpoint;client.roots=&roots
 peer:=thread.create_and_start_with_poly_data(client,proc(c:^H3_Timeout_Client){
  c.result=http3.client_exchange_request(c.endpoint,"synthetic.invalid",{method="GET",target="/pending",authority="synthetic.invalid"},c.roots.roots[:c.roots.count],time.time_add(time.now(),4*time.Second))
 });assert(peer!=nil);defer {thread.join(peer);thread.destroy(peer)}
 until=time.tick_add(time.tick_now(),2*time.Second)
 for sync.atomic_load(&probe.drops)==0&&time.tick_diff(time.tick_now(),until)>0 {thread.yield()}
 // This proves timely native-server release. The independent peer harness
 // separately authenticates the on-wire application CONNECTION_CLOSE.
 testing.expect_value(t,sync.atomic_load(&probe.calls),1)
 testing.expect(t,sync.atomic_load(&probe.polls)>0&&sync.atomic_load(&probe.forwarded))
 testing.expect_value(t,sync.atomic_load(&probe.drops),1)
 stop_server(&fixture.control);thread.join(worker);joined=true
 testing.expect(t,fixture.ok)
 testing.expect_value(t,probe.drops,1)
}

@(test)
http3_request_timeout_zero_keeps_native_thirty_second_default :: proc(t:^testing.T) {
 testing.set_fail_timeout(t,15*time.Second)
 identity:=https80_make_store(t);defer credential_store.destroy(&identity)
 roots:tls.Root_Pool
 assert(tls.root_pool_parse(&roots,transmute([]u8)string(HTTPS80_TEST_CERT)).kind==.None)
 defer tls.root_pool_destroy(&roots)
 default_seen:=false;fixture:H3_Server_Fixture
 fixture.config={handler_data=&default_seen,control=&fixture.control,workers=2,
  handler=proc(data:rawptr,c:^Connection,_:^Request)->Response {
   found:=false
   for peer in c._task.runtime.http3.live.peers {if peer!=nil {
    for slot in peer.in_streams {if slot.dispatched&&!slot.released {
     remaining:=time.diff(time.now(),slot.request.deadline)
     found=remaining>29*time.Second&&remaining<=30*time.Second
    }}
   }}
   sync.atomic_store(cast(^bool)data,found)
   return {status=.OK}
  },
  http3={enabled=true,endpoint={net.IP4_Loopback,0},credentials=identity}}
 worker:=thread.create_and_start_with_poly_data(&fixture,proc(f:^H3_Server_Fixture){f.ok=serve(f.config)})
 assert(worker!=nil);defer thread.destroy(worker)
 joined:=false
 defer if !joined {stop_server(&fixture.control);thread.join(worker)}
 until:=time.tick_add(time.tick_now(),5*time.Second)
 for !server_ready(&fixture.control)&&time.tick_diff(time.tick_now(),until)>0 {thread.yield()}
 endpoint,ready:=server_http3_endpoint(&fixture.control)
 if !testing.expect(t,ready&&endpoint.port>0) {return}
 result:=http3.client_exchange_request(endpoint,"synthetic.invalid",{method="GET",target="/default",authority="synthetic.invalid"},roots.roots[:roots.count],time.time_add(time.now(),4*time.Second))
 testing.expect_value(t,result.error,.None)
 testing.expect_value(t,result.status,200)
 testing.expect(t,sync.atomic_load(&default_seen))
 stop_server(&fixture.control);thread.join(worker);joined=true
 testing.expect(t,fixture.ok)
}
