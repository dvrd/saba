package main

// The client side of this program over async's HTTP/3 client facade. Every
// websocket (RFC 9220, ws_connect_h3) runs on a task of its own, as does every
// plain exchange; all of them share one H3_Pool. The main thread runs the
// scenario one step at a time: it posts a command to a task, wakes it and
// waits until the task finished it, so the assertions read in order.
//
// A lane (QUIC connection) of the pool carries one exchange or one tunnel at a
// time, so each websocket holds a lane of its own while it is open and the
// plain requests share another.

import "base:runtime"
import "core:net"
import "core:sync"
import "core:time"
import async "shared:async"
import h3 "shared:async/http/v3"
import store "shared:async/tls/credentials/store"

H3_COMMAND_TIMEOUT :: 10 * time.Second

Client :: struct {
	r:         ^async.Runtime,
	pool:      ^async.H3_Pool,
	roots:     ^async.Root_Pool,
	identity:  ^store.Store,
	port:      int,
	// The origin requests name; the pool dials 127.0.0.1:port for it.
	authority: string,
	// Dials that reached the address policy: one per new lane.
	dials:     int,
}

count_dial :: proc(host: string, addresses: []net.Endpoint, user: rawptr) -> bool {
	c := cast(^Client)user
	sync.atomic_add(&c.dials, 1)

	return true
}

client_start :: proc(c: ^Client, port: int, authority: string, roots: ^async.Root_Pool, identity: ^store.Store) {
	c.r = new(async.Runtime, runtime.heap_allocator())
	assert(async.init(c.r, {workers = 2, task_capacity = 32, io_capacity = 64}).kind == .None)
	assert(async.start(c.r).kind == .None)
	c.pool = new(async.H3_Pool, runtime.heap_allocator())
	config := async.H3_Pool_Config {
		max_lanes = 8,
		qpack     = {table_capacity = 4096, blocked_streams = 4},
		allocator = runtime.heap_allocator(),
	}
	assert(async.h3_pool_init(c.pool, config).kind == .None)
	c.port, c.authority, c.roots, c.identity = port, authority, roots, identity
}

client_stop :: proc(c: ^Client) {
	assert(async.wait_idle(c.r).kind == .None)
	assert(async.h3_pool_destroy(c.pool).kind == .None)
	free(c.pool, runtime.heap_allocator())
	async.shutdown(c.r)
	assert(async.join(c.r).kind == .None)
	assert(async.destroy(c.r).kind == .None)
	free(c.r, runtime.heap_allocator())
}

client_dial :: proc(c: ^Client) -> async.Dial_Config {
	return {
		host = "127.0.0.1",
		port = c.port,
		deadline = async.deadline_after(c.r, 5 * time.Second),
		address_policy = count_dial,
		policy_user = c,
		tls = async.Dial_TLS{server_name = "localhost", roots = c.roots, client_credentials = c.identity},
	}
}

// Runs f on the pool's capsule under the pool's lock.
with_pool :: proc(c: ^Client, f: proc(pool: ^h3.Pool, user: rawptr), user: rawptr = nil) {
	sync.lock(&c.pool._mutex)
	defer sync.unlock(&c.pool._mutex)
	f(&c.pool._pool, user)
}

// Drains every lane gracefully, as a client that goes away does: each sends
// GOAWAY, then what it still queued (a stream reset included), then closes
// with H3_NO_ERROR. Every exchange and tunnel has ended first. True once
// nothing is pending.
client_drain :: proc(c: ^Client, timeout: time.Duration = 3 * time.Second) -> bool {
	with_pool(c, proc(pool: ^h3.Pool, _: rawptr) {h3.pool_drain(pool)})
	deadline := time.time_add(time.now(), timeout)
	for time.diff(time.now(), deadline) > 0 {
		pending := true
		with_pool(c, proc(pool: ^h3.Pool, user: rawptr) {
			deadline := (cast(^time.Time)user)^
			_ = h3.pool_maintain(pool, deadline)
		}, &deadline)
		with_pool(c, proc(pool: ^h3.Pool, user: rawptr) {
			(cast(^bool)user)^ = h3.pool_pending(pool)
		}, &pending)
		if !pending {
			return true
		}
		time.sleep(time.Millisecond)
	}

	return false
}

