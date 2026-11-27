// Offloaded jobs on a bounded pool, seen from the wire: admission when the pool
// is full, pipelined requests behind a deferred answer, owners that leave or
// time out before their job ends, shutdown and drain with jobs still blocked,
// failed jobs, and a filesystem lane blocked on a FIFO.
package saba_e2e_offload_test

import "core:fmt"
import "core:net"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import harness "../../support/harness"

PROGRAM :: "tests/fixtures/apps/offload"

// One build, then each check on servers of its own, one at a time.
@(test)
offloaded_jobs :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Minute)
	work := harness.workdir(t, "offload")
	defer os.remove_all(work)
	binary, built := harness.build(t, PROGRAM, work)
	if !built {
		return
	}
	check_admission(t, binary)
	check_pipeline(t, binary)
	check_retirement(t, binary)
	check_failure_and_file(t, binary, work)
}

check_admission :: proc(t: ^testing.T, binary: string) -> bool {
	s := launch(t, binary) or_return
	defer close(t, &s)
	clients: [4]net.TCP_Socket
	for &conn, index in clients {
		conn = dial(t, &s)
		harness.send_text(conn, harness.request_wire("/work", "POST", fmt.tprint(index)))
	}
	defer for conn in clients {
		net.close(conn)
	}
	// The pool counts a job as running when a worker takes it, an instant
	// before the job body records its run; wait for both.
	state := until(t, &s, proc(s: Status) -> bool {return s[0] == 2 && s[1] == 2 && s[2] == 4 && s[3] == 2}) or_return
	testing.expectf(t, state[4] == 0, "dropped before release: %v", state)
	testing.expect_value(t, exchange(t, &s, "/work").status, 503)
	// Both job workers block, yet the network worker keeps answering.
	for _ in 0 ..< 32 {
		began := time.tick_now()
		cheap(t, &s)
		testing.expect(t, time.tick_since(began) < 500 * time.Millisecond, "cheap route waited for the pool")
	}
	exchange(t, &s, "/release")
	for conn, index in clients {
		reply, _ := harness.read_response(t, conn)
		testing.expectf(t, reply.status == 201 && string(reply.body) == fmt.tprint(index), "job %d: %d %q", index, reply.status, reply.body)
	}
	state = until(t, &s, proc(s: Status) -> bool {return s[2] == 0}) or_return
	return testing.expectf(t, state[4] == 5, "drops: %v", state)
}

check_pipeline :: proc(t: ^testing.T, binary: string) -> bool {
	one_running :: proc(s: Status) -> bool {return s[0] == 1}
	// A pipelined request already buffered with the job survives its disposal,
	// and no header goes out before the result.
	{
		s := launch(t, binary) or_return
		defer close(t, &s)
		conn := dial(t, &s)
		defer net.close(conn)
		harness.send_text(conn, strings.concatenate({harness.request_wire("/work", "POST", "snapshot"), harness.request_wire("/cheap")}, context.temp_allocator))
		until(t, &s, one_running) or_return
		testing.expect(t, harness.quiet(conn, 30 * time.Millisecond, TIMEOUT), "headers committed before result")
		exchange(t, &s, "/release")
		first, _ := harness.read_response(t, conn)
		second, _ := harness.read_response(t, conn)
		testing.expectf(t, first.status == 201 && string(first.body) == "snapshot", "job: %d %q", first.status, first.body)
		testing.expectf(t, second.status == 200 && string(second.body) == "cheap", "pipelined: %d %q", second.status, second.body)
	}
	// A pipelined request that arrives after suspension grows bounded storage.
	{
		s := launch(t, binary) or_return
		defer close(t, &s)
		conn := dial(t, &s)
		defer net.close(conn)
		harness.send_text(conn, harness.request_wire("/work", "POST", "late pipeline"))
		until(t, &s, one_running) or_return
		large := strings.concatenate({"X-Large: ", strings.repeat("a", 2048, context.temp_allocator), "\r\n"}, context.temp_allocator)
		harness.send_text(conn, harness.request_wire("/cheap", fields = large))
		testing.expect(t, harness.quiet(conn, 30 * time.Millisecond, TIMEOUT), "headers committed before result")
		exchange(t, &s, "/release")
		first, _ := harness.read_response(t, conn)
		second, _ := harness.read_response(t, conn)
		testing.expectf(t, first.status == 201 && string(first.body) == "late pipeline", "job: %d %q", first.status, first.body)
		testing.expectf(t, second.status == 200 && string(second.body) == "cheap", "pipelined: %d %q", second.status, second.body)
	}
	// Overflowing the pipeline closes and retires the owner while its job
	// stays blocked.
	{
		s := launch(t, binary) or_return
		defer close(t, &s)
		conn := dial(t, &s)
		defer net.close(conn)
		harness.send_text(conn, harness.request_wire("/work", "POST", "bounded owner"))
		until(t, &s, one_running) or_return
		harness.send_text(conn, strings.repeat("x", 32769, context.temp_allocator))
		harness.expect_closed(t, conn, "overflowing owner not closed")
		state := until(t, &s, proc(s: Status) -> bool {return s[5] == 1}) or_return
		testing.expectf(t, slice.equal(state[:5], []int{1, 0, 1, 1, 0}), "after overflow: %v", state)
		exchange(t, &s, "/release")
		state = until(t, &s, proc(s: Status) -> bool {return s[2] == 0}) or_return
		testing.expectf(t, state[4] == 1, "drops: %v", state)
	}
	return true
}

