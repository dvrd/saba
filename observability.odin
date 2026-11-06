package server

import "core:sync"
import "core:time"

import async "shared:async"

MAX_EVENT_ROUTE_BYTES :: 128

Request_Outcome :: enum {
	Completed,
	Timeout,
	Cancelled,
	Peer_Closed,
	IO_Error,
	Allocation_Error,
	Protocol_Error,
}

// Callback strings borrow request-owned/static data only until return. Route is
// a bounded matched template, never the raw path/query; unknown methods are OTHER.
Request_Event :: struct {
	request_id: u64,
	method, route: string,
	status: HTTP_Status,
	duration: time.Duration,
	bytes_received, bytes_sent: u64,
	outcome: Request_Outcome,
}

// Keep data and callback state alive until serve returns. The synchronous hook
// runs on the finishing worker, once per HTTP attempt (101 completes on upgrade),
// before request storage is released and outside internal locks. Different
// requests may call it concurrently. Copy any retained event/strings. It may
// query snapshots or request stop/drain, but must not block or call serve again.
Observability_Config :: struct {
	enabled: bool,
	on_complete: proc(data: rawptr, event: ^Request_Event),
	data: rawptr,
}

Request_Metrics :: struct {
	started, completed, active: u64,
	bytes_received, bytes_sent: u64,
	timeouts, cancelled, errors: u64,
	// Index 0 means no HTTP status was prepared; other indices are wire codes.
	statuses: [600]u64,
	total_duration: time.Duration,
}

// Snapshots never invoke observers or expose runtime pointers. False means the
// server is not published. Disabled observations return a zero snapshot.
server_metrics :: proc(control: ^Server_Control) -> (Request_Metrics, bool) {
	if control == nil do return {}, false
	sync.lock(&control._mutex)
	defer sync.unlock(&control._mutex)
	runtime := control._server
	if runtime == nil do return {}, false
	sync.lock(&runtime.observability_mutex)
	defer sync.unlock(&runtime.observability_mutex)
	return runtime.metrics, true
}

@(private)
observability_enabled :: proc(config: Observability_Config) -> bool {
	return config.enabled || config.on_complete != nil
}

@(private)
observe_start :: proc(task: ^Connection_Task) {
	if !observability_enabled(task.runtime.config.observability) do return
	task.observed = true
	task.observed_at = time.tick_now()
	sync.lock(&task.runtime.observability_mutex)
	task.runtime.next_request_id += 1
	task.event.request_id = task.runtime.next_request_id
	task.runtime.metrics.started += 1
	task.runtime.metrics.active += 1
	sync.unlock(&task.runtime.observability_mutex)
}

@(private)
observe_io_error :: proc(task: ^Connection_Task, error: async.Error) {
	if !task.observed do return
	#partial switch error.kind {
	case .None, .Pending: return
	case .Timeout: task.event.outcome = .Timeout
	case .Cancelled, .Stopping: task.event.outcome = .Cancelled
	case .Peer_Closed: task.event.outcome = .Peer_Closed
	case: task.event.outcome = .IO_Error
	}
}

@(private)
event_method :: proc(method: string) -> string {
	switch method {
	case "GET", "POST", "HEAD", "PUT", "DELETE", "PATCH", "OPTIONS", "CONNECT", "TRACE": return method
	}
	return "OTHER"
}

@(private)
observe_finish :: proc(task: ^Connection_Task) {
	if !task.observed || task.observation_finished do return
	task.observation_finished = true
	event := task.event
	event.method = event_method(task.request.method)
	if len(task.request.route) <= MAX_EVENT_ROUTE_BYTES do event.route = task.request.route
	event.duration = time.tick_diff(task.observed_at, time.tick_now())
	if !task.response_finished && async.cancelled(&task.task) && event.outcome == .Completed do event.outcome = .Cancelled
	if !task.response_finished && event.outcome == .Completed do event.outcome = .IO_Error
	runtime := task.runtime
	sync.lock(&runtime.observability_mutex)
	metrics := &runtime.metrics
	metrics.completed += 1
	metrics.active -= 1
	metrics.bytes_received += event.bytes_received
	metrics.bytes_sent += event.bytes_sent
	metrics.total_duration += min(event.duration, time.Duration(max(i64)) - metrics.total_duration)
	if event.outcome == .Timeout do metrics.timeouts += 1
	if event.outcome == .Cancelled do metrics.cancelled += 1
	if event.outcome != .Completed do metrics.errors += 1
	if int(event.status) >= 0 && int(event.status) < len(metrics.statuses) do metrics.statuses[int(event.status)] += 1
	sync.unlock(&runtime.observability_mutex)
	callback := runtime.config.observability.on_complete
	if callback != nil do callback(runtime.config.observability.data, &event)
}

@(private)
observe_failure :: proc(task: ^Connection_Task, outcome: Request_Outcome) {
	if task.observed do task.event.outcome = outcome
}