// --- one plain exchange on its own task ---

Get :: struct {
	client:     ^Client,
	task:       async.Task,
	url:        string,
	x:          async.H3_Exchange,
	begun:      bool,
	headed:     bool,
	status:     int,
	body:       [dynamic]u8,
	identity:   [64]u8,
	identity_n: int,
	error:      async.Error,
	failure:    async.H3_Failure,
	done:       sync.Sema,
}

get_resume :: proc(data: rawptr) -> async.Resume_Result {
	g := cast(^Get)data
	if !g.begun {
		request := async.Http_Request {
			method = .GET,
			url    = g.url,
		}
		if error := async.h3_exchange_begin(g.client.pool, &g.x, &g.task, &request, -1, client_dial(g.client)); error.kind != .None {
			g.error = error
			g.failure = async.h3_exchange_failure(&g.x)
			return .Done
		}
		g.begun = true
		_ = async.h3_exchange_finish(&g.x)
	}
	if ended, result := get_take(g); ended {
		return result
	}
	result := async.h3_exchange_resume(&g.x)
	if result == .Done {
		// The response is complete: take what the resume brought in.
		if ended, taken := get_take(g); ended {
			return taken
		}
		return get_end(g, {kind = .Closed})
	}

	return result
}

// Takes the head and the body that arrived. True once the exchange ended.
get_take :: proc(g: ^Get) -> (bool, async.Resume_Result) {
	if !g.headed {
		head, error := async.h3_exchange_head(&g.x)
		if error.kind == .None {
			g.headed = true
			g.status = head.status
			for header in head.headers {
				if header.name == "x-client-identity" {
					g.identity_n = copy(g.identity[:], header.value)
				}
			}
		} else if error.kind != .Pending {
			return true, get_end(g, error)
		}
	}
	if g.headed {
		buffer: [4096]u8
		for {
			n, error := async.h3_exchange_read(&g.x, buffer[:])
			if n > 0 {
				append(&g.body, ..buffer[:n])
				continue
			}
			if error.kind == .Peer_Closed {
				return true, get_end(g, {})
			}
			if error.kind != .Pending && error.kind != .None {
				return true, get_end(g, error)
			}
			break
		}
	}

	return false, .Waiting
}

get_end :: proc(g: ^Get, error: async.Error) -> async.Resume_Result {
	g.error = error
	g.failure = async.h3_exchange_failure(&g.x)
	async.h3_exchange_destroy(&g.x)

	return .Done
}

// GETs path and waits for the whole response. Free the result with
// get_destroy.
get :: proc(c: ^Client, path: string) -> ^Get {
	g := new(Get, runtime.heap_allocator())
	g.client = c
	g.url = concat("https://", c.authority, path)
	g.body.allocator = runtime.heap_allocator()
	g.task = {
		data    = g,
		resume  = get_resume,
		on_done = proc(data: rawptr) {sync.post(&(cast(^Get)data).done)},
	}
	assert(async.spawn(c.r, &g.task).kind == .None)
	if !sync.sema_wait_with_timeout(&g.done, H3_COMMAND_TIMEOUT) {
		panic("the exchange did not finish in time")
	}

	return g
}

get_destroy :: proc(g: ^Get) {
	delete(g.body)
	delete(g.url, runtime.heap_allocator())
	free(g, runtime.heap_allocator())
}

concat :: proc(parts: ..string) -> string {
	n := 0
	for part in parts {
		n += len(part)
	}
	out := make([]u8, n, runtime.heap_allocator())
	at := 0
	for part in parts {
		at += copy(out[at:], part)
	}

	return string(out)
}

// --- one websocket on its own task ---

Command :: enum i32 {
	None,
	Open,
	Send,
	Recv,
	Close,
}

