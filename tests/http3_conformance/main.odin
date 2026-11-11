package main

import core "shared:saba/core"
import surf "shared:surf"
import http "shared:http"
import "core:strconv"
import h3 "shared:http/v3"
import "core:crypto/tls"
import credentials "core:crypto/tls/credentials"
import store "core:crypto/tls/credentials/store"
import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"

State :: struct {control:core.Server_Control,server:core.Server,calls:u64}
route :: proc(data:rawptr,_:^core.Connection,request:^core.Request)->core.Response {
 assert(request.version=="HTTP/3")
 state:=cast(^State)data
 sync.atomic_add(&state.calls,1)
 if request.path=="/head204" {assert(request.method=="HEAD");return {status=.No_Content}}
 if request.path=="/head304" {
  assert(request.method=="HEAD"&&core.header_value(request,"if-none-match")=="\"asset-v1\"")
  headers:=make([]core.Header,1,request.allocator);headers[0]={"etag","\"asset-v1\""}
  return {status=.Not_Modified,headers=headers}
 }
 if request.path=="/head200" {assert(request.method=="HEAD");return {status=.OK,body=transmute([]u8)string("hello")}}
 assert(request.path=="/probe")
 return {status=.OK,body=transmute([]u8)string("wire-ok")}
}
server :: proc(cert_path,key_path:string) {
	cert,ce:=os.read_entire_file(cert_path,context.allocator);assert(ce==nil);defer delete(cert)
	key,ke:=os.read_entire_file(key_path,context.allocator);assert(ke==nil);defer delete(key)
	identity,error:=credentials.create(cert,key,{},context.allocator);assert(error==.None)
	owner,se:=store.create({},context.allocator);assert(se.kind==.None);defer assert(store.destroy(&owner).kind==.None)
	assert(store.replace(owner,&identity).kind==.None)
	state:State
	state.server={port=0,workers=2,handler=route,handler_data=&state,control=&state.control,http3={enabled=true,endpoint={net.IP4_Loopback,0},credentials=owner,max_connections=1},drain_timeout=300*time.Millisecond}
	worker:=thread.create_and_start_with_poly_data(&state,proc(s:^State){assert(core.serve(s.server))})
	assert(worker!=nil);defer thread.destroy(worker)
	until:=time.tick_add(time.tick_now(),5*time.Second)
	for !core.server_ready(&state.control)&&time.tick_diff(time.tick_now(),until)>0 {time.sleep(time.Millisecond)}
	endpoint,ready:=core.server_http3_endpoint(&state.control);assert(ready)
	fmt.printf("READY %d\n",endpoint.port);os.flush(os.stdout)
	command:[1]u8;_,_=os.read(os.stdin,command[:])
	core.stop_server(&state.control);thread.join(worker)
	fmt.printf("RESULT calls=%d\n",state.calls)
}
client :: proc(port_text,cert_path,mode:string) {
 roots:tls.Root_Pool;assert(tls.root_pool_load_file(&roots,cert_path).kind==.None);defer tls.root_pool_destroy(&roots)
 if mode=="client" {
  url:=fmt.aprintf("https://localhost:%s/probe",port_text);defer delete(url)
  response,error:=surf.execute({method=.GET,url=url},{http3=true,timeout=10*time.Second,tls={root_cas=roots.roots[:roots.count]}})
  if error.kind!=.None {fmt.printf("CLIENT error=%v status=%d\n",error,response.status);os.flush(os.stdout)}
  assert(error.kind==.None&&response.status==200&&string(response.body)=="wire-ok")
  surf.response_destroy(&response)
 } else if mode=="client-head" {
  pool:h3.Pool;defer h3.pool_close(&pool)
  config:=surf.Config{http3=true,http3_pool=&pool,timeout=10*time.Second,tls={root_cas=roots.roots[:roots.count]}}
  cases:=[3]struct {path:string,status:int}{{"/head204",204},{"/head304",304},{"/head200",200}}
  for test in cases {
   url:=fmt.aprintf("https://localhost:%s%s",port_text,test.path)
   conditional:=[1]http.Header{{"if-none-match","\"asset-v1\""}}
   response,error:=surf.execute({method=.HEAD,url=url,headers=conditional[:]},config)
   assert(error.kind==.None&&response.status==test.status&&len(response.body)==0)
   value,found:=surf.response_header(&response,"content-length")
   if test.status==200 {assert(found&&value=="5")} else {assert(!found)}
   if test.status==304 {etag,have:=surf.response_header(&response,"etag");assert(have&&etag=="\"asset-v1\"")}
   fmt.printf("HEAD status=%d content_length=%s present=%v body=%d\n",response.status,value,found,len(response.body))
   surf.response_destroy(&response);delete(url)
  }
 } else {
  port,ok:=strconv.parse_u64(port_text);assert(ok)
  result:=h3.client_exchange_request({net.IP4_Loopback,int(port)},"localhost",{method="GET",target="/probe",authority="localhost"},roots.roots[:roots.count],time.time_add(time.now(),10*time.Second))
  reason:=string(result.reason[:result.reason_len])
  fmt.printf("NEGATIVE error=%v reason=%s sent=%v status=%d\n",result.error,reason,result.sent,result.status)
  expected:="version negotiation";if mode=="client-tp" {expected="transport parameters"}
  assert(result.error==.Protocol&&reason==expected&&!result.sent&&result.status==0)
 }
 fmt.println("OK native",mode)
}
main :: proc() {
 context.logger=log.nil_logger();assert(len(os.args)==4)
 if os.args[1]=="server" {server(os.args[2],os.args[3])} else {client(os.args[2],os.args[3],os.args[1])}
}
