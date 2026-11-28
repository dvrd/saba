package saba_core

import rt "base:runtime"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import async "shared:async"
import budget "shared:async/budget"
import http3 "shared:async/http/v3"
import "shared:async/tls"
import credential_store "shared:async/tls/credentials/store"

// What application code allocates with the default allocator while it serves
// a request belongs to the request: it is freed with it, the handler's state
// for a later callback included, and a body allocated that way is sent from
// where it is.

RM_LEFT :: 4096
RM_GREETING :: "kept past the request"

RM_Server :: struct {
	config:  Server,
	control: Server_Control,
	ok:      bool,
	worker:  ^thread.Thread,
}

RM_Later :: struct {
	note: string,
}

RM_Session :: struct {
	greeting: string,
	sent:     int,
}

// Answers with what the request holds on its heap, as a decimal number.
rm_held :: proc(conn: ^Connection, request: ^Request) -> Response {
	text := fmt.aprintf("%d", request_heap_bytes(conn._task), allocator = request.allocator)
	return {status = .OK, body = transmute([]u8)text}
}

// Answers "request" when the handler runs with the heap of its own request.
rm_default :: proc(conn: ^Connection) -> Response {
	ours := context.allocator == request_heap_allocator(conn._task)
	return {status = .OK, body = transmute([]u8)string("request" if ours else "other")}
}

rm_handler :: proc(_: rawptr, conn: ^Connection, request: ^Request) -> Response {
	switch request.path {
	case "/held":
		return rm_held(conn, request)
	case "/default":
		return rm_default(conn)
	case "/leak":
		// Never freed, and neither is the body: both end with the request.
		left := make([]u8, RM_LEFT)
		left[0] = 1
		body := make([]u8, 16)
		text := strconv.write_int(body, i64(request_heap_bytes(conn._task)), 10)
		return {status = .OK, body = transmute([]u8)text}
	case "/later":
		// State for the poll and the drop, with no allocator named anywhere.
		state := new(RM_Later)
		state.note = strings.clone("later")
		return {
			deferred = {
				data = state,
				poll = proc(data: rawptr, _: ^Deferred_IO) -> (Response, Deferred_Step) {
					state := cast(^RM_Later)data
					body := make([]u8, len(state.note))
					copy(body, state.note)
					return {status = .OK, body = body}, .Ready
				},
				drop = proc(data: rawptr) {
					state := cast(^RM_Later)data
					delete(state.note)
					free(state)
				},
			},
		}
	case "/session":
		// The request's own storage is released once the upgrade is
		// established. What the handler allocated by default is not.
		session := new(RM_Session)
		session.greeting = strings.clone(RM_GREETING)
		response := make_response(request, .Switching_Protocols, {{"Upgrade", "greeting"}})
		response.upgrade = {
			data = session,
			resume = proc(data: rawptr, io: ^Upgrade_IO) -> async.Resume_Result {
				session := cast(^RM_Session)data
				// Freed memory can still read as it was: ask the heap itself.
				if !request_heap_owns(io.connection._task, transmute([]u8)session.greeting) {
					return .Done
				}
				for session.sent < len(session.greeting) {
					n, error := upgrade_write(io, transmute([]u8)session.greeting[session.sent:], async.deadline_after(io.runtime, time.Minute))
					if error.kind == .Pending {
						return .Waiting
					}
					if error.kind != .None {
						return .Done
					}
					session.sent += n
				}
				return .Done
			},
			drop = proc(data: rawptr) {
				session := cast(^RM_Session)data
				delete(session.greeting)
				free(session)
			},
		}
		return response
	case "/arena":
		// As large as the operation's whole budget allows once, not twice.
		body, error := make([]u8, RM_ARENA_BODY, request.allocator)
		if error != nil {
			return {status = .Service_Unavailable}
		}
		for &value, index in body {
			value = u8('a' + index % 26)
		}
		return {status = .OK, body = body}
	}
	return {status = .Not_Found}
}

RM_OPERATION_BYTES :: 512 * mem.Kilobyte
RM_ARENA_BODY :: 300 * mem.Kilobyte

