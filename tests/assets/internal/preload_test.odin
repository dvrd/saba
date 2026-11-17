package saba_assets

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:testing"

@(private)
asset_test_directory :: proc() -> string {
	directory, error := os.make_directory_temp("", "saba-assets-*", context.allocator)
	assert(error == nil)

	return directory
}
@(private)
asset_test_write :: proc(directory, name, value: string) {
	assert(os.write_entire_file(fmt.tprintf("%s/%s", directory, name), value) == nil)
}

@(test)
asset_exact_global_limits_and_legacy_callable :: proc(t: ^testing.T) {
	directory := asset_test_directory()
	defer delete(directory)
	defer os.remove_all(directory)
	asset_test_write(directory, "one.txt", "1234")
	asset_test_write(directory, "empty.txt", "")
	mounts := []Asset_Mount{{directory, ""}}
	legacy: proc(_: []Asset_Mount, _: mem.Allocator) -> ([]Asset_Cache, bool) = prepare_assets
	old, ok := legacy(mounts, context.allocator)
	assert(ok)
	destroy_assets(&old, context.allocator)
	caches, error := prepare_assets_bounded(
		mounts,
		{max_mounts = 1, max_files = 2, max_entries = 2, max_file_bytes = 4, max_total_bytes = 4},
		context.allocator,
	)
	assert(error.kind == .None)
	testing.expect_value(t, len(caches[0].files), 2)
	testing.expect_value(t, string(caches[0].files["one.txt"].body), "1234")
	testing.expect_value(t, len(caches[0].files["empty.txt"].body), 0)
	destroy_assets(&caches, context.allocator)
	destroy_assets(&caches, context.allocator)
	testing.expect(t, caches == nil)

	for item in ([]struct {
			limits: Asset_Limits,
			kind:   Asset_Error_Kind,
		} {
			{{max_files = 1}, .File_Limit},
			{{max_entries = 1}, .Entry_Limit},
			{{max_file_bytes = 3}, .File_Bytes},
			{{max_total_bytes = 3}, .Total_Bytes},
			{{max_files = -1}, .Invalid_Limits},
			{{max_file_bytes = 65 << 20}, .Invalid_Limits},
		}) {
		output, failure := prepare_assets_bounded(mounts, item.limits, context.allocator)
		testing.expect_value(t, failure.kind, item.kind)
		testing.expect(t, output == nil)
	}

	multi := []Asset_Mount{{directory, "/a/"}, {directory, "/b/"}}
	output, failure := prepare_assets_bounded(multi, {max_mounts = 1}, context.allocator)
	testing.expect_value(t, failure.kind, .Mount_Limit)
	testing.expect(t, output == nil)
	output, failure = prepare_assets_bounded(multi, {max_files = 3}, context.allocator)
	testing.expect_value(t, failure.kind, .File_Limit)
	testing.expect(t, output == nil)
	output, failure = prepare_assets_bounded(multi, {max_total_bytes = 7}, context.allocator)
	testing.expect_value(t, failure.kind, .Total_Bytes)
	testing.expect(t, output == nil)
}

@(private)
Asset_Test_Allocator :: struct {
	backing:                    mem.Allocator,
	calls, fail_at, live, peak: int,
	fail_size:                  int,
	path, replacement:          string,
	mutate_size:                int,
	mutated:                    bool,
}
@(private)
asset_test_allocate :: proc(
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
	state := cast(^Asset_Test_Allocator)data
	if mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed {
		if size > 0 {
			state.calls += 1

			if state.fail_at == state.calls || (state.fail_size > 0 && size == state.fail_size) {
				return nil, .Out_Of_Memory
			}

			if !state.mutated && state.mutate_size == size {
				state.mutated = true
				assert(os.write_entire_file(state.path, state.replacement) == nil)
			}
		}
	}
	bytes, error := state.backing.procedure(state.backing.data, mode, size, alignment, old, old_size, loc)
	if error == nil {
		#partial switch mode {
		case .Alloc, .Alloc_Non_Zeroed:
			state.live += len(bytes)
		case .Resize, .Resize_Non_Zeroed:
			state.live += len(bytes) - old_size
		case .Free:
			state.live -= old_size
		}

		state.peak = max(state.peak, state.live)
	}
	return bytes, error
}

