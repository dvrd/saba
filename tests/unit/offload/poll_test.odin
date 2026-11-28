package saba_offload_test

import rt "base:runtime"
import "core:mem"
import "core:sync"
import "core:testing"
import "core:time"
import async "shared:async"
import budget "shared:async/budget"
import pool "shared:async/offload"
import signal "shared:async/signal"
import adapter "shared:saba/offload"
import server "shared:saba/core"

// A job that blocks until released, and counts its drops.
Held_Job :: struct {
	started, release: sync.Sema,
	drops:            int,
}

held_work :: proc(job: ^Held_Job) -> pool.Work {
	return {
		data = job,
		run = proc(data: rawptr, _: pool.Work_Context) -> bool {
			job := cast(^Held_Job)data
			sync.sema_post(&job.started)
			sync.sema_wait(&job.release)
			return true
		},
		drop = proc(data: rawptr) {sync.atomic_add(&(cast(^Held_Job)data).drops, 1)},
	}
}

no_build :: proc(_: rawptr, _: mem.Allocator) -> (server.Response, bool) {
	return {}, false
}

// The owner side of a deferred response: a wake signal on a task that is never
// registered, so a pool notification is a no-op.
Owner :: struct {
	runtime: async.Runtime,
	task:    async.Task,
	io:      server.Deferred_IO,
}

owner_open :: proc(o: ^Owner) {
	assert(async.init(&o.runtime, {workers = 1, task_capacity = 1, io_capacity = 1}).kind == .None)
	wake, created := signal.create(&o.runtime, &o.task)
	assert(created)
	o.io = {
		allocator = context.allocator,
		wake      = wake,
	}
}

owner_close :: proc(o: ^Owner) {
	signal.detach(o.io.wake)
	signal.release(&o.io.wake)
	server.release_request_context(&o.io.cancellation)
	assert(async.destroy(&o.runtime).kind == .None)
}

// A pool that shuts down under a running job cancels it. The owner answers
// 503 and closes: the server is going away, the job did not fail.
@(test)
job_cancelled_by_pool_shutdown_answers_service_unavailable_and_closes :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	lane: pool.Pool
	assert(pool.init(&lane, {workers = 1, capacity = 1}) == .None)
	owner: Owner
	owner_open(&owner)
	defer owner_close(&owner)
	job: Held_Job
	work := held_work(&job)
	response, accepted := adapter.response(&lane, &work, no_build)
	assert(accepted)
	deferred := response.deferred

	_, step := deferred.poll(deferred.data, &owner.io)
	testing.expect_value(t, step, server.Deferred_Step.Waiting)
	testing.expect(t, sync.sema_wait_with_timeout(&job.started, 4 * time.Second), "the job never ran")
	pool.shutdown(&lane)
	answer, cancelled := deferred.poll(deferred.data, &owner.io)
	testing.expect_value(t, cancelled, server.Deferred_Step.Ready)
	testing.expect_value(t, answer.status, server.HTTP_Status.Service_Unavailable)
	testing.expect(t, answer.close_connection)

	server.discard_response(&response)
	sync.sema_post(&job.release)
	testing.expect_value(t, pool.join(&lane), pool.Error.None)
	testing.expect_value(t, pool.destroy(&lane), pool.Error.None)
	testing.expect_value(t, job.drops, 1)
}

// The request's deadline goes to the pool with the job: a request already out
// of time is never queued, and answers 504 with its work dropped once.
@(test)
job_inherits_the_request_deadline :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	lane: pool.Pool
	assert(pool.init(&lane, {workers = 1, capacity = 1}) == .None)
	owner: Owner
	owner_open(&owner)
	defer owner_close(&owner)
	cancellation, created := server.new_request_context(
		nil,
		time.tick_add(time.tick_now(), -time.Second),
		rt.heap_allocator(),
	)
	assert(created)
	owner.io.cancellation = cancellation
	job: Held_Job
	work := held_work(&job)
	response, accepted := adapter.response(&lane, &work, no_build)
	assert(accepted)

	answer, step := response.deferred.poll(response.deferred.data, &owner.io)
	testing.expect_value(t, step, server.Deferred_Step.Ready)
	testing.expect_value(t, answer.status, server.HTTP_Status.Gateway_Timeout)
	testing.expect_value(t, pool.stats(&lane).accepted, u64(0))

	server.discard_response(&response)
	sync.sema_post(&job.release)
	pool.shutdown(&lane)
	testing.expect_value(t, pool.join(&lane), pool.Error.None)
	testing.expect_value(t, pool.destroy(&lane), pool.Error.None)
	testing.expect_value(t, job.drops, 1)
}

// Bytes the job holds outside any allocator are charged to the request's
// budget for as long as the job lives.
@(test)
unmanaged_bytes_are_charged_to_the_request_budget :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	lane: pool.Pool
	assert(pool.init(&lane, {workers = 1, capacity = 1}) == .None)
	owner: Owner
	owner_open(&owner)
	defer owner_close(&owner)
	root, created := budget.create_root({jobs = 1, bytes = 1 << 20})
	assert(created == .None)
	defer budget.release_scope(&root)
	owner.io.resources = root
	job: Held_Job
	work := held_work(&job)
	response, accepted := adapter.response_with_unmanaged_bytes(&lane, &work, no_build, unmanaged_bytes = 4096)
	assert(accepted)

	_, step := response.deferred.poll(response.deferred.data, &owner.io)
	testing.expect_value(t, step, server.Deferred_Step.Waiting)
	testing.expect(t, sync.sema_wait_with_timeout(&job.started, 4 * time.Second), "the job never ran")
	view, error := budget.snapshot(root)
	testing.expect_value(t, error, budget.Error.None)
	testing.expect_value(t, view.used.jobs, 1)
	testing.expect_value(t, view.used.bytes, 4096)

	server.discard_response(&response)
	sync.sema_post(&job.release)
	pool.shutdown(&lane)
	testing.expect_value(t, pool.join(&lane), pool.Error.None)
	testing.expect_value(t, pool.destroy(&lane), pool.Error.None)
	testing.expect_value(t, job.drops, 1)
	view, error = budget.snapshot(root)
	testing.expect_value(t, view.used.jobs, 0)
	testing.expect_value(t, view.used.bytes, 0)
}
