package main

import core "shared:saba/core"
import surf "shared:surf"
import h3 "shared:http/v3"
import "core:crypto/tls"
import credentials "core:crypto/tls/credentials"
import store "core:crypto/tls/credentials/store"
import "core:fmt"
import "core:strconv"
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
 url:=fmt.aprintf("https://localhost:%s/probe",port_text);defer delete(url)
 if mode=="client" {
  response,error:=surf.execute({method=.GET,url=url},{http3=true,timeout=5*time.Second,tls={root_cas=roots.roots[:roots.count]}})
  if error.kind!=.None {fmt.printf("POSITIVE error=%v status=%d\n",error,response.status)}
  assert(error.kind==.None&&response.status==200&&string(response.body)=="wire-ok");surf.response_destroy(&response)
 } else {
  port,ok:=strconv.parse_u64(port_text);assert(ok)
  endpoint:=net.Endpoint{net.IP4_Loopback,int(port)}
  result:=h3.client_exchange_request(endpoint,"localhost",{method="GET",target="/probe",authority="localhost"},roots.roots[:roots.count],time.time_add(time.now(),5*time.Second))
  fmt.printf("NEGATIVE error=%v reason=%s sent=%v status=%d\n",result.error,string(result.reason[:result.reason_len]),result.sent,result.status)
  assert(result.error==.Protocol&&!result.sent&&result.status==0)
 }
 fmt.println("OK native",mode)
}
main :: proc() {
 context.logger=log.nil_logger();assert(len(os.args)==4)
 if os.args[1]=="server" {server(os.args[2],os.args[3])} else {client(os.args[2],os.args[3],os.args[1])}
}
