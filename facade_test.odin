package server

import core "core"
import application "application"
import db "shared:kakunou"
import "core:mem"
import "core:testing"
import "core:time"

@(test)
facade_handler_view_preserves_typed_database_and_io_without_allocation :: proc(t:^testing.T) {
	database:db.SQLite_DB
	buffer:=[]u8{'a','b'}
	transport:=core.Connection{read_buffer=buffer}
	config:=Server{database=&database,handler=proc(conn:^Connection,request:^Request)->Response {
		assert(conn.database!=nil)
		one:[1]u8
		n,error:=read_connection(conn,one[:])
		assert(n==1 && error==nil && one[0]=='a')
		conn.write_deadline=time.tick_add(time.tick_now(),time.Second)
		return {status=.OK}
	}}
	tracker:mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker,context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	request:=Request{method="GET",path="/plain",allocator=mem.tracking_allocator(&tracker)}
	view:=application.Dispatch_Context{connection=&transport,request=&request}
	response:=legacy_dispatch(&config,&view)
	testing.expect_value(t,response.status,.OK)
	testing.expect_value(t,len(transport.read_buffer),1)
	testing.expect_value(t,transport.read_buffer[0],u8('b'))
	testing.expect(t,transport.write_deadline!=time.Tick{})
	testing.expect_value(t,tracker.total_memory_allocated,i64(0))
}
