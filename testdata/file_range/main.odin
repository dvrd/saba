package main

import rt "base:runtime"
import "core:fmt"
import "core:mem"
import budget "shared:async/budget"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import server "shared:saba"

State :: struct {
	root:                        string,
	control:                     server.Server_Control,
	live, allocations, releases: int,
	result:                      bool,
}
state: State

allocate :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]u8,
	mem.Allocator_Error,
) {
	maximum, validation := budget.allocation_cost(16384, mem.DEFAULT_ALIGNMENT)
	assert(validation.kind == .None)
	assert(size <= int(maximum), "file backing exceeds one chunk plus accounting overhead")
	backing := rt.heap_allocator()
	bytes, error := backing.procedure(backing.data, mode, size, alignment, old, old_size, loc)
	if error == nil {
		#partial switch mode {
		case .Alloc, .Alloc_Non_Zeroed:
			sync.atomic_add(&state.live, len(bytes))
			sync.atomic_add(&state.allocations, 1)
		case .Free:
			if old != nil {
				sync.atomic_sub(&state.live, old_size)
				sync.atomic_add(&state.releases, 1)
			}
		}
	}
	return bytes, error
}

fds :: proc() -> int {
	count := 0

	for fd in 0 ..< 4096 {
		if posix.fcntl(posix.FD(fd), .GETFD) >= 0 {
			count += 1
		}
	}

	return count
}

route :: proc(_: ^server.Connection, request: ^server.Request) -> server.Response {
	if request.path == "/stats" {
		snapshot: [4]int
		snapshot[0] = sync.atomic_load(&state.live)
		snapshot[1] = sync.atomic_load(&state.allocations)
		snapshot[2] = sync.atomic_load(&state.releases)
		snapshot[3] = fds()
		body := fmt.aprintf(
			"%d %d %d %d",
			snapshot[0],
			snapshot[1],
			snapshot[2],
			snapshot[3],
			allocator = request.allocator,
		)
		return server.make_response(request, .OK, nil, transmute([]u8)body)
	}

	if request.path == "/fast" {
		return server.make_response(request, .OK, nil, transmute([]u8)string("ok"))
	}
	config := server.File_Stream_Config {
		etag        = `"fixture-v1"`,
		chunk_bytes = 16384,
		timeout     = 3 * time.Second,
		allocator   = {allocate, &state},
	}

	relative := strings.trim_prefix(request.path, "/")

	if strings.has_prefix(relative, "untagged/") {
		relative = relative[len("untagged/"):]
		config.etag = ""
	}

	if relative == "reject" {
		relative = "normal.bin"
		config.max_file_bytes = 3
	}

	if relative == "badhead" {
		relative = "normal.bin"
		config.content_type = "bad\r\nheader"
	}

	return server.serve_file_stream(request, state.root, relative, config)
}

main :: proc() {
	state.root = os.get_env("SABA_FILE_ROOT", context.allocator)
	defer delete(state.root)
	worker := thread.create_and_start(proc() {
		workers, _ := strconv.parse_int(os.get_env("SABA_FILE_WORKERS", context.temp_allocator))
		if workers == 0 {
			workers = 1
		}
		state.result = server.serve({port = 0, workers = workers, handler = route, control = &state.control, keep_alive = {enabled = true}, timeouts = {response = 200 * time.Millisecond}})
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
	assert(state.result && state.live == 0 && state.allocations == state.releases)
	fmt.println("stopped")
	os.flush(os.stdout)
}
