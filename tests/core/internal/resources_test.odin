package saba_core

import exchange "../../http/exchange"
import rt "base:runtime"
import "core:mem"
import charged "core:mem/budget"
import owned "core:mem/owned"
import "core:strings"
import budget "core:sync/budget"
import "core:testing"
import async "shared:async"

Resource_Test :: struct {
	runtime: Server_Runtime,
	task:    Connection_Task,
}
resource_test_init :: proc(fixture: ^Resource_Test, config: Resource_Config = {}) {
	fixture.runtime.config.resources = config
	fixture.runtime.timeouts = resolve_timeouts({})
	assert(initialize_resources(&fixture.runtime))
	assert(async.init(&fixture.runtime.executor, {workers = 1, task_capacity = 1, io_capacity = 1}).kind == .None)
	fixture.task.runtime = &fixture.runtime
	fixture.task.phase = .Dispatch
	assert(start_connection_resources(&fixture.task))
	init_connection_arena(&fixture.task)
	fixture.task.request = {
		allocator         = mem.dynamic_arena_allocator(&fixture.task.arena),
		resources         = fixture.task.resource_operation,
		backing_allocator = charged.allocator(fixture.task.resource_binding),
		method            = "GET",
	}

	assert(begin_request_context(&fixture.task))
}
resource_test_finish :: proc(fixture: ^Resource_Test) {
	finish_request_context(&fixture.task)
	drop_deferred(&fixture.task)
	drop_response_stream(&fixture.task)
	drop_upgrade(&fixture.task)
	mem.dynamic_arena_destroy(&fixture.task.arena)
	finish_operation_resources(&fixture.task)
	charged.release(&fixture.task.resource_transport)
	_ = budget.close(fixture.task.resource_connection)
	budget.release_scope(&fixture.task.resource_connection)
	assert(async.destroy(&fixture.runtime.executor).kind == .None)
	budget.release_scope(&fixture.runtime.resources)
}

@(test)
zero_byte_allowance_uses_fixed_503_storage_and_no_payload_allocation :: proc(t: ^testing.T) {
	fixture: Resource_Test
	resource_test_init(&fixture, {operation_limits = budget.Limits{0, 1, 1}})
	defer resource_test_finish(&fixture)
	before, error := budget.snapshot(fixture.runtime.resources)
	assert(error == .None)
	testing.expect_value(t, before.used.bytes, u64(0))
	assert(queue_response(&fixture.task, {status = .OK, body = []u8{42}}))
	testing.expect(t, strings.contains(string(fixture.task.output[0]), "503 Service Unavailable"))
	testing.expect(t, raw_data(fixture.task.output[0]) == raw_data(fixture.task.resource_emergency[:]))
	after, result := budget.snapshot(fixture.runtime.resources)
	assert(result == .None)
	testing.expect_value(t, after.used.bytes, u64(0))
	testing.expect(t, after.rejected > 0)
	testing.expect(t, fixture.task.finish_after_write && !fixture.task.reuse_after_write)
}