rm_start :: proc(fixture: ^RM_Server, config: Server = {}) -> (net.Endpoint, bool) {
	fixture.config = config
	fixture.config.address = "127.0.0.1"
	fixture.config.workers = 1
	fixture.config.handler = rm_handler
	fixture.config.control = &fixture.control
	fixture.config.keep_alive = {enabled = true}
	fixture.config.timeouts = {header = time.Minute, body = time.Minute, response = time.Minute, idle = time.Minute}
	fixture.worker = thread.create_and_start_with_poly_data(fixture, proc(f: ^RM_Server) {f.ok = serve(f.config)})
	until := time.tick_add(time.tick_now(), 60 * time.Second)
	for !server_ready(&fixture.control) && !thread.is_done(fixture.worker) && time.tick_diff(time.tick_now(), until) > 0 {
		time.sleep(time.Millisecond)
	}
	return server_endpoint(&fixture.control)
}

rm_stop :: proc(fixture: ^RM_Server) {
	stop_server(&fixture.control)
	thread.join(fixture.worker)
	thread.destroy(fixture.worker)
}

// Sends one request and reads its response by its Content-Length. extra is
// read after the head when the response announces no length.
rm_exchange :: proc(socket: net.TCP_Socket, path: string, fields := "", extra := 0) -> (status: int, body: string) {
	request := fmt.tprintf("GET %s HTTP/1.1\r\nHost: a\r\n%s\r\n", path, fields)
	if _, sent := net.send_tcp(socket, transmute([]u8)request); sent != nil {
		return 0, ""
	}
	wire := make([dynamic]u8, context.temp_allocator)
	buffer: [16384]u8
	head := -1
	for head < 0 {
		n, received := net.recv_tcp(socket, buffer[:])
		if n <= 0 || received != nil {
			return 0, ""
		}
		append(&wire, ..buffer[:n])
		head = strings.index(string(wire[:]), "\r\n\r\n")
	}
	text := string(wire[:head])
	if len(text) >= 12 {
		status, _ = strconv.parse_int(text[9:12])
	}
	length := extra
	for line in strings.split_lines_iterator(&text) {
		if len(line) > 15 && strings.equal_fold(line[:15], "content-length:") {
			length, _ = strconv.parse_int(strings.trim_space(line[15:]))
		}
	}
	for len(wire) < head + 4 + length {
		n, received := net.recv_tcp(socket, buffer[:])
		if n <= 0 || received != nil {
			return status, ""
		}
		append(&wire, ..buffer[:n])
	}
	return status, string(wire[head + 4:][:length])
}

rm_dial :: proc(t: ^testing.T, endpoint: net.Endpoint) -> (net.TCP_Socket, bool) {
	socket, dialed := net.dial_tcp(endpoint)
	if !testing.expect_value(t, dialed, nil) {
		return {}, false
	}
	_ = net.set_option(socket, .Receive_Timeout, time.Minute)
	return socket, true
}

// A handler runs with the request's heap. What it leaves there is gone before
// the next request of the connection starts.
@(test)
handler_allocations_end_with_the_request :: proc(t: ^testing.T) {
	fixture: RM_Server
	endpoint, ready := rm_start(&fixture)
	defer rm_stop(&fixture)
	if !testing.expect(t, ready) {
		return
	}
	socket, dialed := rm_dial(t, endpoint)
	if !dialed {
		return
	}
	defer net.close(socket)

	status, body := rm_exchange(socket, "/default")
	testing.expect_value(t, status, 200)
	testing.expect_value(t, body, "request")

	status, body = rm_exchange(socket, "/leak")
	testing.expect_value(t, status, 200)
	held, _ := strconv.parse_int(body)
	testing.expectf(t, held >= RM_LEFT, "the handler's allocations were not on the request's heap: %q", body)

	status, body = rm_exchange(socket, "/held")
	testing.expect_value(t, status, 200)
	testing.expect_value(t, body, "0")
}

