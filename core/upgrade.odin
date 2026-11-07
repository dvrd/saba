package saba_core

import rt "base:runtime"
import "core:time"
import async "shared:async"

// Returning an upgrade transfers data to the server even if the101 write fails.
// Resume runs serially on the existing connection task. It must not retain IO,
// adopt/close the native socket, block, or perform concurrent socket operations.
// Resume may migrate between worker threads. IO and prefetched slices are
// borrowed only during that call. Data must outlive the HTTP request arena.
// A provided drop runs exactly once outside internal locks after IO quiesces.
// With nil drop, the caller owns data and keeps it alive until serve returns.
Upgrade :: struct {
	data: rawptr,
	resume: proc(data:rawptr,io:^Upgrade_IO)->async.Resume_Result,
	drop: proc(data:rawptr),
}

Upgrade_IO :: struct {
	socket: async.Socket,
	runtime: ^async.Runtime,
	connection: ^Connection,
}

// Consume borrowed prefetched bytes only within this resume. The adapter sets
// connection.read_deadline along with its async deadline when changing budgets.
upgrade_read :: proc(io:^Upgrade_IO,dst:[]u8,deadline:async.Deadline)->(int,async.Error) {
	if deadline_expired(io.connection.read_deadline) do return 0,{kind=.Timeout}
	if len(io.connection.read_buffer)>0 {
		n:=copy(dst,io.connection.read_buffer)
		io.connection.read_buffer=io.connection.read_buffer[n:]
		return n,{}
	}
	return async.read(io.socket,dst,deadline)
}

@(private)
drop_upgrade :: proc(task:^Connection_Task) {
	owned:=task.upgrade
	task.upgrade={}
	if owned.drop != nil do owned.drop(owned.data)
}

// Callback borrows remain valid until resume returns, even after consumption.
@(private)
upgrade_resume_finished :: proc(task:^Connection_Task) {
	if len(task.connection.read_buffer)==0 && task.upgrade_prefetched!=nil {
		delete(task.upgrade_prefetched,rt.heap_allocator())
		task.upgrade_prefetched=nil
		task.connection.read_buffer=nil
	}
}
