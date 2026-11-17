package main

import rt "base:runtime"
import "core:fmt"
import owned "core:mem/owned"
import "core:os"
import "core:thread"
import "core:time"
import async "shared:async"
import server "shared:saba/core"

Events :: struct {
	sequence: int,
	next_at:  async.Deadline,
	pending:  owned.Chunk,
}

next_event :: proc(data: rawptr, io: ^server.Stream_IO) -> server.Stream_Step {
	events := cast(^Events)data
	if server.request_cancelled(io.cancellation) {
		return .Failed
	}
	if events.sequence == 8 {
		return .Done
	}

	if events.next_at.at != 0 {
		error := server.stream_wait(io, events.next_at)
		if error.kind == .Pending {
			return .Waiting
		}
		if error.kind != .None {
			return .Failed
		}
		events.next_at = {}
	}

	buffer: [256]u8
	text := ": heartbeat\n\n"
	if events.sequence % 2 == 0 {
		text = fmt.bprintf(buffer[:], "id: %d\nevent: tick\ndata: %d\n\n", events.sequence, events.sequence)
	}
	chunk, error := owned.copy_bounded(transmute([]u8)text, io.max_chunk_bytes, rt.heap_allocator())
	if error.kind != .None {
		return .Failed
	}
	events.pending = chunk
	if server.stream_submit(io, &events.pending) != .Accepted {
		return .Failed
	}
	events.sequence += 1
	events.next_at = async.deadline_after(io.runtime, 250 * time.Millisecond)

	return .Chunk
}

drop_events :: proc(data: rawptr) {
	events := cast(^Events)data
	owned.destroy(&events.pending)
	free(events, rt.heap_allocator())
}

route :: proc(_: rawptr, _: ^server.Connection, request: ^server.Request) -> server.Response {
	if request.path != "/events" || (request.method != "GET" && request.method != "HEAD") {
		return server.not_found(request)
	}
	events, error := new(Events, rt.heap_allocator())
	if error != nil {
		return {status = .Internal_Server_Error}
	}
	response := server.make_response(
		request,
		.OK,
		{{"Content-Type", "text/event-stream"}, {"Cache-Control", "no-store"}},
	)
	response.stream = {
		data            = events,
		next            = next_event,
		drop            = drop_events,
		content_length  = -1,
		max_chunk_bytes = 1024,
		max_body_bytes  = 65536,
		timeout         = 15 * time.Second,
	}

	return response
}

State :: struct {
	control: server.Server_Control,
	result:  bool,
}
main :: proc() {
	state: State
	worker := thread.create_and_start_with_poly_data(&state, proc(state: ^State) {
			state.result = server.serve(
				{
					port = 0,
					workers = 1,
					handler = route,
					control = &state.control,
					keep_alive = {enabled = true},
					timeouts = {response = time.Second},
				},
			)
		})
	assert(worker != nil)

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
	// GET /events with curl -N; press Enter to stop cooperatively.
	command: [1]u8
	os.read(os.stdin, command[:])
	server.stop_server(&state.control)
	thread.join(worker)
	thread.destroy(worker)
	assert(state.result)
	fmt.println("stopped")
	os.flush(os.stdout)
}