@(test)
asset_all_retained_allocation_failures_release_every_owner :: proc(t: ^testing.T) {
	directory := asset_test_directory()
	defer delete(directory)
	defer os.remove_all(directory)

	for i in 0 ..< 12 {
		asset_test_write(directory, fmt.tprintf("%02d.txt", i), "payload")
	}

	state := Asset_Test_Allocator {
		backing = context.allocator,
	}

	allocator := mem.Allocator{asset_test_allocate, &state}
	caches, error := prepare_assets_bounded({{directory, ""}}, {}, allocator)
	assert(error.kind == .None)
	calls := state.calls
	destroy_assets(&caches, allocator)
	testing.expect_value(t, state.live, 0)
	testing.expect(t, calls > 25, "includes map growth and per-file ownership")

	for index in 1 ..= calls {
		state = {
			backing = context.allocator,
			fail_at = index,
		}

		result, failure := prepare_assets_bounded({{directory, ""}}, {}, allocator)
		testing.expect_value(t, failure.kind, .Allocation_Failed)
		testing.expect(t, result == nil)
		destroy_assets(&result, allocator)
		testing.expect_value(t, state.live, 0)
	}
}

@(test)
asset_preallocation_caps_and_changed_file_cleanup :: proc(t: ^testing.T) {
	directory := asset_test_directory()
	defer delete(directory)
	defer os.remove_all(directory)
	asset_test_write(directory, "data.txt", "12345678901234567")
	state := Asset_Test_Allocator {
		backing   = context.allocator,
		fail_size = 17,
	}

	allocator := mem.Allocator{asset_test_allocate, &state}
	result, error := prepare_assets_bounded({{directory, ""}}, {max_file_bytes = 16}, allocator)
	testing.expect_value(t, error.kind, .File_Bytes)
	testing.expect(t, result == nil)
	testing.expect_value(t, state.live, 0)

	for item in ([]struct {
			value: string,
			kind:  Asset_Error_Kind,
		}{{"123456789012345678", .File_Bytes}, {"123", .Read_Failed}}) {
		asset_test_write(directory, "data.txt", "12345678901234567")
		path := fmt.aprintf("%s/data.txt", directory)
		defer delete(path)
		state = {
			backing     = context.allocator,
			path        = path,
			replacement = item.value,
			mutate_size = 17,
		}
		output, failure := prepare_assets_bounded({{directory, ""}}, {max_file_bytes = 17}, allocator)
		testing.expect(t, state.mutated)
		testing.expect_value(t, failure.kind, item.kind)
		testing.expect(t, output == nil)
		testing.expect_value(t, state.live, 0)
	}
}

@(test)
asset_development_reads_remain_bounded_and_paths_stay_private :: proc(t: ^testing.T) {
	directory := asset_test_directory()
	defer delete(directory)
	defer os.remove_all(directory)
	asset_test_write(directory, "ok.txt", "tiny")
	asset_test_write(directory, "private.jsx", "hidden")
	caches, error := prepare_assets_bounded({{directory, ""}}, {max_file_bytes = 4}, context.allocator)
	assert(error.kind == .None)
	defer destroy_assets(&caches, context.allocator)
	testing.expect_value(t, len(caches[0].files), 1)
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	request := Request {
		allocator = mem.dynamic_arena_allocator(&arena),
		method    = "GET",
		path      = "/assets/ok.txt",
	}

	response, matched := serve_assets(&request, caches)
	testing.expect(t, matched)
	testing.expect_value(t, string(response.body), "tiny")
	asset_test_write(directory, "ok.txt", "larger")
	response, matched = asset_test_failed_development(&request, caches)
	testing.expect(t, matched)
	testing.expect_value(t, response.status, .Internal_Server_Error)

	for path in ([]string{"/assets/../ok.txt", "/assets/%2e%2e/ok.txt", "/assets/private.jsx", "/assets/.hidden"}) {
		request.path = path
		response, matched = serve_assets(&request, caches, true)
		testing.expect(t, matched)
		testing.expect_value(t, response.status, .Not_Found)
	}
}

@(test)
asset_bad_mounts_and_exhausted_total_accept_only_empty_files :: proc(t: ^testing.T) {
	directory := asset_test_directory()
	defer delete(directory)
	defer os.remove_all(directory)
	asset_test_write(directory, "one", "a")
	asset_test_write(directory, "two", "b")
	output, failure := prepare_assets_bounded({{directory, ""}}, {max_total_bytes = 1}, context.allocator)
	testing.expect_value(t, failure.kind, .Total_Bytes)
	testing.expect(t, output == nil)

	for mount in ([]Asset_Mount {
			{"", ""},
			{directory, "/../"},
			{directory, "relative/"},
			{directory, "/bad"},
			{"/nonexistent-saba-test-path", ""},
		}) {
		result, error := prepare_assets_bounded({mount}, {}, context.allocator)
		testing.expect(t, error.kind != .None && result == nil)
	}
}

@(private)
asset_test_failed_development :: proc(request: ^Request, caches: []Asset_Cache) -> (Response, bool) {
	previous := context.logger
	context.logger = log.nil_logger()
	defer {
		context.logger = previous
	}

	return serve_assets(request, caches, true)
}
