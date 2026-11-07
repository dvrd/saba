package server

import core "core"
import dev "development"
import db "shared:kakunou"
import "core:net"
import "core:time"

// Compatibility view: valid only during a synchronous facade handler/helper.
// Do not retain this pointer. Core handlers receive the real stable connection.
Connection :: struct {
	socket: net.TCP_Socket,
	database: ^db.SQLite_DB,
	read_buffer: []u8,
	read_deadline,write_deadline:time.Tick,
	reload:^Reload_State,
	_transport:^core.Connection,
}

@(private)
connection_view :: proc(transport:^core.Connection,database:^db.SQLite_DB)->Connection {
	return {socket=transport.socket,database=database,read_buffer=transport.read_buffer,
		read_deadline=transport.read_deadline,write_deadline=transport.write_deadline,_transport=transport}
}

@(private)
connection_writeback :: proc(view:^Connection,transport:^core.Connection) {
	transport.socket=view.socket
	transport.read_buffer=view.read_buffer
	transport.read_deadline=view.read_deadline
	transport.write_deadline=view.write_deadline
}

@(private)
connection_transport :: proc(view:^Connection,local:^core.Connection)->^core.Connection {
	transport:=view._transport
	if transport==nil do transport=local
	connection_writeback(view,transport)
	return transport
}

@(private)
connection_refresh :: proc(view:^Connection,transport:^core.Connection) {
	view.socket=transport.socket
	view.read_buffer=transport.read_buffer
	view.read_deadline=transport.read_deadline
	view.write_deadline=transport.write_deadline
}

read_connection :: proc(conn:^Connection,buffer:[]u8)->(int,net.TCP_Recv_Error) {
	local:core.Connection
	io:=connection_transport(conn,&local)
	n,error:=core.read_connection(io,buffer)
	connection_refresh(conn,io)
	return n,error
}

write_connection :: proc(conn:^Connection,buffer:[]u8)->(int,net.TCP_Send_Error) {
	local:core.Connection
	io:=connection_transport(conn,&local)
	n,error:=core.write_connection(io,buffer)
	connection_refresh(conn,io)
	return n,error
}

send_response :: proc(conn:^Connection,response:Response,request_method:string="")->bool {
	prepared:=response
	injected:[]u8
	if conn.reload!=nil && dev.reload_html_response(response) {
		ok:bool
		injected,ok=dev.inject_reload_client(response.body)
		if !ok {send_empty_response(conn,.Internal_Server_Error);return false}
		if injected!=nil do prepared.body=injected
	}
	defer delete(injected)
	local:core.Connection
	io:=connection_transport(conn,&local)
	result:=core.send_response(io,prepared,request_method)
	connection_refresh(conn,io)
	return result
}
send_empty_response :: proc(conn:^Connection,status:HTTP_Status)->bool {return send_response(conn,{status=status})}
read_request_body :: proc(conn:^Connection,request:^Request,buffer:[]u8)->(HTTP_Status,bool) {
	local:core.Connection
	io:=connection_transport(conn,&local)
	status,ok:=core.read_request_body(io,request,buffer)
	connection_refresh(conn,io)
	return status,ok
}
send_bytes :: proc(conn:^Connection,data:[]u8,operation:string)->bool {
	local:core.Connection
	io:=connection_transport(conn,&local)
	ok:=core.send_bytes(io,data,operation)
	connection_refresh(conn,io)
	return ok
}

upgrade_websocket :: proc(conn:^Connection,request:^Request)->bool {
	local:core.Connection
	io:=connection_transport(conn,&local)
	ok:=dev.upgrade_websocket(io,request)
	connection_refresh(conn,io)
	return ok
}

send_websocket_frame :: proc(conn:^Connection,opcode:Opcode,payload:[]u8)->bool {
	local:core.Connection
	io:=connection_transport(conn,&local)
	ok:=dev.send_websocket_frame(io,opcode,payload)
	connection_refresh(conn,io)
	return ok
}

send_websocket_close :: proc(conn:^Connection,code:u16,reason:string)->bool {
	local:core.Connection
	io:=connection_transport(conn,&local)
	ok:=dev.send_websocket_close(io,code,reason)
	connection_refresh(conn,io)
	return ok
}

read_websocket_bytes :: proc(conn:^Connection,buffer:[]u8)->bool {
	local:core.Connection
	io:=connection_transport(conn,&local)
	ok:=dev.read_websocket_bytes(io,buffer)
	connection_refresh(conn,io)
	return ok
}
