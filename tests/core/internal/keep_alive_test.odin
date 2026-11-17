package saba_core

import "core:log"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
keep_alive_config_is_bounded_and_defaults_are_explicit :: proc(t:^testing.T) {
	testing.expect(t,keep_alive_valid({}))
	testing.expect(t,!keep_alive_valid({max_requests=-1}))
	testing.expect(t,!keep_alive_valid({max_requests=MAX_KEEP_ALIVE_REQUESTS+1}))
	testing.expect(t,!keep_alive_valid({idle_timeout=-1}))
	testing.expect(t,!keep_alive_valid({idle_timeout=MAX_SERVER_TIMEOUT+1}))
	testing.expect_value(t,keep_alive_request_limit({}),100)
	runtime := Server_Runtime{timeouts=resolve_timeouts({idle=40*time.Millisecond})}
	testing.expect_value(t,keep_alive_idle_timeout(&runtime),40*time.Millisecond)
	runtime.config.keep_alive.idle_timeout = 60*time.Millisecond
	testing.expect_value(t,keep_alive_idle_timeout(&runtime),60*time.Millisecond)
	previous := context.logger
	context.logger = log.nil_logger()
	result := serve({handler=proc(_:rawptr,_: ^Connection,_:^Request)->Response{return {}},keep_alive={max_requests=-1}})
	context.logger = previous
	testing.expect(t,!result)
}

@(test)
keep_alive_close_tokens_caps_and_wire_policy :: proc(t:^testing.T) {
	for sample in ([]struct{value:string,close:bool}{
		{"keep-alive",false},{"Upgrade, cLoSe",true},{"close",true},{"keep-alive, close",true},{"",true},{",",true},{"invalid token",true},
	}) {
		request := Request{headers=[]Header{{"cOnNeCtIoN",sample.value}}}
		testing.expect_value(t,request_wants_close(&request),sample.close)
	}
	runtime := Server_Runtime{config={keep_alive={enabled=true,max_requests=3}}}
	task := Connection_Task{runtime=&runtime,phase=.Dispatch}
	testing.expect(t,response_can_reuse(&task,.OK))
	testing.expect(t,!response_can_reuse(&task,.Switching_Protocols))
	testing.expect(t,!response_can_reuse(&task,cast(HTTP_Status)100))
	testing.expect(t,!response_can_reuse(&task,cast(HTTP_Status)103))
	task.requests_completed = 2
	testing.expect(t,!response_can_reuse(&task,.OK))
	task.requests_completed = 0
	runtime.draining = true
	testing.expect(t,!response_can_reuse(&task,.OK))
	buffer: [8192]u8
	head, valid := response_headers({status=.OK},buffer[:],true)
	testing.expect(t,valid && strings.contains(string(head),"Connection: keep-alive\r\n"))
	head, valid = response_headers({status=.OK},buffer[:])
	testing.expect(t,valid && strings.contains(string(head),"Connection: close\r\n"))
}

@(test)
keep_alive_idle_list_is_bounded_and_removal_is_idempotent :: proc(t:^testing.T) {
	runtime: Server_Runtime
	one := Connection_Task{runtime=&runtime}
	two := Connection_Task{runtime=&runtime}
	testing.expect(t,keep_alive_enter_idle(&one))
	testing.expect(t,keep_alive_enter_idle(&two))
	testing.expect(t,runtime.keep_alive_idle_tasks==&two && two.idle_next==&one && one.idle_previous==&two)
	keep_alive_leave_idle(&one)
	keep_alive_leave_idle(&one)
	testing.expect(t,two.idle_next==nil && !one.idle_registered)
	keep_alive_leave_idle(&two)
	testing.expect(t,runtime.keep_alive_idle_tasks==nil)
	runtime.draining = true
	testing.expect(t,!keep_alive_enter_idle(&one))
}

@(test)
keep_alive_next_request_clears_the_previous_write_deadline :: proc(t:^testing.T) {
	runtime := Server_Runtime{timeouts=resolve_timeouts({})}
	task := Connection_Task{runtime=&runtime}
	task.connection.write_deadline = time.tick_add(time.tick_now(),time.Second)
	testing.expect(t,keep_alive_begin_request(&task,3))
	testing.expect_value(t,task.connection.write_deadline,time.Tick{})
}