Message :: struct {
	kind: async.WS_Message_Kind,
	data: []u8,
}

Socket :: struct {
	client:     ^Client,
	task:       async.Task,
	config:     async.WS_Config,
	tunnel:     async.H3_Client_Tunnel,
	session:    async.WS_Session,
	started:    bool,
	open:       bool,
	closing:    bool,
	// The session ended; the tunnel freed itself.
	ended:      bool,
	error:      async.Error,
	close:      async.WS_Close,
	failure:    async.H3_Failure,
	status:     int,
	protocol:   [64]u8,
	protocol_n: int,
	// The lane the tunnel held, once it opened.
	lane:       ^h3.Client,
	inbox:      [dynamic]Message,
	// The command, written by the main thread before it wakes the task.
	command:    Command,
	kind:       async.WS_Message_Kind,
	payload:    []u8,
	result:     async.Error,
	message:    Message,
	done:       sync.Sema,
	retired:    sync.Sema,
}

socket_events :: proc(s: ^Socket) -> async.WS_Events {
	return {
		on_message = proc(session: ^async.WS_Session, message: ^async.WS_Message, user: rawptr) {
			s := cast(^Socket)user
			data := make([]u8, len(message.payload), runtime.heap_allocator())
			copy(data, message.payload)
			append(&s.inbox, Message{message.kind, data})
		},
		on_close = proc(session: ^async.WS_Session, close: ^async.WS_Close, user: rawptr) {
			s := cast(^Socket)user
			s.close = close^
		},
		user = s,
	}
}

socket_resume :: proc(data: rawptr) -> async.Resume_Result {
	s := cast(^Socket)data
	if !s.started {
		s.started = true
		options := async.WS_Client_Options {
			authority    = s.client.authority,
			path         = "/socket",
			origin       = "https://allowed.invalid",
			subprotocols = {"chat.v2"},
		}
		config := s.config
		config.max_frame_bytes = 256 * 1024
		config.events = socket_events(s)
		error := async.ws_connect_h3(s.client.pool, &s.tunnel, &s.task, options, client_dial(s.client), &s.session, config)
		if error.kind != .None {
			s.error = error
			s.failure = async.h3_tunnel_failure(&s.tunnel)
			s.ended = true
			socket_settle(s)
			return .Done
		}
	}
	socket_command(s, true)
	result := async.ws_session_resume(&s.session)
	if !s.open && async.ws_session_protocol(&s.session) != "" {
		s.open = true
		s.protocol_n = copy(s.protocol[:], async.ws_session_protocol(&s.session))
		s.status, _ = async.h3_tunnel_response(&s.tunnel)
		sync.lock(&s.client.pool._mutex)
		if s.tunnel._connect != nil {
			s.lane = s.tunnel._connect.owner
		}
		sync.unlock(&s.client.pool._mutex)
	}
	if result == .Done {
		socket_end(s)
	}
	socket_command(s, false)

	return result
}

socket_end :: proc(s: ^Socket) {
	if s.ended {
		return
	}
	s.close, _ = async.ws_session_closed(&s.session)
	if s.status == 0 {
		s.status, _ = async.h3_tunnel_response(&s.tunnel)
	}
	s.failure = async.h3_tunnel_failure(&s.tunnel)
	async.ws_session_destroy(&s.session)
	s.ended = true
}

// The task ended: a command still waiting is answered.
socket_settle :: proc(s: ^Socket) {
	if sync.atomic_load(&s.command) != .None {
		socket_command(s, false)
		if sync.atomic_load(&s.command) != .None {
			s.result = {kind = .Closed}
			sync.atomic_store(&s.command, .None)
			sync.post(&s.done)
		}
	}
}

