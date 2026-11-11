package saba_core

import h2 "shared:http/v2"
import hpack "shared:http/v2/hpack"
import async "shared:async"
import rt "base:runtime"
import "core:mem"
import owned "core:mem/owned"
import budget "core:sync/budget"
import "core:net"
import "core:strings"

H2_UPGRADE_SLOTS :: 4
@(private)
H2_Upgrade_Input :: struct {owner:h2.Incoming_Data,credit:h2.Data_Token,offset:int}
@(private)
H2_Upgrade :: struct {
 parent:^Connection_Task,
 handle:h2.Stream_Handle,
 connection:Connection_Task,
 response:Response,
 accepted,headers_sent,remote_end,remote_reset,app_done,fin_sent,failed:bool,
 body_sent:int,
 inputs:[H2_BODY_CHUNKS]H2_Upgrade_Input,
 input_head,input_count:int,
}

@(private)
h2_upgrade_find :: proc(task:^Connection_Task,handle:h2.Stream_Handle)->^H2_Upgrade {
 for stream in task.http2.upgrades {if stream!=nil && stream.handle==handle {return stream}}
 return nil
}
@(private)
h2_upgrade_count :: proc(task:^Connection_Task)->int {
 n:=0;for stream in task.http2.upgrades {if stream!=nil {n+=1}};return n
}
@(private)
h2_upgrade_release :: proc(stream:^H2_Upgrade) {
 if stream==nil {return}
 parent:=stream.parent;session:=parent.http2
 for &entry in stream.inputs {
  if entry.credit!=(h2.Data_Token{}) {_=h2.connection_discard(&session.engine,entry.credit)}
  h2.incoming_data_destroy(&entry.owner)
 }
 task:=&stream.connection
 drop_upgrade(task);discard_response(&stream.response)
 finish_request_context(task)
 mem.dynamic_arena_destroy(&task.arena)
 finish_operation_resources(task)
 budget.release_scope(&task.resource_connection)
 for &slot in session.upgrades {if slot==stream {slot=nil;break}}
 h2_remember(session,stream.handle)
 free(stream,rt.heap_allocator())
}

@(private)
h2_upgrade_open :: proc(parent:^Connection_Task,event:h2.Headers_Event)->bool {
 session:=parent.http2
 slot:=-1;for stream,i in session.upgrades {if stream==nil {slot=i;break}}
 if slot<0 || event.end_stream || server_is_draining(parent.runtime) {return false}
 stream,allocated:=new(H2_Upgrade,rt.heap_allocator())
 if allocated!=nil {return false}
 stream.parent=parent;stream.handle=event.stream
 task:=&stream.connection;task.runtime=parent.runtime
 task.connection={_task=task,_secure=true,_peer_identity=tls_peer_identity(&parent.connection),socket=net.TCP_Socket(-1),_timeouts=parent.runtime.timeouts}
 if budget.same_scope(parent.resource_connection,parent.resource_connection) {
  retained,e:=budget.retain_scope(parent.resource_connection)
  if e!=.None {free(stream,rt.heap_allocator());return false}
  task.resource_connection=retained
 }
 session.upgrades[slot]=stream
 if !start_operation_resources(task) {h2_upgrade_release(stream);return false}
 init_connection_arena(task)
 allocator:=mem.dynamic_arena_allocator(&task.arena)
 summary:=event.summary
 method,method_ok:=h2_clone(summary.method,allocator)
 target,target_ok:=h2_clone(summary.path,allocator)
 protocol,protocol_ok:=h2_clone(summary.protocol,allocator)
 if !method_ok || !target_ok || !protocol_ok {h2_upgrade_release(stream);return false}
 headers,he:=make([]Header,len(summary.fields)+1,allocator)
 if he!=nil {h2_upgrade_release(stream);return false}
 count:=0
 for field in summary.fields {
  if len(field.name)==0 || field.name[0]==':' {continue}
  name,nok:=h2_clone(field.name,allocator);value,vok:=h2_clone(field.value,allocator)
  if !nok || !vok {h2_upgrade_release(stream);return false}
  headers[count]={name,value};count+=1
 }
 authority,aok:=h2_clone(summary.authority,allocator)
 if !aok {h2_upgrade_release(stream);return false}
 headers[count]={"host",authority};count+=1
 task.request={resources=task.resource_operation,backing_allocator=connection_storage_allocator(task),allocator=allocator,
  method=method,path=target,protocol=protocol,version="HTTP/2",headers=headers[:count]}
 if at:=strings.index_byte(target,'?');at>=0 {task.request.path=target[:at];task.request.query=target[at+1:]}
 response:=dispatch_request(task)
 if !resource_copy_response(task,&response) {discard_response(&response);h2_upgrade_release(stream);return false}
 if response.status==.None {response.status=.OK}
 stream.accepted=response.upgrade.resume!=nil && int(response.status)>=200 && int(response.status)<300 &&
  !stream_present(response.stream) && !deferred_present(response.deferred)
 upgrade_present:=response.upgrade.resume!=nil || response.upgrade.drop!=nil || response.upgrade.data!=nil
 if upgrade_present && !stream.accepted || stream_present(response.stream) || deferred_present(response.deferred) {
  discard_response(&response);response={status=.Not_Implemented}
 }
 if stream.accepted {task.upgrade=response.upgrade;response.upgrade={}}
 stream.response=response
 return true
}

