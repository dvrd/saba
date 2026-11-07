package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:sync"
import "core:thread"
import "core:time"
import server "shared:saba/core"

State :: struct {
	control:      server.Server_Control,
	mutex:        sync.Mutex,
	contexts:     [8]server.Request_Context,
	count, drops: int,
	result:       bool,
}

retain :: proc(state: ^State, request: ^server.Request) -> int {
	owned, ok := server.retain_request_context(request.cancellation); assert(ok)
	sync.lock(&state.mutex); defer sync.unlock(&state.mutex)
	assert(state.count < len(state.contexts))
	index := state.count; state.count += 1; state.contexts[index] = owned
	return index
}

drop :: proc(data: rawptr) {state := cast(^State)data; sync.atomic_add(&state.drops, 1)}

route :: proc(data: rawptr, _: ^server.Connection, request: ^server.Request) -> server.Response {
	state := cast(^State)data
	if request.path == "/status" {
		sync.lock(&state.mutex); defer sync.unlock(&state.mutex)
		text := fmt.aprintf("%d", sync.atomic_load(&state.drops), allocator = request.allocator)
		for owner in state.contexts[:state.count] {
			text = fmt.aprintf(
				"%s %v",
				text,
				server.request_context_status(owner),
				allocator = request.allocator,
			)
		}
		return server.make_response(request, .OK, nil, transmute([]u8)text)
	}
	if request.path == "/hold" {
		index := retain(state, request)
		return server.make_response(
			request,
			.OK,
			nil,
			transmute([]u8)fmt.aprintf("%d", index, allocator = request.allocator),
		)
	}
	if request.path == "/late" {
		retain(state, request)
		time.sleep(100 * time.Millisecond)
		return {status = .OK, upgrade = {data = state, drop = drop}}
	}
	if request.path == "/cooperate" {
		retain(state, request)
		fmt.println("working"); os.flush(os.stdout)
		for !server.request_cancelled(request.cancellation) {time.sleep(time.Millisecond)}
		return {status = .OK, upgrade = {data = state, drop = drop}}
	}
	if request.path == "/peer" {
		retain(state, request)
		body := make([]u8, 4 * 1024 * 1024, request.allocator)
		for &byte in body do byte = 42
		return server.make_response(request, .OK, nil, body)
	}
	return server.make_response(request, .OK, nil, transmute([]u8)string("ok"))
}

main :: proc() {
	state: State
	budget, _ := strconv.parse_int(os.get_env("SABA_CANCEL_BUDGET_MS", context.temp_allocator))
	worker := thread.create_and_start_with_poly_data(struct {
		state:  ^State,
		budget: int,
	}{&state, budget}, proc(input: struct {
			state:  ^State,
			budget: int,
		}) {
		input.state.result = server.serve(
			{
				port = 0,
				workers = 1,
				handler = route,
				handler_data = input.state,
				control = &input.state.control,
				handler_timeout = time.Duration(input.budget) * time.Millisecond,
				keep_alive = {enabled = true},
				timeouts = {response = time.Second},
			},
		)
	})
	assert(worker != nil)
	for _ in 0 ..< 5000 {
		endpoint, ready := server.server_endpoint(&state.control)
		if ready {
			fmt.printf("ready %d\n", endpoint.port); os.flush(os.stdout); break
		}
		time.sleep(time.Millisecond)
	}
	_, ready := server.server_endpoint(&state.control); assert(ready)
	command: [1]u8; os.read(os.stdin, command[:])
	if command[0] == 'd' {
		assert(server.drain_server(&state.control, 50 * time.Millisecond))
	} else {
		server.stop_server(&state.control)
	}
	thread.join(worker); thread.destroy(worker); assert(state.result)
	fmt.printf("stopped %d", sync.atomic_load(&state.drops))
	for &owner in state.contexts[:state.count] {
		fmt.printf(" %v", server.request_context_status(owner))
		server.release_request_context(&owner); server.release_request_context(&owner)
	}
	fmt.println(); os.flush(os.stdout)
}
