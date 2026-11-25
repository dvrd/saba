package saba_core

import "core:testing"
import "core:sync"
import rt "base:runtime"
import budget "shared:async/sync/budget"

@(test)
upgrade_prefetched_bytes_release_their_charged_backing :: proc(t: ^testing.T) {
	fixture: Resource_Test
	resource_test_init(&fixture)
	defer resource_test_finish(&fixture)
	borrowed := [?]u8{0x81, 0x80, 1, 2, 3, 4}
	fixture.task.connection.read_buffer = borrowed[:]
	testing.expect(t, release_upgrade_request(&fixture.task))
	owned, error := budget.snapshot(fixture.task.resource_connection)
	testing.expect_value(t, error, .None)
	testing.expect(t, owned.used.bytes >= u64(len(borrowed)))
	fixture.task.connection.read_buffer = fixture.task.connection.read_buffer[:0]
	upgrade_resume_finished(&fixture.task)
	released, release_error := budget.snapshot(fixture.task.resource_connection)
	testing.expect_value(t, release_error, .None)
	testing.expect_value(t, released.used.bytes, u64(0))
	testing.expect(t, fixture.task.upgrade_prefetched == nil)
}

@(test)
completed_upgrade_context_observes_drain_and_stop_without_mutating_status :: proc(t: ^testing.T) {
	testing.expect(t, !request_server_stopping({}))

	for stop in ([]bool{false, true}) {
		state, error := new(Server_Cancellation, rt.heap_allocator())
		assert(error == nil)
		state.references = 1
		handle, retained := new_request_context(state, {}, rt.heap_allocator())
		assert(retained)
		cancel_request_context(handle, .Completed)
		testing.expect(t, !request_server_stopping(handle))

		if stop {
			sync.atomic_store(&state.stopping, true)
		} else {
			sync.atomic_store(&state.drain_at, i64(1))
		}

		testing.expect(t, request_server_stopping(handle))
		testing.expect_value(t, request_context_status(handle), .Completed)
		release_request_context(&handle)
		release_server_cancellation(state)
	}
}
