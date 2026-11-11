package main

import core "shared:saba/core"
import ws "shared:saba/websocket"
import surf "shared:surf"
import codec "shared:websocket"
import tls "core:crypto/tls"
import credentials "core:crypto/tls/credentials"
import store "core:crypto/tls/credentials/store"
import rt "base:runtime"
import "core:fmt"
import "core:bytes"
import "core:log"
import "core:mem"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"

State :: struct {control:core.Server_Control,config:core.Server,tls_config:core.TLS_Config,credentials:^store.Store,auth:tls.Client_Auth_Config,roots:tls.Root_Pool,opened,dropped,messages,http,resets:u64}
Peer :: struct {state:^State}
origin :: proc(_:rawptr,_:^core.Request,value:string,present:bool)->bool {return present && value=="https://allowed.invalid"}
protocol :: proc(_:rawptr,_:^core.Request,offered:[]string)->(string,bool) {for p in offered {if p=="chat.v2" {return p,true}};return "",false}
opened :: proc(data:rawptr,io:^ws.IO) {peer:=cast(^Peer)data;assert(ws.subprotocol(io)=="chat.v2");sync.atomic_add(&peer.state.opened,1)}
message :: proc(data:rawptr,io:^ws.IO,opcode:codec.Opcode,payload:[]u8) {peer:=cast(^Peer)data;sync.atomic_add(&peer.state.messages,1);assert(ws.send(io,opcode,payload)==.Accepted)}
closed :: proc(data:rawptr,event:^ws.Close_Event) {peer:=cast(^Peer)data;if event.transport.kind==.Cancelled {sync.atomic_add(&peer.state.resets,1)}}
drop :: proc(data:rawptr) {peer:=cast(^Peer)data;sync.atomic_add(&peer.state.dropped,1);free(peer,rt.heap_allocator())}
route :: proc(data:rawptr,connection:^core.Connection,request:^core.Request)->core.Response {
 state:=cast(^State)data
 identity:=core.tls_peer_identity(connection)
 if state.auth.mode==.Require {assert(identity.authenticated)}
 if request.path=="/socket" {
  assert(request.version=="HTTP/2" && request.protocol=="websocket")
  peer:=new(Peer,rt.heap_allocator());peer.state=state
  response,error:=ws.upgrade(request,{check_origin=origin,select_subprotocol=protocol,max_frame_bytes=256*1024},
   {data=peer,on_open=opened,on_message=message,on_close=closed,drop=drop})
  if error.kind!=.None {free(peer,rt.heap_allocator())}
  return response
 }
 sync.atomic_add(&state.http,1)
 text:=make([]u8,64,request.allocator)
 digits:="0123456789abcdef"
 for byte,i in identity.certificate_sha256 {text[i*2]=digits[byte>>4];text[i*2+1]=digits[byte&15]}
 headers:=make([]core.Header,1,request.allocator);headers[0]={"x-client-identity",string(text)}
 return {status=.OK,headers=headers,body=transmute([]u8)string("http-ok")}
}
server :: proc(cert_path,key_path:string,root_path:string="") {
 state:State
 cert,ce:=os.read_entire_file(cert_path,context.allocator);assert(ce==nil);defer delete(cert)
 key,ke:=os.read_entire_file(key_path,context.allocator);assert(ke==nil);defer delete(key)
 owner,e:=credentials.create(cert,key,{},context.allocator);assert(e==.None)
 state.credentials,_=store.create({},context.allocator);assert(state.credentials!=nil);defer store.destroy(&state.credentials)
 assert(store.replace(state.credentials,&owner).kind==.None)
 state.tls_config={store=state.credentials,handshake_timeout=2*time.Second,close_timeout=200*time.Millisecond}
 if root_path!="" {
  assert(tls.root_pool_load_file(&state.roots,root_path).kind==.None)
  state.auth={mode=.Require,roots=state.roots.roots[:state.roots.count]}
  state.tls_config.client_auth=&state.auth
 }
 defer tls.root_pool_destroy(&state.roots)
 state.config={port=0,workers=2,tls=&state.tls_config,handler=route,handler_data=&state,control=&state.control,
  keep_alive={enabled=true},resources={connection_limits={64*mem.Megabyte,8,8}},
  timeouts={header=3*time.Second,body=time.Second,response=3*time.Second,idle=5*time.Second},drain_timeout=500*time.Millisecond}
 worker:=thread.create_and_start_with_poly_data(&state,proc(s:^State){assert(core.serve(s.config))})
 assert(worker!=nil)
 until:=time.tick_add(time.tick_now(),5*time.Second)
 for !core.server_ready(&state.control) && time.tick_diff(time.tick_now(),until)>0 {time.sleep(time.Millisecond)}
 endpoint,ready:=core.server_endpoint(&state.control);assert(ready)
 fmt.printf("READY %d\n",endpoint.port);os.flush(os.stdout)
 command:[1]u8;_,_=os.read(os.stdin,command[:])
 core.stop_server(&state.control);thread.join(worker);thread.destroy(worker)
 fmt.printf("RESULT opened=%d dropped=%d messages=%d http=%d resets=%d\n",state.opened,state.dropped,state.messages,state.http,state.resets)
 assert(state.opened==state.dropped)
}
identity_replace :: proc(identity:^store.Store,cert,key:string) {
 certificate,ce:=os.read_entire_file(cert,context.allocator);assert(ce==nil);defer delete(certificate)
 secret,ke:=os.read_entire_file(key,context.allocator);assert(ke==nil);defer delete(secret)
 owner,e:=credentials.create(certificate,secret,{},context.allocator);assert(e==.None)
 assert(store.replace(identity,&owner).kind==.None)
}
identity_check :: proc(identity:^store.Store,response:^surf.Response) {
 lease,e:=store.acquire(identity);assert(e.kind==.None);defer store.release(identity,&lease)
 fingerprint,fe:=store.fingerprint(identity,lease);assert(fe.kind==.None)
 text:[64]u8
 digits:="0123456789abcdef"
 for byte,i in fingerprint {text[i*2]=digits[byte>>4];text[i*2+1]=digits[byte&15]}
 actual,found:=surf.response_header(response,"x-client-identity");assert(found&&actual==string(text[:]))
}
client :: proc(port,cert_path:string,identity_cert:string="",identity_key:string="",replacement_cert:string="",replacement_key:string="") {
 roots:tls.Root_Pool;assert(tls.root_pool_load_file(&roots,cert_path).kind==.None);defer tls.root_pool_destroy(&roots)
 identity:^store.Store
 if identity_cert!="" {identity,_=store.create({},context.allocator);assert(identity!=nil);identity_replace(identity,identity_cert,identity_key)}
 defer if identity!=nil {assert(store.destroy(&identity).kind==.None)}
 http:surf.HTTP_Client
 protocols:=[2]string{"h2","http/1.1"}
 assert(surf.http_client_init(&http,{tls={root_cas=roots.roots[:roots.count],alpn_protocols=protocols[:],client_credentials=identity},timeout=3*time.Second},{},context.allocator).kind==.None)
 defer surf.http_client_close(&http)
 url:=fmt.aprintf("https://localhost:%s/socket",port);defer delete(url)
 health:=fmt.aprintf("https://localhost:%s/health",port);defer delete(health)
 conn:surf.WebSocket_Conn;tunnel:surf.HTTP2_Tunnel
 error:=surf.websocket_http2_open(&http,&tunnel,&conn,url,{origin="https://allowed.invalid",subprotocols={"chat.v2"}})
 fmt.printf("OPEN error=%v phase=%v\n",error.kind,error.phase)
 assert(error.kind==.None)
 defer surf.websocket_release_message(&conn)
 assert(surf.websocket_subprotocol(&conn)=="chat.v2")
 conn2:surf.WebSocket_Conn;tunnel2:surf.HTTP2_Tunnel
 assert(surf.websocket_http2_open(&http,&tunnel2,&conn2,url,{origin="https://allowed.invalid",subprotocols={"chat.v2"}}).kind==.None)
 defer surf.websocket_release_message(&conn2)
 response,re:=surf.http_client_exchange(&http,{method=.GET,url=health})
 assert(re.kind==.None && string(response.body)=="http-ok")
 if identity!=nil {identity_check(identity,&response)}
 surf.response_destroy(&response)
 if replacement_cert!="" {
  dials:=surf.http_client_dials(&http)
  identity_replace(identity,replacement_cert,replacement_key)
  response,re=surf.http_client_exchange(&http,{method=.GET,url=health})
  assert(re.kind==.None && string(response.body)=="http-ok")
  identity_check(identity,&response);surf.response_destroy(&response)
  assert(surf.http_client_dials(&http)==dials+1)
 }
 assert(surf.websocket_write_message(&conn,.Text,transmute([]u8)string("native-hello")).kind==.None)
 buffer:[128]u8
 opcode,n,read:=surf.websocket_read_message(&conn,buffer[:])
 fmt.printf("READ kind=%v n=%d\n",read.kind,n)
 assert(read.kind==.None && opcode==.Text && string(buffer[:n])=="native-hello")
 // This exceeds both the HTTP2 stream window and Saba's64KiB body queue.
 // Incremental backpressure must complete without buffering an unbounded body.
 payload:=make([]u8,128*1024);defer delete(payload)
 for &byte,i in payload {byte=u8(i%251)}
 assert(surf.websocket_write_message(&conn,.Binary,payload).kind==.None)
 received:=make([]u8,len(payload));defer delete(received)
 opcode,n,read=surf.websocket_read_message(&conn,received)
 fmt.printf("LARGE kind=%v n=%d opcode=%v\n",read.kind,n,opcode)
 assert(read.kind==.None && opcode==.Binary && n==len(payload) && bytes.equal(payload,received))
 assert(surf.websocket_close(&conn,1000,"").kind==.None)
 assert(surf.websocket_write_message(&conn2,.Text,transmute([]u8)string("second-stream")).kind==.None)
 opcode,n,read=surf.websocket_read_message(&conn2,buffer[:])
 assert(read.kind==.None && string(buffer[:n])=="second-stream")
 assert(surf.websocket_close(&conn2,1000,"").kind==.None)
 response,re=surf.http_client_exchange(&http,{method=.GET,url=health})
 fmt.printf("AFTER kind=%v phase=%v status=%d body=%s\n",re.kind,re.phase,response.status,string(response.body))
 assert(re.kind==.None && string(response.body)=="http-ok");surf.response_destroy(&response)
 surf.http_client_close(&http)
 if identity!=nil {view,e:=store.stats(identity);assert(e.kind==.None&&view.active_leases==0)}
 fmt.println("OK native-http2-websocket")
}
main :: proc() {
 context.logger=log.nil_logger()
 assert(len(os.args)>=4)
 if os.args[1]=="server" {server(os.args[2],os.args[3])}
 else if os.args[1]=="server-mtls" {assert(len(os.args)==5);server(os.args[2],os.args[3],os.args[4])}
 else if os.args[1]=="client-mtls" {assert(len(os.args)==8);client(os.args[2],os.args[3],os.args[4],os.args[5],os.args[6],os.args[7])}
 else {client(os.args[2],os.args[3])}
}
