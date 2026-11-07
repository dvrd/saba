package saba_development

import core "../core"
import rt "base:runtime"
import "core:sync"
import "core:time"
import "core:unicode/utf8"
import async "shared:async"

@(private)
Session_Phase :: enum {Header,Frame,Write}
@(private)
Reload_Session :: struct {
	state:^Reload_State,
	phase:Session_Phase,
	initialized:bool,
	version:u64,
	deadline:async.Deadline,
	input:[131]u8,
	used,expected:int,
	output:[256]u8,
	output_used,output_offset:int,
	close_after:bool,
}

// This adapter owns WebSocket framing/session storage; core drives only the
// optional continuation on its existing task and destroys it exactly once.
handle :: proc(state:^Reload_State,request:^Request)->(Response,bool) {
	if core.match_route(request,"GET","/__reload/client.js") do return reload_client_response(request),true
	if !core.match_route(request,"GET","/__reload") do return {},false
	accept_storage,allocation_error:=make([]u8,28,request.allocator)
	if allocation_error!=nil do return {status=.Internal_Server_Error},true
	accept,status:=websocket_accept(request,accept_storage)
	if status!=.None do return {status=status},true
	response:=make_response(request,.Switching_Protocols,{{"Upgrade","websocket"},{"Sec-WebSocket-Accept",accept}})
	if response.status!=.Switching_Protocols do return response,true
	session,error:=new(Reload_Session,rt.heap_allocator())
	if error!=nil do return {status=.Internal_Server_Error},true
	session.state=state
	session.version=sync.atomic_load(&state.version)
	response.upgrade={data=session,resume=resume_session,drop=drop_session}
	return response,true
}

@(private)
drop_session :: proc(data:rawptr) {free(cast(^Reload_Session)data,rt.heap_allocator())}

@(private)
reset_session_read :: proc(session:^Reload_Session,io:^core.Upgrade_IO) {
	session.used,session.expected=0,2
	session.phase=.Header
	session.deadline=async.deadline_after(io.runtime,RELOAD_INTERVAL)
	io.connection.read_deadline=time.tick_add(time.tick_now(),RELOAD_INTERVAL)
}

@(private)
queue_session_output :: proc(session:^Reload_Session,io:^core.Upgrade_IO,count:int,close_after:bool) {
	session.output_used,session.output_offset=count,0
	session.close_after=close_after
	session.phase=.Write
	session.deadline=async.deadline_after(io.runtime,RESPONSE_SEND_TIMEOUT)
	io.connection.write_deadline=time.tick_add(time.tick_now(),RESPONSE_SEND_TIMEOUT)
}

@(private)
append_websocket_frame :: proc(storage:[]u8,opcode:Opcode,payload:[]u8)->int {
	assert(len(payload)<=125 && len(storage)>=len(payload)+2)
	storage[0],storage[1]=0x80|u8(opcode),u8(len(payload))
	copy(storage[2:],payload)
	return len(payload)+2
}

@(private)
queue_session_close :: proc(session:^Reload_Session,io:^core.Upgrade_IO,code:u16,reason:string) {
	payload:[125]u8
	assert(len(reason)<=123)
	payload[0],payload[1]=u8(code>>8),u8(code&255)
	copy(payload[2:],reason)
	count:=append_websocket_frame(session.output[:],.Close,payload[:2+len(reason)])
	queue_session_output(session,io,count,true)
}

@(private)
resume_session :: proc(data:rawptr,io:^core.Upgrade_IO)->async.Resume_Result {
	session:=cast(^Reload_Session)data
	if !session.initialized {session.initialized=true;reset_session_read(session,io)}
	if session.phase==.Write {
		if session.output_offset==session.output_used {
			if session.close_after do return .Done
			reset_session_read(session,io)
			return .Yield
		}
		n,error:=async.write(io.socket,session.output[session.output_offset:session.output_used],session.deadline)
		if error.kind==.Pending do return .Waiting
		if error.kind!=.None do return .Done
		session.output_offset+=n
		return .Yield
	}
	used:=session.used
	if session.phase==.Header && used==0 {
		if sync.atomic_load(&session.state.stopped) do return .Done
		if sync.atomic_load(&session.state.version)!=session.version {
			count:=append_websocket_frame(session.output[:],.Text,transmute([]u8)string("reload"))
			payload:=[]u8{u8(REGULAR_CLOSE>>8),u8(REGULAR_CLOSE&255),'r','e','l','o','a','d','i','n','g'}
			count+=append_websocket_frame(session.output[count:],.Close,payload)
			queue_session_output(session,io,count,true)
			return .Yield
		}
	}
	target:=session.expected
	if session.phase==.Header && used==0 do target=1
	n,error:=core.upgrade_read(io,session.input[used:target],session.deadline)
	if error.kind==.Pending do return .Waiting
	if error.kind==.Timeout && used==0 && session.phase==.Header {reset_session_read(session,io);return .Yield}
	if error.kind!=.None do return .Done
	session.used+=n
	used=session.used
	if used==1 {
		session.deadline=async.deadline_after(io.runtime,REQUEST_HEADER_TIMEOUT)
		io.connection.read_deadline=time.tick_add(time.tick_now(),REQUEST_HEADER_TIMEOUT)
		return .Yield
	}
	if used<session.expected do return .Yield
	header:=session.input[:2]
	opcode:=Opcode(header[0]&15)
	length:=int(header[1]&127)
	if session.phase==.Header {
		code:u16=PROTOCOL_ERROR
		reason:string
		if header[0]&0x70!=0 {reason="reserved bits must be zero"}
		else if header[1]&0x80==0 {reason="client frames must be masked"}
		else if opcode==.Text || opcode==.Binary {code=UNSUPPORTED_DATA;reason="reload endpoint accepts control frames only"}
		else if opcode!=.Close && opcode!=.Ping && opcode!=.Pong {reason="unsupported opcode"}
		else if header[0]&0x80==0 {reason="control frames must not be fragmented"}
		else if length>125 {reason="control payload exceeds125bytes"}
		else if opcode==.Close && length==1 {reason="close payload must be empty or contain at least2bytes"}
		if reason!="" {queue_session_close(session,io,code,reason);return .Yield}
		session.expected=6+length
		session.phase=.Frame
		return .Yield
	}
	mask:=session.input[2:6]
	payload:=session.input[6:6+length]
	for &value,i in payload do value~=mask[i%4]
	#partial switch opcode {
	case .Close:
		if length>=2 {
			code:=u16(payload[0])<<8|u16(payload[1])
			if !valid_close_code(code) {queue_session_close(session,io,PROTOCOL_ERROR,"invalid close code");return .Yield}
			if !utf8.valid_string(string(payload[2:])) {queue_session_close(session,io,INVALID_PAYLOAD_DATA,"close reason must be valid UTF-8");return .Yield}
		}
		count:=append_websocket_frame(session.output[:],.Close,payload)
		queue_session_output(session,io,count,true)
	case .Ping:
		count:=append_websocket_frame(session.output[:],.Pong,payload)
		queue_session_output(session,io,count,false)
	case .Pong:reset_session_read(session,io)
	case:return .Done
	}
	return .Yield
}
