package main

import rt "base:runtime"
import "core:fmt"
import owned "shared:async/mem/owned"
import "core:os"
import "core:strconv"
import "core:sync"
import "core:thread"
import "core:time"
import async "shared:async"
import server "shared:saba/core"

State :: struct {
	control:                                           server.Server_Control,
	result:                                            bool,
	next_id, active, live, allocated, released, drops: int,
}
Mode :: enum {
	Normal,
	Error,
	Short,
	Long,
	Wait,
	Stall,
	Backpressure,
	Overlimit,
	Badwait,
}
Producer :: struct {
	state:                                                   ^State,
	id, sequence, count, size, allocations, releases, calls: int,
	offset:                                                  int,
	mode:                                                    Mode,
	pending:                                                 owned.Chunk,
	next_at:                                                 async.Deadline,
}

release_bytes :: proc(storage: []u8, data: rawptr) {
	producer := cast(^Producer)data
	producer.releases += 1
	sync.atomic_add(&producer.state.released, 1)
	sync.atomic_sub(&producer.state.live, len(storage))
	delete(storage, rt.heap_allocator())
}

next :: proc(data: rawptr, io: ^server.Stream_IO) -> server.Stream_Step {
	producer := cast(^Producer)data
	producer.calls += 1
	assert(producer.releases == producer.allocations, "driver polled while a chunk was still borrowed")
	if server.request_cancelled(io.cancellation) {
		return .Failed
	}
	if producer.mode == .Badwait {
		return .Waiting
	}

	if producer.mode == .Stall {
		err := server.stream_wait(io, async.deadline_after(io.runtime, 10 * time.Second))
		return .Waiting if err.kind == .Pending else .Failed
	}

	if producer.mode == .Error && producer.sequence == 1 {
		return .Failed
	}
	if producer.sequence == producer.count {
		return .Done
	}

	if producer.mode == .Wait {
		if producer.next_at.at == 0 {
			producer.next_at = async.deadline_after(io.runtime, 50 * time.Millisecond)
		}
		error := server.stream_wait(io, producer.next_at)
		if error.kind == .Pending {
			return .Waiting
		}
		if error.kind != .None {
			return .Failed
		}
		producer.next_at = {}
	}

	grant := producer.size
	if producer.mode == .Backpressure {
		grant = 32768
	}
	storage, error := make([]u8, grant, rt.heap_allocator())
	if error != nil {
		return .Failed
	}
	for &byte, i in storage {
		byte = u8((producer.offset + i) % 251)
	}
	producer.allocations += 1
	sync.atomic_add(&producer.state.allocated, 1)
	sync.atomic_add(&producer.state.live, grant)
	producer.pending, _ = owned.take_custom(&storage, producer.size, release_bytes, producer)
	result := server.stream_submit(io, &producer.pending, {release_frees_storage = true})

	if result != .Accepted {
		assert(producer.pending.release != nil, "rejection destroyed producer ownership")
		return .Failed
	}

	assert(producer.pending.release == nil)
	producer.sequence += 1
	producer.offset += producer.size

	return .Chunk
}

drop :: proc(data: rawptr) {
	producer := cast(^Producer)data
	owned.destroy(&producer.pending)
	assert(producer.allocations == producer.releases)
	sync.atomic_sub(&producer.state.active, 1)
	sync.atomic_add(&producer.state.drops, 1)
	fmt.printf("drop %d %d %d %d\n", producer.id, producer.calls, producer.allocations, producer.releases)
	os.flush(os.stdout)
	free(producer, rt.heap_allocator())
}