@(private)
h2_upgrade_data :: proc(stream:^H2_Upgrade,event:h2.Event_View,value:h2.Data_Event)->bool {
 session:=stream.parent.http2
 if stream.input_count==len(stream.inputs) {return false}
 at:=(stream.input_head+stream.input_count)%len(stream.inputs)
 entry:=&stream.inputs[at]
 if h2.connection_data_take(&session.engine,event.token,&entry.owner).kind!=.None {return false}
 entry.credit=value.consumption;stream.input_count+=1
 if value.end_stream {stream.remote_end=true}
 return true
}
@(private)
h2_upgrade_read :: proc(data:rawptr,destination:[]u8,deadline:async.Deadline)->(int,async.Error) {
 stream:=cast(^H2_Upgrade)data;session:=stream.parent.http2
 if stream.remote_reset {return 0,{kind=.Cancelled}}
 if h2_upgrade_expired(stream,deadline) {return 0,{kind=.Timeout}}
 if len(destination)==0 {return 0,{}}
 for stream.input_count>0 {
  entry:=&stream.inputs[stream.input_head]
  bytes,ok:=h2.incoming_data_bytes(&entry.owner)
  if !ok {return 0,{kind=.Closed}}
  n:=copy(destination,bytes[entry.offset:]);entry.offset+=n
  if n>0 {_=h2.connection_consume(&session.engine,entry.credit,u32(n))}
  if entry.offset==len(bytes) {
   if len(bytes)==0 {_=h2.connection_discard(&session.engine,entry.credit)}
   h2.incoming_data_destroy(&entry.owner);entry^={}
   stream.input_head=(stream.input_head+1)%len(stream.inputs);stream.input_count-=1
  }
  // Empty/padding-only DATA is legal HTTP2 framing, not WebSocket EOF.
  if n>0 {return n,{}}
 }
 if stream.remote_end {return 0,{kind=.Peer_Closed}}
 return 0,{kind=.Pending}
}
@(private)
h2_upgrade_write :: proc(data:rawptr,source:[]u8,deadline:async.Deadline)->(int,async.Error) {
 stream:=cast(^H2_Upgrade)data
 if stream.remote_reset {return 0,{kind=.Cancelled}}
 if h2_upgrade_expired(stream,deadline) {return 0,{kind=.Timeout}}
 if stream.fin_sent {return 0,{kind=.Closed}}
 amount:=min(len(source),H2_FRAME_BYTES)
 if amount==0 {return 0,{}}
 chunk,e:=owned.copy_bounded(source[:amount],H2_FRAME_BYTES,connection_storage_allocator(&stream.connection))
 if e.kind!=.None {return 0,{kind=.Allocation_Failed}}
 error:=h2.connection_send_data(&stream.parent.http2.engine,stream.handle,&chunk,false)
 if error.kind!=.None {
  owned.destroy(&chunk)
  return 0,{kind=.Pending if error.kind==.Limit_Exceeded else .Closed}
 }
 return amount,{}
}
@(private)
h2_upgrade_wait :: proc(data:rawptr,read,write:bool,deadline:async.Deadline)->async.Error {
 stream:=cast(^H2_Upgrade)data
 if stream.remote_reset {return {kind=.Cancelled}}
 if read && (stream.input_count>0 || stream.remote_end) {return {}}
 if deadline.epoch!=0 {return async.sleep_until_earlier(&stream.parent.runtime.executor,deadline)}
 return {kind=.Pending}
}