@(test)
charged_backing_and_late_context_survive_operation_retirement :: proc(t: ^testing.T) {
	fixture: Resource_Test
	resource_test_init(&fixture)
	defer resource_test_finish(&fixture)
	_, error := make([]u8, 1, fixture.task.request.allocator)
	assert(error == nil)
	view, ve := budget.snapshot(fixture.runtime.resources)
	assert(ve == .None)
	testing.expect(t, view.used.bytes >= 16 * mem.Kilobyte)
	retained, ok := retain_request_context(fixture.task.request.cancellation)
	assert(ok)
	job_binding, created := charged.create(request_resources(retained))
	assert(created.kind == .None)
	data, allocated := charged.allocate(job_binding, 1024)
	assert(allocated.kind == .None)
	job, accepted := budget.reserve(request_resources(retained), {jobs = 1}, .Running)
	assert(accepted == .None)
	finish_request_context(&fixture.task)
	mem.dynamic_arena_destroy(&fixture.task.arena)
	finish_operation_resources(&fixture.task)
	late, le := budget.snapshot(fixture.runtime.resources)
	assert(le == .None)
	testing.expect(t, late.used.bytes > 1024 && late.used.jobs == 1 && late.used.running == 1)
	testing.expect_value(t, request_context_status(retained), .Failed)
	_, denied := charged.allocate(job_binding, 1)
	testing.expect_value(t, denied.kind, .Budget_Rejected)
	testing.expect_value(t, denied.budget, .Closed)
	assert(budget.set_job_phase(&job, .Held) == .None)
	held, he := budget.snapshot(fixture.runtime.resources)
	assert(he == .None)
	testing.expect_value(t, held.used.bytes, late.used.bytes)
	testing.expect_value(t, held.used.jobs, u64(1))
	testing.expect_value(t, held.used.held, u64(1))
	assert(start_operation_resources(&fixture.task))
	init_connection_arena(&fixture.task)
	new_view, ne := budget.snapshot(fixture.task.resource_operation)
	assert(ne == .None)
	testing.expect_value(t, new_view.used.bytes, u64(0))
	testing.expect_value(t, new_view.used.jobs, u64(0))
	testing.expect_value(t, charged.deallocate(job_binding, raw_data(data)).kind, .None)
	charged.release(&job_binding)
	budget.release(&job)
	release_request_context(&retained)
	recovered, re := budget.snapshot(fixture.runtime.resources)
	assert(re == .None)
	testing.expect_value(t, recovered.used, budget.Usage{})
	testing.expect_value(t, recovered.scope_nodes, u64(3))
}

@(test)
server_scope_closure_does_not_close_the_injected_global_parent :: proc(t: ^testing.T) {
	parent, error := budget.create_root({128 * mem.Kilobyte, 2, 2})
	assert(error == .None)
	defer budget.release_scope(&parent)
	fixture: Resource_Test
	resource_test_init(&fixture, {parent = parent})
	assert(budget.close(fixture.runtime.resources) == .None)
	view, result := budget.snapshot(parent)
	assert(result == .None)
	testing.expect(t, !view.closed)
	lease, admitted := budget.reserve(parent, {bytes = 1})
	assert(admitted == .None)
	budget.release(&lease)
	resource_test_finish(&fixture)
	final, final_error := budget.snapshot(parent)
	assert(final_error == .None)
	testing.expect_value(t, final.used, budget.Usage{})
	testing.expect_value(t, final.scope_nodes, u64(1))
}

@(test)
legacy_stream_submit_remains_assignable_to_the_original_procedure_type :: proc(t: ^testing.T) {
	legacy: proc(_: ^Stream_IO, _: ^owned.Chunk) -> exchange.Submit_Result = stream_submit
	testing.expect_value(t, legacy(nil, nil), .Invalid)
}

@(test)
emergency_rejection_preserves_known_timeout_and_body_policy_status :: proc(t: ^testing.T) {
	for status in ([]HTTP_Status{.Request_Timeout, .Content_Too_Large}) {
		fixture: Resource_Test
		resource_test_init(&fixture, {operation_limits = budget.Limits{0, 1, 1}})
		assert(queue_response(&fixture.task, {status = status}))
		expected := "408 Request Timeout" if status == .Request_Timeout else "413 Content Too Large"
		testing.expect(t, strings.contains(string(fixture.task.output[0]), expected))
		view, error := budget.snapshot(fixture.runtime.resources)
		assert(error == .None)
		testing.expect_value(t, view.used.bytes, u64(0))
		resource_test_finish(&fixture)
	}
}
resource_deferred_failure :: proc(data: rawptr, io: ^Deferred_IO) -> (Response, Deferred_Step) {
	source := cast(^Deferred_Source)data
	source.calls^ += 1
	_, error := make([]u8, mem.Megabyte, io.allocator)
	assert(error != nil)

	return {}, .Failed
}

@(test)
deferred_build_budget_failure_emits_fixed_503_and_drops_once :: proc(t: ^testing.T) {
	fixture: Resource_Test
	resource_test_init(&fixture, {operation_limits = budget.Limits{32 * mem.Kilobyte, 1, 1}})
	defer resource_test_finish(&fixture)
	calls, drops: int
	source := new(Deferred_Source, rt.heap_allocator())
	source^ = {
		calls = &calls,
		drops = &drops,
	}

	assert(
		queue_response(
			&fixture.task,
			{deferred = {data = source, poll = resource_deferred_failure, drop = deferred_drop}},
		),
	)
	testing.expect_value(t, await_response(&fixture.task), .Yield)
	testing.expect_value(t, fixture.task.phase, .Write)
	testing.expect(t, strings.contains(string(fixture.task.output[0]), "503 Service Unavailable"))
	testing.expect_value(t, calls, 1)
	testing.expect_value(t, drops, 1)
	drop_deferred(&fixture.task)
	testing.expect_value(t, drops, 1)
}

