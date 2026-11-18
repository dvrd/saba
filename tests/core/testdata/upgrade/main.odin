package main

import core "shared:saba/core"
import async "shared:async"
import rt "base:runtime"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"

State :: struct {
	control:          core.Server_Control,
	mutex:            sync.Mutex,
	created, dropped: int,
	result:           bool,
}
state: State
Session :: struct {
	state:                   ^State,
	id, resumes, used, sent: int,
	writing:                 bool,
	buffer:                  [5]u8,
	deadline:                async.Deadline,
}

resume :: proc(data: rawptr, io: ^core.Upgrade_IO) -> async.Resume_Result {
	session := cast(^Session)data

	if session.resumes == 0 {
		session.deadline = async.deadline_after(io.runtime, time.Second)
		io.connection.read_deadline = time.tick_add(time.tick_now(), time.Second)
	}

	session.resumes += 1

	if !session.writing {
		n, error := core.upgrade_read(io, session.buffer[session.used:], session.deadline)
		if error.kind == .Pending {
			return .Waiting
		}
		if error.kind != .None {
			return .Done
		}
		session.used += n
		if session.used < 5 {
			return .Yield
		}
		session.writing = true
	}

	if session.sent == 5 {
		return .Done
	}
	n, error := async.write(io.socket, session.buffer[session.sent:], session.deadline)
	if error.kind == .Pending {
		return .Waiting
	}
	if error.kind != .None {
		return .Done
	}
	session.sent += n

	return .Yield
}

drop :: proc(data: rawptr) {
	session := cast(^Session)data
	sync.lock(&session.state.mutex)
	session.state.dropped += 1
	fmt.printf("dropped %d %d\n", session.id, session.resumes)
	os.flush(os.stdout)
	sync.unlock(&session.state.mutex)
	free(session, rt.heap_allocator())
}

handler :: proc(_: rawptr, _: ^core.Connection, request: ^core.Request) -> core.Response {
	if request.path == "/stateless" {
		response := core.make_response(request, .Switching_Protocols, {{"Upgrade", "raw-echo"}})
		response.upgrade = {
			resume = proc(_: rawptr, _: ^core.Upgrade_IO) -> async.Resume_Result {return .Done},
		}

		return response
	}

	session, error := new(Session, rt.heap_allocator())
	assert(error == nil)
	session.state = &state
	sync.lock(&state.mutex)
	state.created += 1
	session.id = state.created
	fmt.printf("created %d\n", session.id)
	os.flush(os.stdout)
	sync.unlock(&state.mutex)
	if request.path == "/writefail" {
		time.sleep(60 * time.Millisecond)
	}
	response := core.make_response(request, .Switching_Protocols, {{"Upgrade", "raw-echo"}})
	if request.path == "/reject" {
		response.status = .OK
	}
	if request.path == "/badheader" {
		response.headers[0].value = "bad\r\nfield"
	}
	if request.path == "/missingprotocol" {
		response.headers = nil
	}
	if request.path == "/emptyprotocol" {
		response.headers[0].value = " \t "
	}
	response.upgrade = {
		data   = session,
		resume = resume,
		drop   = drop,
	}

	return response
}

main :: proc() {
	worker := thread.create_and_start(
		proc() {state.result = core.serve({handler = handler, control = &state.control, port = 0, workers = 2})},
	)
	assert(worker != nil)
	until := time.tick_add(time.tick_now(), 5 * time.Second)

	for time.tick_diff(time.tick_now(), until) > 0 {
		endpoint, ready := core.server_endpoint(&state.control)

		if ready {
			fmt.printf("ready %d\n", endpoint.port)
			os.flush(os.stdout)
			break
		}

		time.sleep(time.Millisecond)
	}

	_, ready := core.server_endpoint(&state.control)
	assert(ready)
	command: [1]u8
	os.read(os.stdin, command[:])
	core.stop_server(&state.control)
	thread.join(worker)
	thread.destroy(worker)
	assert(state.result && state.created == state.dropped)
	fmt.printf("finished %d %d\n", state.created, state.dropped)
	os.flush(os.stdout)
}
