package saba_core

import rt "base:runtime"
import "core:mem"
import charged "core:mem/budget"
import "core:strings"
import "core:sync"
import budget "core:sync/budget"
import "core:time"
import async "shared:async"

DEFAULT_OPERATION_RESOURCES :: budget.Limits{32 * mem.Megabyte, 1, 1}
// H2 can own both a protocol stream lease and a response-producer lease.
DEFAULT_CONNECTION_RESOURCES :: budget.Limits{bytes=64 * mem.Megabyte, streams=64, jobs=4}
DEFAULT_SERVER_RESOURCES :: budget.Limits{bytes=256 * mem.Megabyte, streams=4096, jobs=128}

// Nil limits select finite defaults; explicit zero limits admit nothing. Parent
// is borrowed during startup; the server owns a child and never closes Parent.
Resource_Config :: struct {
	parent:                                             budget.Scope,
	operation_limits, connection_limits, global_limits: Maybe(budget.Limits),
}
server_resources :: proc(control: ^Server_Control) -> (budget.Snapshot, bool) {
	if control == nil do return {}, false
	sync.lock(&control._mutex); defer sync.unlock(&control._mutex)
	if control._server == nil do return {}, false
	view, error := budget.snapshot(control._server.resources)
	return view, error == .None
}
// Returned ownership survives runtime retirement. Release it explicitly.
retain_server_resources :: proc(control: ^Server_Control) -> (budget.Scope, bool) {
	if control == nil do return {}, false
	sync.lock(&control._mutex); defer sync.unlock(&control._mutex)
	if control._server == nil do return {}, false
	owner, error := budget.retain_scope(control._server.resources)
	return owner, error == .None
}
@(private)
initialize_resources :: proc(runtime: ^Server_Runtime) -> bool {
	config := runtime.config.resources
	runtime.operation_limits = DEFAULT_OPERATION_RESOURCES
	runtime.connection_limits = DEFAULT_CONNECTION_RESOURCES
	limits := DEFAULT_SERVER_RESOURCES
	if value, ok := config.operation_limits.?; ok do runtime.operation_limits = value
	if value, ok := config.connection_limits.?; ok do runtime.connection_limits = value
	if value, ok := config.global_limits.?; ok do limits = value
	error: budget.Error
	if budget.same_scope(config.parent, config.parent) {
		runtime.resources, error = budget.create_child(config.parent, limits)
	} else {
		runtime.resources, error = budget.create_root(limits)
	}
	if error != .None do return false
	view, snapshot_error := budget.snapshot(runtime.resources)
	if snapshot_error != .None || view.depth > budget.MAX_DEPTH - 2 {
		budget.release_scope(&runtime.resources); return false
	}
	return true
}
@(private)
start_connection_resources :: proc(task: ^Connection_Task) -> bool {
	if !budget.same_scope(task.runtime.resources, task.runtime.resources) do return true
	owner, error := budget.create_child(task.runtime.resources, task.runtime.connection_limits)
	if error != .None do return false
	task.resource_connection = owner
	return start_operation_resources(task)
}
@(private)
start_operation_resources :: proc(task: ^Connection_Task) -> bool {
	if !budget.same_scope(task.resource_connection, task.resource_connection) do return true
	owner, error := budget.create_child(task.resource_connection, task.runtime.operation_limits)
	if error != .None do return false
	binding, binding_error := charged.create(owner)
	if binding_error.kind != .None {
		budget.release_scope(&owner); return false
	}
	task.resource_operation, task.resource_binding = owner, binding
	return true
}
@(private)
finish_operation_resources :: proc(task: ^Connection_Task) {
	if budget.same_scope(task.resource_operation, task.resource_operation) {
		_ = budget.close(task.resource_operation)
	}
	charged.release(&task.resource_binding)
	budget.release_scope(&task.resource_operation)
}
@(private)
resource_pressure :: proc(task: ^Connection_Task) -> bool {
	return charged.stats(task.resource_binding).rejected != 0
}
// Fixed task storage remains usable after payload admission is exhausted.
@(private)
resource_reject :: proc(
	task: ^Connection_Task,
	status: HTTP_Status = .Service_Unavailable,
) -> bool {
 if task.http2_request!=nil {return h2_request_emergency(task,status)}
	head, encoded := response_headers({status = status}, task.resource_emergency[:])
	if !encoded do return false
	task.output = {head, nil, nil}
	task.output_index, task.output_offset = 0, 0
	task.reuse_after_write, task.finish_after_write = false, true
	task.deadline = async.deadline_after(&task.runtime.executor, task.runtime.timeouts.response)
	task.connection.write_deadline = time.tick_add(time.tick_now(), task.runtime.timeouts.response)
	task.phase = .Write
	if task.observed {
		task.event.status = status
		task.event.outcome = .Timeout if status == .Request_Timeout else .Allocation_Error
	}
	return true
}
// Unknown raw borrows have no full-allocation provenance. Copy before suspension.
@(private)
resource_copy_response :: proc(task: ^Connection_Task, response: ^Response) -> bool {
 if len(response.trailers)>0 && task.request.version!="HTTP/3" {return false}
	if !budget.same_scope(task.resource_operation, task.resource_operation) do return true
	allocator := mem.dynamic_arena_allocator(&task.arena)
	body := response.body
	// HEAD only needs the representation length while encoding its head.
	if task.request.method != "HEAD" {
		storage, error := make([]u8, len(body), allocator)
		if error != nil do return false
		copy(storage, body); body = storage
	}
	headers, he := make([]Header, len(response.headers), allocator)
	if he != nil do return false
	for field, i in response.headers {
		name, ne := strings.clone(field.name, allocator)
		value, ve := strings.clone(field.value, allocator)
		if ne != nil || ve != nil do return false
		headers[i] = {name, value}
	}
 trailers,trailer_error:=make([]Header,len(response.trailers),allocator)
 if trailer_error!=nil {return false}
 for field,i in response.trailers {
  name,name_error:=strings.clone(field.name,allocator);value,value_error:=strings.clone(field.value,allocator)
  if name_error!=nil || value_error!=nil {return false};trailers[i]={name,value}
 }
 response.trailers=trailers
	response.body, response.headers = body, headers
	return true
}
@(private)
connection_storage_allocator :: proc(task: ^Connection_Task) -> mem.Allocator {
	if !budget.same_scope(task.resource_connection, task.resource_connection) {
		return rt.heap_allocator()
	}
	allocator := charged.allocator(task.resource_transport)
	if allocator.procedure == nil {
		binding, error := charged.create(task.resource_connection)
		if error.kind != .None do return {}
		task.resource_transport = binding; allocator = charged.allocator(binding)
	}
	return allocator
}

@(private)
resource_failure_status :: proc(status: HTTP_Status) -> HTTP_Status {
	if status == .Request_Timeout || status == .Content_Too_Large do return status
	return .Service_Unavailable
}