@(test)
review_head_large_host_body_does_not_need_retention :: proc(t: ^testing.T) {
	fixture: Resource_Test
	resource_test_init(&fixture, {operation_limits = budget.Limits{32 * mem.Kilobyte, 1, 1}})
	defer resource_test_finish(&fixture)
	fixture.task.request.method = "HEAD"
	body := make([]u8, 64 * mem.Kilobyte, rt.heap_allocator())
	defer delete(body, rt.heap_allocator())
	assert(queue_response(&fixture.task, {status = .OK, body = body}))
	testing.expectf(
		t,
		strings.contains(string(fixture.task.output[0]), "200 OK"),
		"HEAD retains unsent body: %s",
		string(fixture.task.output[0]),
	)
	testing.expect_value(t, len(fixture.task.output[1]), 0)
	testing.expect(t, strings.contains(string(fixture.task.output[0]), "Content-Length: 65536"))
}

@(test)
review_chunk_decoder_budget_reject_uses_fixed_503 :: proc(t: ^testing.T) {
	fixture: Resource_Test
	resource_test_init(&fixture, {operation_limits = budget.Limits{32 * mem.Kilobyte, 1, 1}})
	defer resource_test_finish(&fixture)
	finish_request_context(&fixture.task)
	raw: [8192]u8
	used := copy(raw[:], "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n")

	for _ in 0 ..< 100 {
		used += copy(raw[used:], "X-Test: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\n")
	}

	used += copy(raw[used:], "\r\n")
	fixture.task.header = fixture.task.initial_header[:]

	for size in ([4]int{1024, 2048, 4096, 8192}) {
		buffer, error := make([]u8, size, mem.dynamic_arena_allocator(&fixture.task.arena))
		assert(error == nil)
		fixture.task.header = buffer
	}

	copy(fixture.task.header, raw[:used])
	fixture.task.header_used = used
	fixture.task.phase = .Headers
	queued := prepare_request(&fixture.task)
	testing.expectf(
		t,
		queued && strings.contains(string(fixture.task.output[0]), "503 Service Unavailable"),
		"decoder pressure closes without fixed response: queued=%v phase=%v",
		queued,
		fixture.task.phase,
	)
}

Review_KA_Pressure :: struct {
	binding:   charged.Binding,
	busy:      []u8,
	busy_size: int,
	armed:     bool,
}
review_ka_metadata :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> (
	[]u8,
	mem.Allocator_Error,
) {
	state := cast(^Review_KA_Pressure)data
	if mode == .Free && state.armed {
		state.armed = false
		allocated, error := charged.allocate(state.binding, state.busy_size)
		assert(error.kind == .None)
		state.busy = allocated
	}
	backing := rt.heap_allocator()
	return backing.procedure(backing.data, mode, size, alignment, old_memory, old_size, location)
}