@(private)
h2_upgrade_headers :: proc(stream:^H2_Upgrade)->bool {
 if stream.headers_sent {return true}
 fields:[H2_FIELD_CAP]hpack.Field;names:[H2_NAME_SCRATCH]u8;used:=0;count:=1
 status:[3]u8;code:=int(stream.response.status)
 status={u8('0'+code/100),u8('0'+code/10%10),u8('0'+code%10)}
 fields[0]={":status",string(status[:]),false}
 for header in stream.response.headers {
  if count==len(fields) || len(header.name)>len(names)-used {return false}
  start:=used
  for byte in transmute([]u8)header.name {
   lower:=byte;if lower>='A' && lower<='Z' {lower+=32};names[used]=lower;used+=1
  }
  lower:=string(names[start:used])
  if h2_skip_response_header(lower) {continue}
  fields[count]={lower,header.value,lower=="set-cookie"};count+=1
 }
 end:=!stream.accepted && len(stream.response.body)==0
 e:=h2.connection_send_headers(&stream.parent.http2.engine,stream.handle,fields[:count],end)
 if e.kind==.Limit_Exceeded {return false}
 if e.kind!=.None {_=h2.connection_reset(&stream.parent.http2.engine,stream.handle,.Cancel);stream.app_done=true;stream.failed=true;return true}
 stream.headers_sent=true;stream.fin_sent=end
 return true
}
@(private)
h2_upgrade_pump :: proc(parent:^Connection_Task)->bool {
 progress:=false
 for stream in parent.http2.upgrades {
  if stream==nil {continue}
  if !h2_upgrade_headers(stream) {continue}
  if stream.failed {h2_upgrade_release(stream);progress=true;continue}
  if stream.fin_sent {stream.connection.response_finished=true;h2_upgrade_release(stream);progress=true;continue}
  if !stream.accepted {
   if stream.body_sent<len(stream.response.body) {
    part:=stream.response.body[stream.body_sent:][:min(H2_FRAME_BYTES,len(stream.response.body)-stream.body_sent)]
    n,e:=h2_upgrade_write(stream,part,{})
    if e.kind==.None {stream.body_sent+=n;progress=progress||n>0}
    if stream.body_sent<len(stream.response.body) {continue}
   }
   stream.app_done=true
  } else if !stream.app_done {
   io:=Upgrade_IO{runtime=&parent.runtime.executor,connection=&stream.connection.connection,
    stream_data=stream,stream_read=h2_upgrade_read,stream_write=h2_upgrade_write,stream_wait=h2_upgrade_wait}
   result:=stream.connection.upgrade.resume(stream.connection.upgrade.data,&io)

   if result==.Done {stream.app_done=true;drop_upgrade(&stream.connection);progress=true}
   if result==.Yield {progress=true}
  }
  if stream.app_done && !stream.fin_sent {
   empty,allocation:=owned.allocate(0,connection_storage_allocator(&stream.connection))
   if allocation.kind!=.None {continue}
   e:=h2.connection_send_data(&parent.http2.engine,stream.handle,&empty,true)
   if e.kind==.Limit_Exceeded {owned.destroy(&empty);continue}
   if e.kind!=.None {owned.destroy(&empty)}
   stream.fin_sent=e.kind==.None
   if e.kind!=.None {_=h2.connection_reset(&parent.http2.engine,stream.handle,.Cancel)}
  }
  if stream.fin_sent || stream.app_done {
   stream.connection.response_finished=stream.fin_sent
   h2_upgrade_release(stream);progress=true
  }
 }
 return progress
}

@(private)
h2_upgrade_expired :: proc(stream:^H2_Upgrade,deadline:async.Deadline)->bool {
 return deadline.epoch!=0 && async.deadline_after(&stream.parent.runtime.executor,0).at>=deadline.at
}

@(private)
h2_upgrade_reset :: proc(stream:^H2_Upgrade) {
 stream.remote_reset=true
 cancel_request_context(stream.connection.request.cancellation,.Peer_Closed)
 if stream.accepted && stream.headers_sent && !stream.app_done {
  io:=Upgrade_IO{runtime=&stream.parent.runtime.executor,connection=&stream.connection.connection,
   stream_data=stream,stream_read=h2_upgrade_read,stream_write=h2_upgrade_write,stream_wait=h2_upgrade_wait}
  // One final serialized callback observes cancellation; the owner retires the
  // stream regardless of whether application code correctly returns Done.
  _=stream.connection.upgrade.resume(stream.connection.upgrade.data,&io)
 }
 h2_upgrade_release(stream)
}