check_retirement :: proc(t: ^testing.T, binary: string) -> bool {
	// A peer that closes retires its owner and arena before the job, which
	// cannot be interrupted, finishes.
	{
		s := launch(t, binary) or_return
		defer close(t, &s)
		clients := [2]net.TCP_Socket{dial(t, &s), dial(t, &s)}
		for conn in clients {
			harness.send_text(conn, harness.request_wire("/work", "POST", "late owner"))
		}
		until(t, &s, proc(s: Status) -> bool {return s[0] == 2}) or_return
		for conn in clients {
			net.close(conn)
		}
		state := until(t, &s, proc(s: Status) -> bool {return s[5] == 2}) or_return
		testing.expectf(t, slice.equal(state[:5], []int{2, 0, 2, 2, 0}), "after close: %v", state)
		exchange(t, &s, "/release")
		state = until(t, &s, proc(s: Status) -> bool {return s[2] == 0}) or_return
		testing.expectf(t, state[4] == 2, "drops: %v", state)
	}
	// The handler deadline answers 504 and retires the arena while the job
	// keeps its snapshot. The job may have run, so it is not a replayable 408.
	{
		s := launch(t, binary, budget = 80) or_return
		defer close(t, &s)
		conn := dial(t, &s)
		defer net.close(conn)
		harness.send_text(conn, harness.request_wire("/work", "POST", "expired owner"))
		expired, _ := harness.read_response(t, conn)
		testing.expect_value(t, expired.status, 504)
		harness.expect_closed(t, conn, "expired owner not closed")
		state := until(t, &s, proc(s: Status) -> bool {return s[5] == 1}) or_return
		testing.expectf(t, slice.equal(state[:5], []int{1, 0, 1, 1, 0}), "after deadline: %v", state)
		exchange(t, &s, "/release")
		state = until(t, &s, proc(s: Status) -> bool {return s[2] == 0}) or_return
		testing.expectf(t, state[4] == 1, "drops: %v", state)
	}
	// Shutdown retires every owner, running and queued, before the jobs are
	// released; the program checks the runtime and arenas are gone by then.
	{
		s := launch(t, binary) or_return
		defer close(t, &s)
		clients: [4]net.TCP_Socket
		for &conn in clients {
			conn = dial(t, &s)
			harness.send_text(conn, harness.request_wire("/work", "POST", "stop owner"))
		}
		defer for conn in clients {
			net.close(conn)
		}
		until(t, &s, proc(s: Status) -> bool {return s[0] == 2 && s[1] == 2 && s[2] == 4}) or_return
		testing.expect_value(t, retire(t, &s), 4)
		for conn in clients {
			harness.expect_closed(t, conn, "owner not closed by shutdown")
		}
	}
	// The drain deadline retires a deferred owner before its job is released.
	{
		s := launch(t, binary) or_return
		defer close(t, &s)
		conn := dial(t, &s)
		defer net.close(conn)
		harness.send_text(conn, harness.request_wire("/work", "POST", "drain owner"))
		until(t, &s, proc(s: Status) -> bool {return s[0] == 1}) or_return
		testing.expect_value(t, retire(t, &s, "d"), 1)
		harness.expect_closed(t, conn, "owner not closed by drain")
	}
	return true
}

check_failure_and_file :: proc(t: ^testing.T, binary, work: string) -> bool {
	// A failed job exposes no result and frees what it owned exactly once.
	{
		s := launch(t, binary) or_return
		defer close(t, &s)
		conn := dial(t, &s)
		defer net.close(conn)
		harness.send_text(conn, harness.request_wire("/fail", "POST", "failed output"))
		until(t, &s, proc(s: Status) -> bool {return s[0] == 1}) or_return
		exchange(t, &s, "/release")
		reply, _ := harness.read_response(t, conn)
		testing.expectf(t, reply.status == 500 && len(reply.body) == 0, "failed job: %d %q", reply.status, reply.body)
		state := until(t, &s, proc(s: Status) -> bool {return s[2] == 0}) or_return
		testing.expectf(t, state[4] == 1, "drops: %v", state)
	}
	// The sole filesystem worker blocks opening a real named pipe; a second
	// request is rejected without opening another descriptor.
	fifo := fmt.tprintf("%s/owned.fifo", work)
	created := posix.mkfifo(strings.clone_to_cstring(fifo, context.temp_allocator), {.IRUSR, .IWUSR})
	testing.expect(t, created == .OK, "could not create a FIFO") or_return
	s := launch(t, binary, fifo = fifo) or_return
	defer close(t, &s)
	conn := dial(t, &s)
	defer net.close(conn)
	harness.send_text(conn, harness.request_wire("/file"))
	began := time.tick_now()
	for string(exchange(t, &s, "/file-status").body) != "1 0 1" {
		testing.expect(t, time.tick_since(began) < 3 * time.Second, "file worker never blocked") or_return
		time.sleep(5 * time.Millisecond)
	}
	testing.expect_value(t, exchange(t, &s, "/file").status, 503)
	cheap(t, &s)
	writer, opened := os.open(fifo, {.Write})
	testing.expectf(t, opened == nil, "open FIFO: %v", opened) or_return
	_, _ = os.write_string(writer, "owned filesystem bytes")
	os.close(writer)
	reply, _ := harness.read_response(t, conn)
	return testing.expectf(t, reply.status == 200 && string(reply.body) == "owned filesystem bytes", "file: %d %q", reply.status, reply.body)
}
