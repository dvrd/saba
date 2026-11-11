package saba_core

import http "../../http"
import h2 "shared:http/v2"
import hpack "shared:http/v2/hpack"
import exchange "shared:http/exchange"
import signal "shared:async/signal"
import "core:mem"
import charged "core:mem/budget"
import owned "core:mem/owned"
import "core:net"
import "core:strings"
import "core:strconv"
import budget "core:sync/budget"
import "core:time"

// Only the parent task touches the engine or socket. A lazy request context owns
// the arena, cancellation, continuation and producer until its own stream ends.
@(private)
H2_Request :: struct {
 parent:^Connection_Task,
 task:Connection_Task,
 handle:h2.Stream_Handle,
 receiving,have_length,request_open,ready,headers_sent,failed:bool,
 expected,limit,body_len,offset,producer_offset:int,
 body_deadline,response_deadline:time.Tick,
 response:Response,
}
@(private)
h2_request_allocator :: proc(task:^Connection_Task)->mem.Allocator {
 allocator:=charged.allocator(task.resource_binding)
 if allocator.procedure==nil {allocator=connection_storage_allocator(task)}
 return allocator
}
@(private)
h2_request_find :: proc(parent:^Connection_Task,handle:h2.Stream_Handle)->^H2_Request {
 for request in parent.http2.requests {if request!=nil && request.handle==handle {return request}}
 return nil
}
@(private)
h2_request_count :: proc(parent:^Connection_Task)->int {
 count:=0;for request in parent.http2.requests {if request!=nil {count+=1}};return count
}
@(private)
h2_request_release :: proc(request:^H2_Request,success:bool,status:Request_Status) {
 parent:=request.parent;task:=&request.task;session:=parent.http2
 if !success {cancel_request_context(task.request.cancellation,status)}
 task.response_finished=success
 drop_deferred(task);drop_response_stream(task);discard_response(&request.response)
 finish_request_context(task);observe_finish(task)
 mem.dynamic_arena_destroy(&task.arena);finish_operation_resources(task)
 charged.release(&task.resource_transport)
 budget.release_scope(&task.resource_connection)
 for &slot in session.requests {if slot==request {slot=nil;break}}
 h2_remember(session,request.handle)
 session.idle_deadline=time.tick_add(time.tick_now(),parent.runtime.timeouts.idle)
 free(request,session.allocator)
}
@(private)
h2_request_open :: proc(parent:^Connection_Task,event:h2.Headers_Event)->bool {
 session:=parent.http2
 slot:=-1;for request,i in session.requests {if request==nil {slot=i;break}}
 if slot<0 || session.shutdown || server_is_draining(parent.runtime) {return false}
 request,error:=new(H2_Request,session.allocator);if error!=nil {return false}
 request.parent=parent;request.handle=event.stream
 task:=&request.task;task.runtime=parent.runtime;task.http2=session;task.http2_request=request
 task.connection={_task=task,_secure=true,_peer_identity=tls_peer_identity(&parent.connection),socket=net.TCP_Socket(-1),_timeouts=parent.runtime.timeouts}
 if budget.same_scope(parent.resource_connection,parent.resource_connection) {
  retained,e:=budget.retain_scope(parent.resource_connection)
  if e!=.None {free(request,session.allocator);return false}
  task.resource_connection=retained
 }
 session.requests[slot]=request
 if !start_operation_resources(task) {h2_request_release(request,false,.Unavailable);return false}
 init_connection_arena(task)
 previous_temp:=context.temp_allocator;defer context.temp_allocator=previous_temp
 context.temp_allocator=mem.dynamic_arena_allocator(&task.arena)
 if parent.observed && !parent.observation_finished {
  task.observed=parent.observed;task.observed_at=parent.observed_at;task.event=parent.event
  parent.observed=false;parent.observation_finished=true
 } else {observe_start(task)}
 if !h2_request_decode(task,event.summary,event.end_stream) {
  _=h2.connection_reset(&session.engine,event.stream,.Cancel)
  h2_request_release(request,false,.Failed)
 }
 return true
}
@(private)
h2_request_complete :: proc(task:^Connection_Task) {
 request:=task.http2_request
 if request.failed || !request.request_open || request.ready || task.deferred.poll!=nil {return}
 request.receiving=false
 previous_temp:=context.temp_allocator;defer context.temp_allocator=previous_temp
 context.temp_allocator=task.request.allocator
 if request.have_length && request.body_len!=request.expected {
  request.failed=true;return
 }
 task.request.body=task.request.body[:request.body_len]
 request.response_deadline=time.tick_add(time.tick_now(),task.runtime.timeouts.response)
 response:=dispatch_request(task)
 if !h2_queue_response(task,response) {request.failed=true}
}
@(private)
h2_request_emergency :: proc(task:^Connection_Task,status:HTTP_Status)->bool {
 request:=task.http2_request
 drop_deferred(task);drop_response_stream(task);discard_response(&request.response)
 if request.headers_sent {request.failed=true;return true}
 request.response={status=status};request.ready=true;request.receiving=false
 if task.observed {task.event.status=status}
 if request.response_deadline==(time.Tick{}) {request.response_deadline=time.tick_add(time.tick_now(),task.runtime.timeouts.response)}
 return true
}
@(private)
h2_queue_response :: proc(task:^Connection_Task,response:Response)->bool {
 request:=task.http2_request
 if request==nil {discarded:=response;discard_response(&discarded);return false}
 if resource_pressure(task) {discarded:=response;discard_response(&discarded);return h2_request_emergency(task,.Service_Unavailable)}
 if deferred_present(response.deferred) {
  if !queue_deferred(task,response) {return false}
  signal.detach(task.deferred_signal);signal.release(&task.deferred_signal)
  created:=false
  task.deferred_signal,created=signal.create(&task.runtime.executor,&request.parent.task)
  request.response_deadline=task.deferred_expires
  return created
 }
 prepared:=response;content_coding_prepare(&task.request,&prepared)
 if prepared.upgrade.resume!=nil || prepared.upgrade.drop!=nil || prepared.upgrade.data!=nil || prepared.status==.Switching_Protocols {
  discard_response(&prepared);prepared={status=.Not_Implemented}
 }
 if !resource_copy_response(task,&prepared) {discard_response(&prepared);return h2_request_emergency(task,.Service_Unavailable)}
 if prepared.status==.None {prepared.status=.OK}
 request.response=prepared;request.ready=true
 request.response_deadline=time.tick_add(time.tick_now(),task.runtime.timeouts.response)
 if task.observed {task.event.status=prepared.status}
 if stream_present(prepared.stream) {
  request.response.stream={}
  if !queue_stream_response(task,prepared) {return false}
  if task.streaming!=nil {request.response_deadline=task.streaming.expires}
 }
 return true
}
@(private)
h2_request_trailers :: proc(request:^H2_Request,fields:[]hpack.Field) {
 task:=&request.task;allocator:=mem.dynamic_arena_allocator(&task.arena)
 trailers,e:=make([]Header,len(fields),allocator);if e!=nil {request.failed=true;return}
 for field,i in fields {
  name,nok:=h2_clone(field.name,allocator);value,vok:=h2_clone(field.value,allocator)
  if !nok || !vok {request.failed=true;return}
  trailers[i]={name,value}
 }
 task.request.trailers=trailers
}
@(private)
h2_request_data :: proc(request:^H2_Request,event:h2.Event_View,value:h2.Data_Event)->bool {
 engine:=&request.parent.http2.engine
 incoming:h2.Incoming_Data
 if h2.connection_data_take(engine,event.token,&incoming).kind!=.None {return false}
 bytes,ok:=h2.incoming_data_bytes(&incoming)
 if ok && request.receiving && !request.failed {
  if len(bytes)>request.limit-request.body_len {_=h2_request_emergency(&request.task,.Content_Too_Large)} else {
   copy(request.task.request.body[request.body_len:],bytes);request.body_len+=len(bytes)
   if request.task.observed {request.task.event.bytes_received+=u64(len(bytes))}
  }
 }
 _=h2.connection_discard(engine,value.consumption);h2.incoming_data_destroy(&incoming)
 if value.end_stream && request.receiving {h2_request_complete(&request.task)}
 return true
}
// Headers are copied by the engine before these bounded stack buffers expire.
@(private)
h2_request_headers :: proc(request:^H2_Request,trailers:bool)->h2.Error {
 fields:[H2_FIELD_CAP]hpack.Field;names:[H2_NAME_SCRATCH]u8;used,count:=0,0
 status:[3]u8;length:[32]u8
 if !trailers {
  code:=int(request.response.status);status={u8('0'+code/100),u8('0'+code/10%10),u8('0'+code%10)}
  fields[0]={":status",string(status[:]),false};count=1
 }
 headers:=request.response.trailers if trailers else request.response.headers
 for header in headers {
  if count==len(fields) || len(header.name)>len(names)-used {return {kind=.Invalid_Input}}
  start:=used
  for byte in transmute([]u8)header.name {lower:=byte;if lower>='A'&&lower<='Z' {lower+=32};names[used]=lower;used+=1}
  name:=string(names[start:used]);if h2_skip_response_header(name) {continue}
  fields[count]={name,header.value,false};count+=1
 }
 code:=int(request.response.status)
 if !trailers && count<len(fields) && code>=200 && code!=204 && code!=304 && (http.response_body_allowed(code,request.task.request.method) || request.task.request.method=="HEAD") {
  size:=i64(len(request.response.body));if request.task.streaming!=nil {size=request.task.streaming.producer.content_length}
  if size>=0 {fields[count]={"content-length",strconv.write_int(length[:],size,10),false};count+=1}
 }
 if trailers {return h2.connection_send_trailers(&request.parent.http2.engine,request.handle,fields[:count])}
 return h2.connection_send_headers(&request.parent.http2.engine,request.handle,fields[:count],false)
}
@(private)
h2_request_output :: proc(request:^H2_Request)->bool {
 task:=&request.task;engine:=&request.parent.http2.engine
 if !request.ready {return false}
 if pending,ok:=h2.connection_stream_output_pending(engine,request.handle);!ok || pending {return false}
 if !request.headers_sent {
  error:=h2_request_headers(request,false)
  if error.kind==.Limit_Exceeded {return false}
  if error.kind!=.None {request.failed=true;return false}
  request.headers_sent=true;return true
 }
 source:[]u8;done:=!http.response_body_allowed(int(request.response.status),task.request.method)
 if !done && task.streaming!=nil {
  stream:=task.streaming
  if !stream.pending && !stream.terminal {
   if produce_stream(task)==.Done {request.failed=true;return false}
  }
  if stream.pending {body,ok:=exchange.body(&stream.exchange);if !ok {request.failed=true;return false};source=body[request.producer_offset:]}
  done=stream.terminal
 } else if !done {source=request.response.body[request.offset:];done=len(source)==0}
 if len(source)>0 {
  amount:=min(len(source),H2_FRAME_BYTES)
  chunk,e:=owned.copy_bounded(source[:amount],H2_FRAME_BYTES,request.parent.http2.allocator)
  if e.kind!=.None {request.failed=true;return false}
  error:=h2.connection_send_data(engine,request.handle,&chunk,false)
  if error.kind!=.None {owned.destroy(&chunk);if error.kind!=.Limit_Exceeded {request.failed=true};return false}
  if task.streaming!=nil {
   request.producer_offset+=amount
   if amount==len(source) {request.producer_offset=0;task.streaming.pending=false;if !exchange.release_body(&task.streaming.exchange) {request.failed=true}}
  } else {request.offset+=amount}
  return true
 }
 if !done {return false}
 if len(request.response.trailers)>0 {
  error:=h2_request_headers(request,true)
  if error.kind==.Limit_Exceeded {return false}
  if error.kind!=.None {request.failed=true;return false}
 } else {
  empty,allocation:=owned.copy_bounded(nil,0,request.parent.http2.allocator)
  if allocation.kind!=.None {request.failed=true;return false}
  // A zero-byte DATA FIN has no payload backing and consumes no body credit.
  error:=h2.connection_send_data(engine,request.handle,&empty,true)
  if error.kind!=.None {owned.destroy(&empty);if error.kind!=.Limit_Exceeded {request.failed=true};return false}
 }
 if request.response.close_connection {h2_shutdown(request.parent)}
 h2_request_release(request,true,.Completed)
 return true
}
@(private)
h2_requests_pump :: proc(parent:^Connection_Task)->bool {
 previous_temp:=context.temp_allocator;defer context.temp_allocator=previous_temp
 session:=parent.http2;progress:=false;count:=len(session.requests)
 for i in 0..<count {
  index:=(session.cursor+i)%count;request:=session.requests[index];if request==nil {continue}
  task:=&request.task
  context.temp_allocator=mem.dynamic_arena_allocator(&task.arena)
  deadline:=request.body_deadline if request.receiving else request.response_deadline
  if deadline!=(time.Tick{}) && deadline_expired(deadline) {cancel_request_context(task.request.cancellation,.Deadline);request.failed=true}
  if request_cancelled(task.request.cancellation) {request.failed=true}
  if !request.failed && task.deferred.poll!=nil {
   if deadline_expired(task.deferred_expires) {request.failed=true;cancel_request_context(task.request.cancellation,.Deadline)} else {
    response,step:=task.deferred.poll(task.deferred.data,&Deferred_IO{resources=task.resource_operation,backing_allocator=task.request.backing_allocator,allocator=task.request.allocator,cancellation=task.request.cancellation,wake=task.deferred_signal})
    if step==.Ready {
     drop_deferred(task)
     if deferred_present(response.deferred) {discard_response(&response);request.failed=true} else if !h2_queue_response(task,response) {request.failed=true}
     progress=true
    } else {discard_response(&response);if step==.Failed {request.failed=true}}
   }
  }
  if request.failed {
   _=h2.connection_reset(&session.engine,request.handle,.Cancel);h2_request_release(request,false,.Failed);progress=true;continue
  }
  progress=h2_request_output(request)||progress
 }
 if count>0 {session.cursor=(session.cursor+1)%count}
 return progress
}
@(private)
h2_request_decode :: proc(task: ^Connection_Task, summary: h2.Header_Summary, end_stream: bool) -> bool {
	session := task.http2_request
	if task.observation_finished {
		task.observed = false
		task.observation_finished = false
		task.response_finished = false
		task.event = {}
		observe_start(task)
	}
	allocator := mem.dynamic_arena_allocator(&task.arena)
	method, method_ok := h2_clone(summary.method, allocator)
	path_raw, path_ok := h2_clone(summary.path, allocator)
	authority, authority_ok := h2_clone(summary.authority, allocator)
	if !method_ok || !path_ok || !authority_ok {
		session.failed = true
		return false
	}
	path, query := path_raw, ""
	if mark := strings.index(path, "?"); mark >= 0 {
		query = path[mark + 1:]
		path = path[:mark]
	}
	regular := 0
	has_host := false
	for field in summary.fields {
		if len(field.name) == 0 || field.name[0] == ':' do continue
		if strings.equal_fold(field.name, "host") do has_host = true
		regular += 1
	}
	if !has_host && authority != "" do regular += 1
	if regular > REQUEST_HEADER_COUNT_LIMIT {
		observe_failure(task, .Protocol_Error)
		return false
	}
	headers, header_error := make([]Header, regular, allocator)
	if header_error != nil {
		session.failed = true
		return false
	}
	index := 0
	for field in summary.fields {
		if len(field.name) == 0 || field.name[0] == ':' do continue
		name, name_ok := h2_clone(field.name, allocator)
		value, value_ok := h2_clone(field.value, allocator)
		if !name_ok || !value_ok {
			session.failed = true
			return false
		}
		headers[index] = {name, value}
		index += 1
	}
	if !has_host && authority != "" {
		headers[index] = {"host", authority}
		index += 1
	}
	limit := REQUEST_BODY_LIMIT
	request := Request{
		resources = task.resource_operation,
		backing_allocator = h2_request_allocator(task),
		allocator = allocator,
		method = method,
		path = path,
		query = query,
		version = "HTTP/2",
		headers = headers[:index],
		request_id = task.event.request_id,
		_observe = task.observed,
	}
	task.request = request
	if task.runtime.config.request_body_limit != nil {
		limit = task.runtime.config.request_body_limit(&task.request)
	}
	if limit < 0 {
		observe_failure(task, .Protocol_Error)
		return false
	}
	expected := 0
	have_length := false
	if length, present := summary.content_length.?; present {
		if length > u64(max(int)) || int(length) > limit {
			observe_failure(task, .Protocol_Error)
			return false
		}
		expected = int(length)
		have_length = true
	}
	capacity := expected if have_length else limit
	if !end_stream || (have_length && expected > 0) {
		body, body_error := make([]u8, capacity, allocator)
		if body_error != nil {
			session.failed = true
			return false
		}
		task.request.body = body
	}
	task.request.has_content_length = have_length
	task.request.content_length = expected
	session.have_length = have_length
	session.expected = expected
	session.limit = capacity
	session.body_len = 0
	session.request_open = true
	session.receiving = !end_stream
	duration := body_timeout(task.runtime.timeouts, expected if have_length else 0)
	session.body_deadline = time.tick_add(time.tick_now(), duration)
	if task.observed do task.event.method = method
	if end_stream do h2_request_complete(task)
	return true
}

