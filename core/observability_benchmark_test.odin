package saba_core

import "core:fmt"
import "core:testing"
import "core:time"

// Disabled benchmarks still need file imports to be referenced under strict vet.
@(private)
observability_benchmark_imports :: proc() {
	_ = fmt.printf
	_ = testing.expect
	_ = time.tick_now
}

when #config(SABA_OBSERVABILITY_BENCHMARK, false) {
// Explicitly select this benchmark; no network/provider state is involved.
@(test)
observability_overhead_benchmark :: proc(t: ^testing.T) {
	iterations :: 100000
	fmt.printf("observability state bytes: metrics=%d event=%d task=%d\n",size_of(Request_Metrics),size_of(Request_Event),size_of(Connection_Task))
	for mode in 0..<3 {
		runtime: Server_Runtime
		calls: u64
		if mode > 0 do runtime.config.observability.enabled = true
		if mode == 2 {
			runtime.config.observability.data = &calls
			runtime.config.observability.on_complete = proc(data:rawptr,_:^Request_Event) {counter:=cast(^u64)data;counter^ += 1}
		}
		task := Connection_Task{runtime=&runtime,response_finished=true}
		task.request.method = "GET"
		start := time.tick_now()
		for _ in 0..<iterations {
			task.observed, task.observation_finished = false,false
			observe_start(&task)
			observe_finish(&task)
		}
		ns := f64(time.tick_diff(start,time.tick_now())) / f64(iterations)
		fmt.printf("observability benchmark mode=%d iterations=%d ns_per_attempt=%.2f\n",mode,iterations,ns)
		if mode == 0 do testing.expect_value(t,runtime.metrics.completed,u64(0))
		else do testing.expect_value(t,runtime.metrics.completed,u64(iterations))
		if mode == 2 do testing.expect_value(t,calls,u64(iterations))
	}
}

}
