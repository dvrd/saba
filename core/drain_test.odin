package saba_core

import "core:testing"
import "core:time"
import async "shared:async"

@(test)
drain_control_remembers_requests_and_rejects_invalid_budgets :: proc(t:^testing.T) {
	control:Server_Control
	testing.expect_value(t,server_state(&control),.Stopped)
	testing.expect(t,!server_ready(&control))
	testing.expect(t,!drain_server(nil))
	testing.expect(t,!drain_server(&control,-time.Second))
	testing.expect(t,!drain_server(&control,MAX_DRAIN_TIMEOUT+1))
	testing.expect(t,drain_server(&control))
	testing.expect(t,drain_server(&control,2*time.Second))
	testing.expect(t,drain_server(&control,3*time.Second))
	testing.expect_value(t,control._drain_timeout,2*time.Second)
	testing.expect(t,control._drain_default_requested)
	stop_server(&control)
	testing.expect(t,!drain_server(&control))
	release_server(&control)
	testing.expect(t,!control._drain_requested && control._drain_timeout==0)
}

@(test)
repeated_runtime_drain_never_extends_deadline :: proc(t:^testing.T) {
	runtime:Server_Runtime
	error:=async.init(&runtime.executor,{workers=1,task_capacity=2,io_capacity=0})
	if !testing.expect_value(t,error.kind,.None) {return}
	defer async.destroy(&runtime.executor)
	runtime.config.drain_timeout=10*time.Second
	request_runtime_drain(&runtime,0)
	first:=runtime.drain_deadline
	request_runtime_drain(&runtime,20*time.Second)
	testing.expect_value(t,runtime.drain_deadline,first)
	request_runtime_drain(&runtime,time.Second)
	testing.expect(t,runtime.drain_deadline.at<first.at)
	testing.expect(t,runtime.draining)
}

@(test)
readiness_stops_on_internal_runtime_shutdown :: proc(t:^testing.T) {
    control:Server_Control
    runtime:Server_Runtime
    error:=async.init(&runtime.executor,{workers=1,task_capacity=2,io_capacity=0})
    if !testing.expect_value(t,error.kind,.None) {return}
    defer async.destroy(&runtime.executor)
    runtime.accept_task={resume=proc(_:rawptr)->async.Resume_Result{return .Waiting}}
    error=async.register(&runtime.executor,&runtime.accept_task)
    if !testing.expect_value(t,error.kind,.None) {return}
    testing.expect(t,claim_server(&control))
    defer release_server(&control)
    publish_server(&control,&runtime,{})
    testing.expect(t,server_ready(&control))
    async.shutdown(&runtime.executor)
    testing.expect(t,!server_ready(&control))
    testing.expect_value(t,server_state(&control),.Stopping)
    unpublish_server(&control)
    testing.expect_value(t,server_state(&control),.Stopping)
}
