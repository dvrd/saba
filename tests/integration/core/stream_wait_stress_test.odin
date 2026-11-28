package saba_core

import rt "base:runtime"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import async "shared:async"
import owned "shared:async/owned"

// A producer that suspends on a timer before every chunk. Every chunk needs
// its timer wake to arrive: a lost one leaves the stream silent for good.
// The streams share one worker with each other and with large downloads, so
// the wakes arrive while the worker is busy writing.
SWS_CHUNKS :: 20
SWS_CLIENTS :: 16
SWS_ROUNDS :: 12
SWS_DOWNLOADS :: 2
SWS_LARGE :: 4 * 1024 * 1024

SWS_Producer :: struct {
	sent:    int,
	next_at: async.Deadline,
}

SWS_Fixture :: struct {
	config:  Server,
	control: Server_Control,
	ok:      bool,
	worker:  ^thread.Thread,
	large:   []u8,
	// Set once every timer stream finished; the downloads stop then.
	settled: bool,
}

sws_next :: proc(data: rawptr, io: ^Stream_IO) -> Stream_Step {
	producer := cast(^SWS_Producer)data
	if producer.sent == SWS_CHUNKS {
		return .Done
	}
	if producer.next_at.at == 0 {
		producer.next_at = async.deadline_after(io.runtime, time.Millisecond)
	}
	waited := stream_wait(io, producer.next_at)
	if waited.kind == .Pending {
		return .Waiting
	}
	if waited.kind != .None {
		return .Failed
	}
	producer.next_at = {}
	chunk, error := owned.copy_bounded(transmute([]u8)string("x"), 1, io.backing_allocator)
	if error.kind != .None {
		return .Failed
	}
	if stream_submit(io, &chunk) != .Accepted {
		owned.destroy(&chunk)
		return .Failed
	}
	producer.sent += 1
	return .Chunk
}

sws_handler :: proc(data: rawptr, _: ^Connection, request: ^Request) -> Response {
	if request.path == "/large" {
		return {status = .OK, body = (cast(^SWS_Fixture)data).large}
	}
	producer := new(SWS_Producer, rt.heap_allocator())
	return {
		status = .OK,
		stream = {
			data = producer,
			next = sws_next,
			drop = proc(data: rawptr) {
				free(cast(^SWS_Producer)data, rt.heap_allocator())
			},
			content_length = -1,
			// Long enough that only a lost wake, never the budget, ends a stream early.
			timeout = 2 * time.Minute,
		},
	}
}

SWS_Client :: struct {
	endpoint:  net.Endpoint,
	completed: int,
	failure:   string,
}

sws_client :: proc(c: ^SWS_Client) {
	want := strings.repeat("1\r\nx\r\n", SWS_CHUNKS, rt.heap_allocator())
	defer delete(want, rt.heap_allocator())
	for round in 0 ..< SWS_ROUNDS {
		socket, dialed := net.dial_tcp(c.endpoint)
		if dialed != nil {
			c.failure = fmt.aprintf("round %d: dial %v", round, dialed, allocator = rt.heap_allocator())
			return
		}
		// A minute without a byte is a stalled stream, not a slow machine.
		_ = net.set_option(socket, .Receive_Timeout, time.Minute)
		request := "GET /ticks HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n"
		_, _ = net.send_tcp(socket, transmute([]u8)request)
		wire := make([dynamic]u8, rt.heap_allocator())
		buffer: [4096]u8
		stalled := false
		for {
			n, received := net.recv_tcp(socket, buffer[:])
			if n > 0 {
				append(&wire, ..buffer[:n])
			}
			if received != nil {
				stalled = true
				break
			}
			if n == 0 {
				break
			}
		}
		net.close(socket)
		text := string(wire[:])
		complete := !stalled && strings.contains(text, want) && strings.has_suffix(text, "0\r\n\r\n")
		if !complete {
			c.failure = fmt.aprintf(
				"round %d: stalled=%v after %d bytes, %d of %d chunks",
				round,
				stalled,
				len(wire),
				strings.count(text, "1\r\nx\r\n"),
				SWS_CHUNKS,
				allocator = rt.heap_allocator(),
			)
			delete(wire)
			return
		}
		delete(wire)
		c.completed += 1
	}
}

