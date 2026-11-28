package saba_assets

import "core:fmt"
import "core:mem"
import "core:os"
import "core:testing"

Read_Test_Allocator :: struct {
	backing:             mem.Allocator,
	path:                string,
	replacement:         []u8,
	armed, fail, erased: bool,
	requested:           int,
}
read_test_allocate :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]u8,
	mem.Allocator_Error,
) {
	state := cast(^Read_Test_Allocator)data
	if mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize {
		state.requested += size

		if state.fail {
			return nil, .Out_Of_Memory
		}

		if state.armed {
			state.armed = false
			assert(os.write_entire_file(state.path, state.replacement) == nil)
		}
	}
	if mode == .Free && old_memory != nil {
		state.erased = true

		for b in (cast([^]u8)old_memory)[:old_size] {
			if b != 0 {
				state.erased = false
				break
			}
		}
	}
	return state.backing.procedure(state.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

@(test)
regular_file_boundaries_and_rejections :: proc(t: ^testing.T) {
	directory, error := os.make_directory_temp("", "bounded-read-*", context.allocator)

	if !testing.expect(t, error == nil) {
		return
	}

	defer delete(directory)
	defer os.remove(directory)
	path := fmt.aprintf("%s/config", directory)
	defer delete(path)
	defer os.remove(path)

	for size in ([]int{0, 16, 65536}) {
		source := make([]u8, size)
		defer delete(source)

		for _, i in source {
			source[i] = u8(i % 251)
		}

		if !testing.expect(t, os.write_entire_file(path, source) == nil) {
			return
		}

		data, read_error := read_limited(path, 65536)
		testing.expect_value(t, read_error.kind, .None)
		testing.expect_value(t, len(data), size)
		testing.expect_value(t, string(data), string(source))
		delete(data)
	}

	large := make([]u8, 65537)
	defer delete(large)
	testing.expect(t, os.write_entire_file(path, large) == nil)
	state := Read_Test_Allocator {
		backing = context.allocator,
	}

	data, read_error := read_limited(path, 65536, {procedure = read_test_allocate, data = &state})
	testing.expect_value(t, read_error.kind, .Limit_Exceeded)
	testing.expect(t, data == nil && state.requested == 0, "oversize rejected before payload allocation")

	for invalid in ([]string{"", "invalid\x00path", directory}) {
		_, e := read_limited(invalid, 65536)
		testing.expect_value(t, e.kind, .Invalid_Input)
	}

	_, missing := read_limited(fmt.tprintf("%s/missing", directory), 65536)
	testing.expect_value(t, missing.kind, .Open_Failed)
	_, invalid_limit := read_limited(path, 0)
	testing.expect_value(t, invalid_limit.kind, .Invalid_Input)
}

@(test)
concurrent_growth_shrink_and_erasure :: proc(t: ^testing.T) {
	directory, error := os.make_directory_temp("", "bounded-race-*", context.allocator)

	if !testing.expect(t, error == nil) {
		return
	}

	defer delete(directory)
	defer os.remove(directory)
	path := fmt.aprintf("%s/config", directory)
	defer delete(path)
	defer os.remove(path)
	// Allocation is after fstat, so this deterministic hook changes the same
	// open file before reading; no timing-dependent background thread is needed.
	cases := []struct {
		initial, replacement: string,
		limit:                int,
		expected:             Read_Error_Kind,
	} {
		{"secret", "secret!", 6, .Limit_Exceeded},
		{"secret", "secret!", 20, .Size_Changed},
		{"secret", "sec", 20, .Size_Changed},
	}

	for item in cases {
		testing.expect(t, os.write_entire_file(path, item.initial) == nil)
		state := Read_Test_Allocator {
			backing     = context.allocator,
			path        = path,
			replacement = transmute([]u8)item.replacement,
			armed       = true,
		}

		data, read_error := read_limited(
			path,
			item.limit,
			{procedure = read_test_allocate, data = &state},
			erase_on_failure = true,
		)
		testing.expect_value(t, read_error.kind, item.expected)
		testing.expect(t, data == nil && state.erased, "failed credential snapshot is wiped before release")
		testing.expect_value(t, state.requested, len(item.initial))
	}
}

@(test)
allocation_failure_returns_no_snapshot :: proc(t: ^testing.T) {
	directory, error := os.make_directory_temp("", "bounded-allocation-*", context.allocator)

	if !testing.expect(t, error == nil) {
		return
	}

	defer delete(directory)
	defer os.remove(directory)
	path := fmt.aprintf("%s/config", directory)
	defer delete(path)
	defer os.remove(path)
	testing.expect(t, os.write_entire_file(path, "secret") == nil)
	state := Read_Test_Allocator {
		backing = context.allocator,
		fail    = true,
	}

	data, read_error := read_limited(path, 20, {procedure = read_test_allocate, data = &state})
	testing.expect(t, data == nil)
	testing.expect_value(t, read_error.kind, .Allocation_Failed)
}
