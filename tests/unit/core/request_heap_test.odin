package saba_core

import rt "base:runtime"
import "core:log"
import "core:mem"
import "core:testing"

// The allocator application code gets by default while it serves a request.

@(test)
request_heap_counts_what_the_request_holds :: proc(t: ^testing.T) {
	task := new(Connection_Task)
	defer free(task)
	defer request_heap_release(task)
	allocator := request_heap_allocator(task)

	// A request that allocates nothing has no heap at all.
	testing.expect(t, task.heap == nil)
	testing.expect_value(t, request_heap_bytes(task), 0)

	kept, kept_error := make([]u8, 100, allocator)
	passing, passing_error := make([]u8, 50, allocator)
	testing.expect(t, kept_error == nil && passing_error == nil && task.heap != nil)
	testing.expect_value(t, request_heap_bytes(task), 150)
	for value in kept {
		testing.expect_value(t, value, 0)
	}

	testing.expect(t, request_heap_owns(task, kept))
	testing.expect(t, request_heap_owns(task, kept[:10]))
	testing.expect(t, !request_heap_owns(task, kept[1:]), "a slice that does not start the allocation")
	testing.expect(t, !request_heap_owns(task, nil))

	testing.expect_value(t, delete(passing, allocator), nil)
	testing.expect_value(t, request_heap_bytes(task), 100)
	testing.expect(t, !request_heap_owns(task, passing), "freed memory is no longer the request's")

	empty, empty_error := make([]u8, 0, allocator)
	testing.expect(t, empty_error == nil && raw_data(empty) == nil)
	testing.expect_value(t, request_heap_bytes(task), 100)
}

@(test)
request_heap_release_takes_everything_and_the_heap :: proc(t: ^testing.T) {
	task := new(Connection_Task)
	defer free(task)
	allocator := request_heap_allocator(task)

	for size in ([]int{1, 64, 4096, 1 << 20}) {
		_, error := mem.alloc_bytes(size, allocator = allocator)
		testing.expect_value(t, error, nil)
	}
	testing.expect_value(t, len(task.heap.live), 4)
	request_heap_release(task)
	testing.expect(t, task.heap == nil)
	testing.expect_value(t, request_heap_bytes(task), 0)

	// The next request starts from nothing, and free_all does the same.
	again, error := make([]u8, 32, allocator)
	testing.expect(t, error == nil && request_heap_owns(task, again))
	free_all(allocator)
	testing.expect(t, task.heap == nil)
}

@(test)
request_heap_resizes_keep_content_and_count :: proc(t: ^testing.T) {
	task := new(Connection_Task)
	defer free(task)
	defer request_heap_release(task)
	context.allocator = request_heap_allocator(task)

	// A dynamic array that grows the way a handler builds a body.
	body: [dynamic]u8
	for index in 0 ..< 100_000 {
		append(&body, u8(index % 251))
	}
	intact := true
	for value, index in body {
		intact &&= value == u8(index % 251)
	}
	testing.expect(t, intact, "content changed while the array grew")
	testing.expect(t, request_heap_owns(task, body[:]))
	// One allocation holds the array, whatever it took to grow it.
	testing.expect_value(t, len(task.heap.live), 1)
	testing.expect_value(t, request_heap_bytes(task), cap(body))

	shrink(&body)
	testing.expect_value(t, request_heap_bytes(task), len(body))
	delete(body)
	testing.expect_value(t, request_heap_bytes(task), 0)

	grown, error := mem.resize_bytes(nil, 64, allocator = context.allocator)
	testing.expect(t, error == nil && len(grown) == 64 && request_heap_owns(task, grown))
	for value in grown {
		testing.expect_value(t, value, 0)
	}
	gone, gone_error := mem.resize_bytes(grown, 0, allocator = context.allocator)
	testing.expect(t, gone_error == nil && gone == nil)
	testing.expect_value(t, request_heap_bytes(task), 0)
}

@(test)
request_heap_keeps_the_alignment_asked_for :: proc(t: ^testing.T) {
	task := new(Connection_Task)
	defer free(task)
	defer request_heap_release(task)
	allocator := request_heap_allocator(task)

	for alignment in ([]int{8, 16, 64, 4096}) {
		memory, error := mem.alloc_bytes(100, alignment, allocator)
		testing.expect_value(t, error, nil)
		testing.expectf(t, uintptr(raw_data(memory)) % uintptr(alignment) == 0, "alignment %d", alignment)
		grown, grow_error := mem.resize_bytes(memory, 5000, alignment, allocator)
		testing.expect_value(t, grow_error, nil)
		testing.expectf(t, uintptr(raw_data(grown)) % uintptr(alignment) == 0, "alignment %d after a resize", alignment)
	}
}

// Memory from another allocator is not the request's to free. The heap says
// so and leaves it alone, where the process heap would have been corrupted.
@(test)
request_heap_refuses_memory_it_did_not_allocate :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()
	task := new(Connection_Task)
	defer free(task)
	defer request_heap_release(task)
	allocator := request_heap_allocator(task)

	elsewhere, _ := make([]u8, 64, rt.heap_allocator())
	defer delete(elsewhere, rt.heap_allocator())
	elsewhere[0] = 42

	testing.expect_value(t, delete(elsewhere, allocator), mem.Allocator_Error.Invalid_Pointer)
	testing.expect(t, task.heap.warned)
	_, resized := mem.resize_bytes(elsewhere, 128, allocator = allocator)
	testing.expect_value(t, resized, mem.Allocator_Error.Invalid_Pointer)
	testing.expect_value(t, elsewhere[0], 42)
	testing.expect_value(t, request_heap_bytes(task), 0)

	// Freeing nothing is not an error, as with any allocator.
	testing.expect_value(t, free(nil, allocator), nil)

	features := mem.query_features(allocator)
	testing.expect(t, .Free in features && .Resize in features && .Free_All in features)
}