// State a handler allocates for a later callback, and frees there, needs no
// allocator named: the callbacks run with the request's heap too.
@(test)
deferred_state_from_the_default_allocator_is_the_requests :: proc(t: ^testing.T) {
	fixture: RM_Server
	endpoint, ready := rm_start(&fixture)
	defer rm_stop(&fixture)
	if !testing.expect(t, ready) {
		return
	}
	socket, dialed := rm_dial(t, endpoint)
	if !dialed {
		return
	}
	defer net.close(socket)

	for _ in 0 ..< 3 {
		status, body := rm_exchange(socket, "/later")
		testing.expect_value(t, status, 200)
		testing.expect_value(t, body, "later")
	}
	status, body := rm_exchange(socket, "/held")
	testing.expect_value(t, status, 200)
	testing.expect_value(t, body, "0")
}

// An upgrade releases the request's own storage as soon as it is established.
// What the handler allocated by default stays until the connection ends.
@(test)
upgrade_state_from_the_default_allocator_outlives_the_request :: proc(t: ^testing.T) {
	fixture: RM_Server
	endpoint, ready := rm_start(&fixture)
	defer rm_stop(&fixture)
	if !testing.expect(t, ready) {
		return
	}
	socket, dialed := rm_dial(t, endpoint)
	if !dialed {
		return
	}
	defer net.close(socket)

	status, body := rm_exchange(socket, "/session", "Connection: Upgrade\r\nUpgrade: greeting\r\n", len(RM_GREETING))
	testing.expect_value(t, status, 101)
	testing.expect_value(t, body, RM_GREETING)
}

// A server that names the process heap for its handlers keeps what they
// allocate until they free it: nothing is on the request's heap.
@(test)
handler_allocator_can_be_the_process_heap :: proc(t: ^testing.T) {
	fixture: RM_Server
	endpoint, ready := rm_start(&fixture, {handler_allocator = rt.heap_allocator()})
	defer rm_stop(&fixture)
	if !testing.expect(t, ready) {
		return
	}
	socket, dialed := rm_dial(t, endpoint)
	if !dialed {
		return
	}
	defer net.close(socket)

	status, body := rm_exchange(socket, "/default")
	testing.expect_value(t, status, 200)
	testing.expect_value(t, body, "other")
}

// A body allocated with the request's allocator is sent from where it is. The
// operation's budget has room for it once: the copy the server used to make
// would not fit.
@(test)
body_the_request_owns_is_not_copied :: proc(t: ^testing.T) {
	fixture: RM_Server
	endpoint, ready := rm_start(&fixture, {resources = {operation_limits = budget.Limits{RM_OPERATION_BYTES, 1, 1}}})
	defer rm_stop(&fixture)
	if !testing.expect(t, ready) {
		return
	}
	socket, dialed := rm_dial(t, endpoint)
	if !dialed {
		return
	}
	defer net.close(socket)

	status, body := rm_exchange(socket, "/arena")
	testing.expect_value(t, status, 200)
	if testing.expect_value(t, len(body), RM_ARENA_BODY) {
		testing.expect(t, body[0] == 'a' && body[27] == 'b' && body[len(body) - 1] == u8('a' + (RM_ARENA_BODY - 1) % 26))
	}
}