route :: proc(data: rawptr, _: ^server.Connection, request: ^server.Request) -> server.Response {
	state := cast(^State)data

	if request.path == "/stats" {
		// Materialize private storage before fmt packs borrowed any arguments.
		snapshot: [5]int
		snapshot[0] = sync.atomic_load(&state.active)
		snapshot[1] = sync.atomic_load(&state.live)
		snapshot[2] = sync.atomic_load(&state.allocated)
		snapshot[3] = sync.atomic_load(&state.released)
		snapshot[4] = sync.atomic_load(&state.drops)
		body := fmt.aprintf(
			"%d %d %d %d %d",
			snapshot[0],
			snapshot[1],
			snapshot[2],
			snapshot[3],
			snapshot[4],
			allocator = request.allocator,
		)
		return server.make_response(request, .OK, nil, transmute([]u8)body)
	}

	if request.path == "/fast" {
		return server.make_response(request, .OK, nil, transmute([]u8)string("ok"))
	}
	producer, error := new(Producer, rt.heap_allocator())
	if error != nil {
		return {status = .Internal_Server_Error}
	}
	producer^ = {
		state = state,
		id    = sync.atomic_add(&state.next_id, 1) + 1,
		count = 3,
		size  = 2048,
	}

	sync.atomic_add(&state.active, 1)
	length: i64 = -1
	timeout := 3 * time.Second
	max_body: i64 = 8 * 1024 * 1024
	status: server.HTTP_Status = .OK

	switch request.path {
	case "/known":
		length = 6144
	case "/large":
		producer.count = 512
		producer.size = 16384
		length = 8 * 1024 * 1024
	case "/error":
		producer.mode = .Error
		producer.size = 3
	case "/short":
		producer.count = 1
		producer.size = 3
		length = 6
	case "/long":
		producer.count = 1
		producer.size = 3
		length = 2
	case "/wait":
		producer.mode = .Wait
		producer.count = 4
		producer.size = 3
	case "/stall":
		producer.mode = .Stall
		timeout = 100 * time.Millisecond
	case "/backpressure":
		producer.mode = .Backpressure
		producer.size = 1
	case "/overlimit":
		producer.mode = .Overlimit
		producer.size = 3
		max_body = 3
	case "/badwait":
		producer.mode = .Badwait
	case "/nobody":
		status = .No_Content
		length = 0
	case "/empty":
		length = 0
		producer.count = 0
	case "/slow":
		producer.count = 65536
		producer.size = 16384
		max_body = 1024 * 1024 * 1024
	}

	response := server.make_response(
		request,
		status,
		{{"X-Stream-ID", fmt.aprintf("%d", producer.id, allocator = request.allocator)}},
	)
	if request.path == "/badhead" {
		response = server.make_response(request, status, {{"Content-Length", "1"}}) // rejected before wire output
	}

	if request.path == "/mix" {
		response.body = make([]u8, 1, request.allocator)
		response.body[0] = 42
	}

	response.stream = {
		data            = producer,
		next            = next,
		drop            = drop,
		content_length  = length,
		max_chunk_bytes = 16384,
		max_body_bytes  = max_body,
		timeout         = timeout,
	}

	return response
}

main :: proc() {
	state: State
	worker := thread.create_and_start_with_poly_data(&state, proc(state: ^State) {
		workers, _ := strconv.parse_int(os.get_env("SABA_STREAM_WORKERS", context.temp_allocator))
		if workers == 0 {
			workers = 1
		}
		state.result = server.serve({port = 0, workers = workers, handler = route, handler_data = state, control = &state.control, keep_alive = {enabled = true}, timeouts = {response = 150 * time.Millisecond}})
	}); assert(worker != nil)
	for _ in 0 ..< 5000 {
		endpoint, ready := server.server_endpoint(&state.control)

		if ready {
			fmt.printf("ready %d\n", endpoint.port)
			os.flush(os.stdout)
			break
		}

		time.sleep(time.Millisecond)
	}

	_, ready := server.server_endpoint(&state.control)
	assert(ready)
	command: [1]u8
	os.read(os.stdin, command[:])
	server.stop_server(&state.control)
	thread.join(worker)
	thread.destroy(worker)
	assert(state.result)
	assert(state.active == 0 && state.live == 0 && state.allocated == state.released)
	fmt.printf("stopped %d %d %d\n", state.drops, state.allocated, state.released)
	os.flush(os.stdout)
}
