package saba_core

import "core:mem"
import "core:testing"
import rt "base:runtime"
import async "shared:async"

@(test)
upgrade_drop_is_once_and_cleared_before_reentrant_drop :: proc(t: ^testing.T) {
	Owner :: struct {
		task:  ^Connection_Task,
		count: int,
	}

	task: Connection_Task
	owner := Owner {
		task = &task,
	}

	task.upgrade = {
		data = &owner,
		resume = proc(_: rawptr, _: ^Upgrade_IO) -> async.Resume_Result {return .Done},
		drop = proc(data: rawptr) {
			owner := cast(^Owner)data
			owner.count += 1
			drop_upgrade(owner.task)
		},
	}

	drop_upgrade(&task)
	drop_upgrade(&task)
	testing.expect_value(t, owner.count, 1)
}

@(test)
invalid_upgrade_is_released_before_response_allocation :: proc(t: ^testing.T) {
	runtime: Server_Runtime
	task := Connection_Task {
		runtime = &runtime,
	}

	count: int

	for response in ([]Response {
			{
				status = .OK,
				upgrade = {
					data = &count,
					resume = proc(_: rawptr, _: ^Upgrade_IO) -> async.Resume_Result {return .Done},
					drop = proc(data: rawptr) {counter := cast(^int)data; counter^ += 1},
				},
			},
			{
				status = .Switching_Protocols,
				upgrade = {data = &count, drop = proc(data: rawptr) {counter := cast(^int)data; counter^ += 1}},
			},
		}) {
		count = 0
		testing.expect(t, !queue_response(&task, response))
		testing.expect_value(t, count, 1)
		drop_upgrade(&task)
		testing.expect_value(t, count, 1)
	}
}

@(test)
failed_response_allocation_keeps_upgrade_for_terminal_drop :: proc(t: ^testing.T) {
	runtime: Server_Runtime
	task := Connection_Task {
		runtime = &runtime,
	}

	mem.dynamic_arena_init(
		&task.arena,
		out_band_size = 64 * 1024,
		block_allocator = {
			procedure = proc(
				_: rawptr,
				mode: mem.Allocator_Mode,
				size, alignment: int,
				old_memory: rawptr,
				old_size: int,
				location := #caller_location,
			) -> (
				[]u8,
				mem.Allocator_Error,
			) {return nil, .Out_Of_Memory},
		},
	)
	defer mem.dynamic_arena_destroy(&task.arena)
	count: int
	response := Response {
		status = .Switching_Protocols,
		headers = {{"Upgrade", "raw-echo"}},
		upgrade = {
			data = &count,
			resume = proc(_: rawptr, _: ^Upgrade_IO) -> async.Resume_Result {return .Done},
			drop = proc(data: rawptr) {counter := cast(^int)data; counter^ += 1},
		},
	}

	testing.expect(t, !queue_response(&task, response))
	testing.expect_value(t, count, 0)
	drop_upgrade(&task)
	drop_upgrade(&task)
	testing.expect_value(t, count, 1)
}

@(test)
upgrade_prefetch_borrow_survives_until_resume_returns :: proc(t: ^testing.T) {
	saved := make([]u8, 5, rt.heap_allocator())
	copy(saved, "hello")
	task := Connection_Task {
		upgrade_prefetched = saved,
		connection = {read_buffer = saved},
	}

	io := Upgrade_IO {
		connection = &task.connection,
	}

	borrowed := io.connection.read_buffer
	buffer: [5]u8
	n, error := upgrade_read(&io, buffer[:], {})
	testing.expect_value(t, n, 5)
	testing.expect_value(t, error.kind, .None)
	testing.expect_value(t, borrowed[0], u8('h'))
	testing.expect_value(t, string(borrowed), "hello")
	testing.expect(t, task.upgrade_prefetched != nil)
	upgrade_resume_finished(&task)
	testing.expect(t, task.upgrade_prefetched == nil)
	upgrade_resume_finished(&task)
}