socket_command :: proc(s: ^Socket, act: bool) {
	command := sync.atomic_load(&s.command)
	finished := false
	#partial switch command {
	case .Open:
		if s.open {
			finished = true
		} else if s.ended {
			s.result = s.error if s.error.kind != .None else s.close.error
			if s.result.kind == .None {
				s.result = {kind = .Closed}
			}
			finished = true
		}
	case .Send:
		if act && !s.ended {
			error := async.ws_message_send(&s.session, s.kind, s.payload)
			if error.kind != .Pending {
				s.result = error
				finished = true
			}
		} else if s.ended {
			s.result = {kind = .Closed}
			finished = true
		}
	case .Recv:
		if len(s.inbox) > 0 {
			s.message = pop_front(&s.inbox)
			finished = true
		} else if s.ended {
			s.result = s.close.error if s.close.error.kind != .None else async.Error{kind = .Closed}
			finished = true
		}
	case .Close:
		if act && !s.closing && !s.ended {
			s.closing = true
			s.result = async.ws_close(&s.session, 1000, "")
		}
		finished = s.ended
	}
	if finished {
		sync.atomic_store(&s.command, .None)
		sync.post(&s.done)
	}
}

// Opens a websocket on a task of its own and waits until it is open (or
// failed). Free it with socket_destroy once it ended.
socket_open :: proc(c: ^Client, config: async.WS_Config = {}) -> (^Socket, async.Error) {
	s := new(Socket, runtime.heap_allocator())
	s.client = c
	s.config = config
	s.inbox.allocator = runtime.heap_allocator()
	s.task = {
		data      = s,
		resume    = socket_resume,
		on_cancel = proc(data: rawptr) -> async.Resume_Result {
			s := cast(^Socket)data
			if !s.started || s.ended {
				return .Done
			}
			result := async.ws_session_cancel(&s.session)
			if result == .Done {
				socket_end(s)
			}
			return result
		},
		on_done   = proc(data: rawptr) {
			s := cast(^Socket)data
			if s.started && !s.ended {
				socket_end(s)
			}
			socket_settle(s)
			sync.post(&s.retired)
		},
	}
	sync.atomic_store(&s.command, .Open)
	assert(async.spawn(c.r, &s.task).kind == .None)
	if !sync.sema_wait_with_timeout(&s.done, H3_COMMAND_TIMEOUT) {
		panic("the websocket did not open in time")
	}

	return s, s.result
}

socket_call :: proc(s: ^Socket, command: Command) -> async.Error {
	s.result = {}
	sync.atomic_store(&s.command, command)
	async.wake(s.client.r, &s.task)
	if !sync.sema_wait_with_timeout(&s.done, H3_COMMAND_TIMEOUT) {
		panic("the websocket task did not finish its command in time")
	}

	return s.result
}

socket_send :: proc(s: ^Socket, kind: async.WS_Message_Kind, payload: []u8) -> async.Error {
	s.kind, s.payload = kind, payload

	return socket_call(s, .Send)
}

// The next message; its data is the caller's (heap allocator).
socket_receive :: proc(s: ^Socket) -> (async.WS_Message_Kind, []u8, async.Error) {
	error := socket_call(s, .Recv)

	return s.message.kind, s.message.data, error
}

// Runs the close handshake and waits until the tunnel closed.
socket_close :: proc(s: ^Socket) -> async.Error {
	error := socket_call(s, .Close)
	socket_wait(s)

	return error
}

// Abandons the websocket at once: the task is cancelled and the tunnel reset
// with H3_REQUEST_CANCELLED.
socket_cancel :: proc(s: ^Socket) {
	assert(async.cancel(s.client.r, &s.task).kind == .None)
	socket_wait(s)
}

socket_wait :: proc(s: ^Socket) {
	if !sync.sema_wait_with_timeout(&s.retired, H3_COMMAND_TIMEOUT) {
		panic("the websocket task did not end in time")
	}
	// Posted once; keep it posted for another wait.
	sync.post(&s.retired)
}

socket_protocol :: proc(s: ^Socket) -> string {
	return string(s.protocol[:s.protocol_n])
}

socket_destroy :: proc(s: ^Socket) {
	for message in s.inbox {
		delete(message.data, runtime.heap_allocator())
	}
	delete(s.inbox)
	free(s, runtime.heap_allocator())
}
