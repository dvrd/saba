package saba_modules

import core "../core"
import offload "../offload"
import rt "base:runtime"
import "core:mem"
import "core:slice"
import "core:strings"
import pool "shared:async/offload"

@(private)
Development_Module_Job :: struct {
	root, relative: string,
	backing:        mem.Allocator,
	arena:          mem.Dynamic_Arena,
	result:         Response,
}

// Prepared mount roots remain immutable until the application joins the lane.
// Each job takes its own copy of the decoded path and owns all result storage.
serve_development_modules :: proc(
	request: ^Request,
	mounts: []Module_Cache,
	lane: ^pool.Pool,
) -> (
	Response,
	bool,
) {
	for mount in mounts {
		relative, invalid, matched := module_request(request, mount.mount.prefix)
		if !matched {
			continue
		}
		if invalid || module_excluded(mount.mount.exclude, relative) {
			return not_found(request), true
		}

		backing := request.backing_allocator
		if backing.procedure == nil {
			backing = rt.heap_allocator()
		}
		job, error := new(Development_Module_Job, backing)
		if error != nil {
			return {status = .Service_Unavailable}, true
		}
		job.root, job.backing = mount.mount.directory, backing
		mem.dynamic_arena_init(
			&job.arena,
			backing,
			backing,
			block_size = 4096,
			out_band_size = 2048,
		)
		job.relative, error = strings.clone(relative, mem.dynamic_arena_allocator(&job.arena))
		if error != nil {
			drop_development_module(job)
			return {status = .Service_Unavailable}, true
		}

		work := pool.Work{job, run_development_module, drop_development_module}
		response, ok := offload.response(lane, &work, build_development_module)
		if !ok {
			drop_development_module(job)
			return {status = .Service_Unavailable}, true
		}
		return response, true
	}
	return {}, false
}

@(private)
run_development_module :: proc(data: rawptr, ctx: pool.Work_Context) -> bool {
	job := cast(^Development_Module_Job)data
	if pool.cancelled(ctx) {
		return false
	}
	// Development representations depend only on the module path. The HTTP
	// writer suppresses HEAD bytes after using the GET representation length.
	request := Request {
		allocator = mem.dynamic_arena_allocator(&job.arena),
	}
	// Diagnostics name their source through this worker's scratch storage.
	context.temp_allocator = request.allocator
	job.result = read_module(&request, job.root, job.relative, true)
	return true
}

@(private)
build_development_module :: proc(data: rawptr, allocator: mem.Allocator) -> (Response, bool) {
	result := (cast(^Development_Module_Job)data).result
	body, error := slice.clone(result.body, allocator)
	if error != nil {
		return {}, false
	}
	headers, ok := core.clone_headers(result.headers, allocator)
	return {status = result.status, body = body, headers = headers}, ok
}

@(private)
drop_development_module :: proc(data: rawptr) {
	job := cast(^Development_Module_Job)data
	mem.dynamic_arena_destroy(&job.arena)
	free(job, job.backing)
}
