package saba_core

import "core:log"
import "core:testing"
import "core:time"
import "core:thread"
import "core:sync"

@(test)
observability_disabled_has_no_counters_or_ids :: proc(t: ^testing.T) {
	runtime: Server_Runtime
	task := Connection_Task{runtime=&runtime}
	observe_start(&task)
	observe_finish(&task)
	testing.expect(t,!task.observed)
	testing.expect_value(t,task.event.request_id,u64(0))
	testing.expect_value(t,runtime.metrics.started,u64(0))
}

@(test)
observability_completes_once_and_hook_can_snapshot :: proc(t: ^testing.T) {
	State :: struct {control: ^Server_Control, called: int, valid: bool}
	runtime: Server_Runtime
	control := Server_Control{_server=&runtime}
	state := State{control=&control}
	runtime.config.observability = {
		enabled=true,
		data=&state,
		on_complete=proc(data:rawptr,event:^Request_Event) {
			state := cast(^State)data
			metrics, valid := server_metrics(state.control)
			state.called += 1
			state.valid = valid && metrics.completed == 1 && metrics.active == 0 &&
				event.request_id == 1 && event.method == "GET" && event.route == "/things/:id"
			stop_server(state.control)
		},
	}
	task := Connection_Task{runtime=&runtime,response_finished=true}
	observe_start(&task)
	task.request.method = "GET"
	task.request.route = "/things/:id"
	task.event.status = .OK
	task.event.bytes_received, task.event.bytes_sent = 12,34
	observe_finish(&task)
	observe_finish(&task)
	testing.expect_value(t,state.called,1)
	testing.expect(t,state.valid)
	testing.expect_value(t,runtime.metrics.started,u64(1))
	testing.expect_value(t,runtime.metrics.completed,u64(1))
	testing.expect_value(t,runtime.metrics.statuses[200],u64(1))
	testing.expect_value(t,runtime.metrics.bytes_received,u64(12))
	testing.expect_value(t,runtime.metrics.bytes_sent,u64(34))
	testing.expect(t,runtime.metrics.total_duration >= 0)
}

@(test)
observability_bounds_labels_and_preserves_failure_outcomes :: proc(t: ^testing.T) {
	runtime: Server_Runtime
	runtime.config.observability.enabled = true
	task := Connection_Task{runtime=&runtime,response_finished=true}
	observe_start(&task)
	task.request.method = "USER-SUPPLIED-SECRET"
	observe_io_error(&task,{kind=.Timeout})
	task.event.status = .Request_Timeout
	observe_finish(&task)
	testing.expect_value(t,runtime.metrics.timeouts,u64(1))
	testing.expect_value(t,runtime.metrics.errors,u64(1))
	testing.expect_value(t,event_method(task.request.method),"OTHER")
	request := Request{method="GET",path="/things/private-id",_observe=true}
	testing.expect(t,match_route(&request,"GET","/things/:id"))
	testing.expect_value(t,request.route,"/things/:id")
	request = {method="GET",path="/things/private-id"}
	testing.expect(t,match_route(&request,"GET","/things/:id"))
	testing.expect_value(t,request.route,"")
}

@(test)
timeouts_preserve_defaults_and_validate_overrides :: proc(t: ^testing.T) {
	defaults := resolve_timeouts({})
	testing.expect_value(t,defaults.header,5*time.Second)
	testing.expect_value(t,defaults.body,5*time.Second)
	testing.expect_value(t,defaults.large_body,30*time.Second)
	testing.expect_value(t,defaults.response,5*time.Second)
	testing.expect_value(t,defaults.idle,5*time.Second)
	testing.expect(t,timeouts_valid({}))
	testing.expect(t,!timeouts_valid({header=-1}))
	testing.expect(t,!timeouts_valid({response=MAX_SERVER_TIMEOUT+1}))
	custom := resolve_timeouts({header=time.Second,body=20*time.Millisecond,response=30*time.Millisecond,idle=40*time.Millisecond})
	testing.expect_value(t,custom.idle,40*time.Millisecond)
	testing.expect_value(t,body_timeout(custom,1),20*time.Millisecond)
	testing.expect_value(t,body_timeout(custom,REQUEST_BODY_LIMIT+1),20*time.Millisecond)
	testing.expect_value(t,resolve_timeouts({header=time.Second,idle=2*time.Second}).idle,time.Second)
	previous := context.logger
	context.logger = log.nil_logger()
	result := serve({handler=proc(_:rawptr,_: ^Connection,_:^Request)->Response{return {}},timeouts={header=-1}})
	context.logger = previous
	testing.expect(t,!result)
}

@(test)
observability_concurrent_snapshots_are_consistent :: proc(t: ^testing.T) {
	Worker :: struct {runtime: ^Server_Runtime, done: bool}
	runtime: Server_Runtime
	runtime.config.observability.enabled = true
	control := Server_Control{_server=&runtime}
	workers: [4]Worker
	threads: [4]^thread.Thread
	for &worker, i in workers {
		worker.runtime = &runtime
		threads[i] = thread.create_and_start_with_poly_data(&worker,proc(worker:^Worker) {
			for _ in 0..<1000 {
				task := Connection_Task{runtime=worker.runtime,response_finished=true}
				observe_start(&task)
				task.event.status = .OK
				observe_finish(&task)
			}
			sync.atomic_store(&worker.done,true)
		})
		testing.expect(t,threads[i] != nil)
	}
	for {
		metrics, valid := server_metrics(&control)
		testing.expect(t,valid)
		testing.expect(t,metrics.started >= metrics.completed)
		testing.expect_value(t,metrics.active,metrics.started-metrics.completed)
		all_done := true
		for &worker in workers do all_done = all_done && sync.atomic_load(&worker.done)
		if all_done do break
		thread.yield()
	}
	for worker in threads {thread.join(worker);thread.destroy(worker)}
	testing.expect_value(t,runtime.metrics.started,u64(4000))
	testing.expect_value(t,runtime.metrics.completed,u64(4000))
	testing.expect_value(t,runtime.metrics.active,u64(0))
	testing.expect_value(t,runtime.metrics.statuses[200],u64(4000))
}