// Which bodies the server keeps and which it copies, and what a kept one
// costs the operation.
@(test)
response_body_ownership_follows_its_storage :: proc(t: ^testing.T) {
	fixture: Resource_Test
	resource_test_init(&fixture)
	defer resource_test_finish(&fixture)
	task := &fixture.task
	used :: proc(fixture: ^Resource_Test) -> u64 {
		view, error := budget.snapshot(fixture.runtime.resources)
		assert(error == .None)
		return view.used.bytes
	}

	// In a block of the request's arena.
	small, _ := make([]u8, 100, task.request.allocator)
	response := Response {
		status = .OK,
		body   = small,
	}
	testing.expect(t, resource_copy_response(task, &response))
	testing.expect(t, raw_data(response.body) == raw_data(small), "a body in the request's arena was copied")

	// One of the arena's larger allocations, from its start.
	large, _ := make([]u8, 64 * mem.Kilobyte, task.request.allocator)
	before := used(&fixture)
	response = {
		status = .OK,
		body   = large,
	}
	testing.expect(t, resource_copy_response(task, &response))
	testing.expect(t, raw_data(response.body) == raw_data(large), "a large body in the request's arena was copied")
	testing.expect_value(t, used(&fixture), before)

	// The same allocation from its middle has no provenance the server can check.
	response = {
		status = .OK,
		body   = large[10:],
	}
	testing.expect(t, resource_copy_response(task, &response))
	testing.expect(t, raw_data(response.body) != raw_data(large[10:]), "a slice from the middle of an allocation was kept")

	// On the request's heap: kept, and charged to the operation for as long
	// as the request lasts.
	owned, _ := make([]u8, 32 * mem.Kilobyte, request_default_allocator(task))
	before = used(&fixture)
	response = {
		status = .OK,
		body   = owned,
	}
	testing.expect(t, resource_copy_response(task, &response))
	testing.expect(t, raw_data(response.body) == raw_data(owned), "a body on the request's heap was copied")
	testing.expect_value(t, used(&fixture), before + u64(len(owned)))

	// Anything else is a borrow, and is copied.
	borrowed := transmute([]u8)string("a static body")
	response = {
		status = .OK,
		body   = borrowed,
	}
	testing.expect(t, resource_copy_response(task, &response))
	testing.expect(t, raw_data(response.body) != raw_data(borrowed), "a borrowed body was not copied")
	testing.expect_value(t, string(response.body), "a static body")

	// A body on the request's heap that the operation has no room for is not
	// sent at all.
	huge, _ := make([]u8, 40 * mem.Megabyte, request_default_allocator(task))
	response = {
		status = .OK,
		body   = huge,
	}
	testing.expect(t, !resource_copy_response(task, &response), "a body over the operation's budget was accepted")
}

// Every HTTP/2 stream is a request of its own, with a heap of its own.
@(test)
h2_handlers_run_with_the_requests_heap :: proc(t: ^testing.T) {
	state := H2W_Server {
		idle = H2W_PATIENCE,
	}
	h2w_run(t, &state, proc(t: ^testing.T, state: ^H2W_Server, peer: ^H2W_Peer) {
		wire: [dynamic]u8
		defer delete(wire)
		h2w_get(&wire, 1, "/default")
		if !testing.expect(t, h2w_preface(peer) && h2w_send(peer, wire[:])) {
			return
		}
		body: [dynamic]u8
		defer delete(body)
		for {
			frame, ok := h2w_next(peer, true)
			if !testing.expect(t, ok && frame.kind != 7 && frame.kind != 3, "connection ended before the response") {
				return
			}
			if frame.stream != 1 || frame.kind > 1 {
				continue
			}
			if frame.kind == 0 {
				append(&body, ..frame.payload)
			}
			if frame.flags & 1 != 0 {
				break
			}
		}
		testing.expect_value(t, string(body[:]), "request")
	})
}

// So is every HTTP/3 request.
@(test)
http3_handlers_run_with_the_requests_heap :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, time.Minute)
	store := h3_limits_store()
	defer credential_store.destroy(&store)
	fixture: H3W_Server
	worker, port := h3w_start(&fixture, store)
	defer thread.destroy(worker)
	defer {
		stop_server(&fixture.control)
		thread.join(worker)
	}
	if !testing.expect(t, port > 0) {
		return
	}
	roots := h3_limits_roots()
	defer tls.root_pool_destroy(&roots)
	pool := new(http3.Pool)
	defer {
		http3.pool_close(pool)
		free(pool)
	}
	result := http3.pool_exchange_request(
		pool,
		{net.IP4_Loopback, port},
		"127.0.0.1",
		{method = "GET", target = "/default", authority = "127.0.0.1"},
		roots.roots[:roots.count],
		time.time_add(time.now(), 10 * time.Second),
	)
	testing.expect(t, result.error == .None, h3_test_error(&result))
	testing.expect_value(t, result.status, 200)
	testing.expect_value(t, h3_test_body(&result), "request")
}