@(test)
review_keepalive_prefetch_growth_pressure_uses_fixed_503 :: proc(t: ^testing.T) {
	state: Review_KA_Pressure
	parent, error := budget.create_root({64 * mem.Kilobyte, 2, 2}, {review_ka_metadata, &state})
	assert(error == .None)
	binding, created := charged.create(parent)
	assert(created.kind == .None)
	state.binding = binding
	one, computed := charged.allocation_cost(1, mem.DEFAULT_ALIGNMENT)
	assert(computed.kind == .None)
	state.busy_size = 64 * mem.Kilobyte - int(one) + 1
	fixture: Resource_Test
	resource_test_init(&fixture, {parent = parent})
	fixture.runtime.config.keep_alive.enabled = true
	next, allocated := make([]u8, 700, fixture.task.request.allocator)
	assert(allocated == nil)
	prefix := copy(next, "GET /next HTTP/1.1\r\nHost: x\r\nX-Pad: ")
	for i in prefix ..< len(next) - 4 do next[i] = 'a'
	copy(next[len(next) - 4:], "\r\n\r\n")
	fixture.task.connection.read_buffer = next
	assert(queue_response(&fixture.task, {status = .OK}))
	fixture.task.response_finished = true
	fixture.task.requests_completed = 1
	state.armed = true
	// Another application operation takes global credits exactly after the old
	// operation retires, before this valid pipelined head needs a fresh block.
	queued := keep_alive_next_request(&fixture.task)
	testing.expectf(
		t,
		queued && strings.contains(string(fixture.task.output[0]), "503 Service Unavailable"),
		"prefetch pressure closes without fixed response: queued=%v",
		queued,
	)
	resource_test_finish(&fixture)
	assert(charged.deallocate(binding, raw_data(state.busy)).kind == .None)
	charged.release(&binding)
	budget.release_scope(&parent)
}

@(test)
connection_scope_is_observable_and_has_independent_admission :: proc(t: ^testing.T) {
	fixture: Resource_Test
	resource_test_init(&fixture, {connection_limits = budget.Limits{512 * mem.Kilobyte, 1, 4}})
	retained, ok := retain_request_context(fixture.task.request.cancellation)
	assert(ok)
	connection := request_connection_resources(retained)
	view, error := budget.snapshot(connection)
	assert(error == .None)
	testing.expect_value(t, view.limits.bytes, u64(512 * mem.Kilobyte))
	_, denied := budget.reserve(fixture.task.resource_operation, {bytes = mem.Megabyte})
	testing.expect_value(t, denied, .Limit_Exceeded)
	op, oe := budget.snapshot(fixture.task.resource_operation)
	assert(oe == .None)
	global, ge := budget.snapshot(fixture.runtime.resources)
	assert(ge == .None)
	testing.expect_value(t, op.used, budget.Usage{})
	testing.expect_value(t, global.used, budget.Usage{})
	resource_test_finish(&fixture)
	late, le := budget.snapshot(request_connection_resources(retained))
	assert(le == .None)
	testing.expect(t, late.closed)
	testing.expect_value(t, late.used, budget.Usage{})
	release_request_context(&retained)
}

Review_KA_Metadata_Failure :: struct {
	armed: bool,
}
review_ka_fail_metadata :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> (
	[]u8,
	mem.Allocator_Error,
) {
	state := cast(^Review_KA_Metadata_Failure)data
	if state.armed && (mode == .Alloc || mode == .Resize) do return nil, .Out_Of_Memory
	backing := rt.heap_allocator()
	return backing.procedure(backing.data, mode, size, alignment, old_memory, old_size, location)
}
@(test)
review_keepalive_operation_create_failure_balances_observation :: proc(t: ^testing.T) {
	state: Review_KA_Metadata_Failure
	parent, error := budget.create_root({1024 * mem.Kilobyte, 2, 2}, {review_ka_fail_metadata, &state})
	assert(error == .None)
	defer budget.release_scope(&parent)
	fixture: Resource_Test
	resource_test_init(&fixture, {parent = parent})
	defer resource_test_finish(&fixture)
	fixture.runtime.config.keep_alive.enabled = true
	fixture.runtime.config.observability.enabled = true
	observe_start(&fixture.task)
	next, allocation_error := make([]u8, 32, fixture.task.request.allocator)
	assert(allocation_error == nil)
	count := copy(next, "GET /next HTTP/1.1\r\nHost: x\r\n\r\n")
	fixture.task.connection.read_buffer = next[:count]
	assert(queue_response(&fixture.task, {status = .OK}))
	fixture.task.response_finished = true
	fixture.task.requests_completed = 1
	state.armed = true
	assert(keep_alive_next_request(&fixture.task))
	testing.expect(t, strings.contains(string(fixture.task.output[0]), "503 Service Unavailable"))
	fixture.task.response_finished = true
	observe_finish(&fixture.task)
	testing.expect_value(t, fixture.runtime.metrics.started, u64(2))
	testing.expect_value(t, fixture.runtime.metrics.completed, u64(2))
	testing.expect_value(t, fixture.runtime.metrics.active, u64(0))
}