SWS_Download :: struct {
	fixture:  ^SWS_Fixture,
	endpoint: net.Endpoint,
	fetched:  int,
	failure:  string,
}

// Fetches /large over and over until the timer streams are done.
sws_download :: proc(d: ^SWS_Download) {
	buffer := make([]u8, 64 * 1024, rt.heap_allocator())
	defer delete(buffer, rt.heap_allocator())
	for !sync.atomic_load(&d.fixture.settled) {
		socket, dialed := net.dial_tcp(d.endpoint)
		if dialed != nil {
			d.failure = fmt.aprintf("dial %v", dialed, allocator = rt.heap_allocator())
			return
		}
		_ = net.set_option(socket, .Receive_Timeout, time.Minute)
		request := "GET /large HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n"
		_, _ = net.send_tcp(socket, transmute([]u8)request)
		total := 0
		for {
			n, received := net.recv_tcp(socket, buffer)
			total += max(n, 0)
			if received != nil || n == 0 {
				break
			}
		}
		net.close(socket)
		if total < SWS_LARGE {
			d.failure = fmt.aprintf("a download ended after %d bytes", total, allocator = rt.heap_allocator())
			return
		}
		d.fetched += 1
	}
}

// Many streams suspend on short timers at once. Each must be resumed for
// every chunk; the clients allow a minute of silence before they call a
// stream stalled.
@(test)
stream_timer_waits_are_never_lost :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Minute)
	fixture: SWS_Fixture
	fixture.large = make([]u8, SWS_LARGE)
	defer delete(fixture.large)
	fixture.config = {
		address      = "127.0.0.1",
		workers      = 1,
		handler      = sws_handler,
		handler_data = &fixture,
		control      = &fixture.control,
		timeouts     = {header = time.Minute, body = time.Minute, response = time.Minute, idle = time.Minute},
	}
	fixture.worker = thread.create_and_start_with_poly_data(&fixture, proc(f: ^SWS_Fixture) {f.ok = serve(f.config)})
	until := time.tick_add(time.tick_now(), 60 * time.Second)
	for !server_ready(&fixture.control) && !thread.is_done(fixture.worker) && time.tick_diff(time.tick_now(), until) > 0 {
		time.sleep(time.Millisecond)
	}
	endpoint, ready := server_endpoint(&fixture.control)
	defer {
		stop_server(&fixture.control)
		thread.join(fixture.worker)
		thread.destroy(fixture.worker)
	}
	if !testing.expect(t, ready && endpoint.port > 0) {
		return
	}

	downloads: [SWS_DOWNLOADS]SWS_Download
	downloaders: [SWS_DOWNLOADS]^thread.Thread
	for &download, index in downloads {
		download = {
			fixture  = &fixture,
			endpoint = endpoint,
		}
		downloaders[index] = thread.create_and_start_with_poly_data(&download, sws_download)
	}

	clients: [SWS_CLIENTS]SWS_Client
	threads: [SWS_CLIENTS]^thread.Thread
	for &client, index in clients {
		client.endpoint = endpoint
		threads[index] = thread.create_and_start_with_poly_data(&client, sws_client)
	}
	completed := 0
	for worker, index in threads {
		thread.join(worker)
		thread.destroy(worker)
		completed += clients[index].completed
		if clients[index].failure != "" {
			testing.expectf(t, false, "client %d: %s", index, clients[index].failure)
			delete(clients[index].failure, rt.heap_allocator())
		}
	}
	testing.expect_value(t, completed, SWS_CLIENTS * SWS_ROUNDS)

	sync.atomic_store(&fixture.settled, true)
	for worker, index in downloaders {
		thread.join(worker)
		thread.destroy(worker)
		if downloads[index].failure != "" {
			testing.expectf(t, false, "download %d: %s", index, downloads[index].failure)
			delete(downloads[index].failure, rt.heap_allocator())
		}
	}
}
