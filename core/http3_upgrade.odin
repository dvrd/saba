package saba_core
import http3 "../../http/v3"
import async "shared:async"
import "core:strings"

@(private)
Http3_Upgrade_IO :: struct {state:^Http3_Request,endpoint:^http3.Connect_Stream}
@(private)
http3_upgrade_response :: proc(owner:^Http3,wire:^http3.Server_Request,state:^Http3_Request,out:^http3.Server_Response)->(bool,http3.Response_Status) {
 response:=&state.response
 if response.upgrade.resume==nil && response.upgrade.drop==nil && response.upgrade.data==nil {return false,.Pending}
 if wire.connect==nil || wire.protocol!="websocket" || response.upgrade.resume==nil {return false,.Pending}
 if response.status!=.OK || stream_present(response.stream) || len(response.body)>0 {discard_response(response);out.status=500;return true,.Ready}
 task:=&state.connection
 if !resource_copy_response(task,response) {return true,.Failed}
 fields,error:=make([]http3.Field,len(response.headers),task.request.allocator);if error!=nil {return true,.Failed}
 for header,i in response.headers {
  name,e:=strings.to_lower(header.name,task.request.allocator);if e!=nil {return true,.Failed}
  fields[i]={name=name,value=header.value}
 }
 task.upgrade=response.upgrade;response.upgrade={}
 out.status=200;out.headers=fields
 out.duplex={data=state,resume=http3_upgrade_resume,drop=http3_upgrade_drop}
 return true,.Ready
}
@(private)
http3_upgrade_resume :: proc(data:rawptr,endpoint:^http3.Connect_Stream)->http3.Duplex_Status {
 state:=cast(^Http3_Request)data;task:=&state.connection
 if endpoint.cancelled {cancel_request_context(task.request.cancellation,.Peer_Closed)}
 if task.upgrade.resume==nil {return .Done}
 transport:=Http3_Upgrade_IO{state,endpoint}
 io:=Upgrade_IO{runtime=&state.owner.runtime.executor,connection=&task.connection,stream_data=&transport,
  stream_read=http3_upgrade_read,stream_write=http3_upgrade_write,stream_wait=http3_upgrade_wait}
 result:=task.upgrade.resume(task.upgrade.data,&io)
 return .Done if result==.Done else .Pending
}
@(private)
http3_upgrade_drop :: proc(data:rawptr) {drop_upgrade(&(cast(^Http3_Request)data).connection)}
@(private)
http3_upgrade_expired :: proc(io:^Http3_Upgrade_IO,deadline:async.Deadline)->bool {return deadline.epoch!=0 && async.deadline_after(&io.state.owner.runtime.executor,0).at>=deadline.at}
@(private)
http3_upgrade_error :: proc(status:http3.Connect_IO_Status)->async.Error {
 switch status {case .None:return {};case .Pending:return {kind=.Pending};case .End:return {kind=.Peer_Closed};case .Cancelled:return {kind=.Cancelled};case .Failed:return {kind=.Closed}}
 return {kind=.Closed}
}
@(private)
http3_upgrade_read :: proc(data:rawptr,dst:[]u8,deadline:async.Deadline)->(int,async.Error) {
 io:=cast(^Http3_Upgrade_IO)data
 if http3_upgrade_expired(io,deadline) {return 0,{kind=.Timeout}}
 n,status:=http3.connect_read(io.endpoint,dst);return n,http3_upgrade_error(status)
}
@(private)
http3_upgrade_write :: proc(data:rawptr,src:[]u8,deadline:async.Deadline)->(int,async.Error) {
 io:=cast(^Http3_Upgrade_IO)data
 if http3_upgrade_expired(io,deadline) {return 0,{kind=.Timeout}}
 n,status:=http3.connect_write(io.endpoint,src);return n,http3_upgrade_error(status)
}
@(private)
http3_upgrade_wait :: proc(data:rawptr,read,write:bool,deadline:async.Deadline)->async.Error {
 io:=cast(^Http3_Upgrade_IO)data
 if io.endpoint.cancelled {return {kind=.Cancelled}}
 if http3_upgrade_expired(io,deadline) {return {kind=.Timeout}}
 if read && (io.endpoint.input_n>0 || io.endpoint.remote_fin) {return {}}
 if write && io.endpoint.output_n<len(io.endpoint.output)-4 {return {}}
 if deadline.epoch!=0 {return async.sleep_until_earlier(&io.state.owner.runtime.executor,deadline)}
 return {kind=.Pending}
}
