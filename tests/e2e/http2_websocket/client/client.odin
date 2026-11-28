package main

// The client side of this program over async's HTTP/2 client facade. One task
// owns every HTTP/2 connection the client dials, the websocket sessions it
// opens over them (RFC 8441, ws_connect_h2) and the plain exchanges it makes
// on them. The main thread runs the scenario one step at a time: it posts a
// command, wakes the task and waits until the task finished it, so the
// assertions read in order as before.

import "base:runtime"
import "core:net"
import "core:sync"
import "core:time"
import async "shared:async"
import store "shared:async/tls/credentials/store"

H2_CONNS :: 2
H2_SOCKETS :: 2
H2_COMMAND_TIMEOUT :: 10 * time.Second

Command :: enum i32 {
	None,
	Dial,
	Open,
	Get,
	Send,
	Recv,
	Close,
	Shutdown,
	Quit,
}

Message :: struct {
	kind: async.WS_Message_Kind,
	data: []u8,
}

Conn :: struct {
	stream:          async.Stream,
	client:          async.H2_Client,
	dialing:         bool,
	serving:         bool,
	failed:          bool,
	closing:         bool,
	retired:         bool,
	error:           async.Error,
}

Socket :: struct {
	driver:     ^Driver,
	conn:       int,
	x:          async.H2_Exchange,
	session:    async.WS_Session,
	connecting: bool,
	bound:      bool,
	ended:      bool,
	closing:    bool,
	error:      async.Error,
	close:      async.WS_Close,
	protocol:   [64]u8,
	protocol_n: int,
	inbox:      [dynamic]Message,
}

Get :: struct {
	x:          async.H2_Exchange,
	begun:      bool,
	headed:     bool,
	status:     int,
	body:       [dynamic]u8,
	identity:   [64]u8,
	identity_n: int,
	error:      async.Error,
}

Driver :: struct {
	r:        ^async.Runtime,
	task:     async.Task,
	port:     int,
	roots:    ^async.Root_Pool,
	identity: ^store.Store,
	alpn:     [1]string,
	conns:    [H2_CONNS]Conn,
	sockets:  [H2_SOCKETS]Socket,
	get:      Get,
	// Dials that reached the address policy: one per new connection.
	dials:    int,
	// The command, written by the main thread before it wakes the task.
	command:  Command,
	target:   int,
	path:     string,
	authority: string,
	kind:     async.WS_Message_Kind,
	payload:  []u8,
	sent:     bool,
	result:   async.Error,
	message:  Message,
	done:     sync.Sema,
	finished: sync.Sema,
}

count_dial :: proc(host: string, addresses: []net.Endpoint, user: rawptr) -> bool {
	d := cast(^Driver)user
	sync.atomic_add(&d.dials, 1)

	return true
}

driver_start :: proc(d: ^Driver, port: int, roots: ^async.Root_Pool, identity: ^store.Store) {
	d.r = new(async.Runtime, runtime.heap_allocator())
	assert(async.init(d.r, {workers = 2, task_capacity = 16, io_capacity = 32}).kind == .None)
	assert(async.start(d.r).kind == .None)
	d.port, d.roots, d.identity = port, roots, identity
	d.alpn = {"h2"}
	d.task = {
		data      = d,
		resume    = driver_resume,
		on_cancel = driver_cancel,
		on_done   = proc(data: rawptr) {
			d := cast(^Driver)data
			for &c in d.conns {
				if c.serving {
					async.h2_client_destroy(&c.client)
				}
				if c.dialing {
					async.stream_destroy(&c.stream)
				}
			}
			sync.post(&d.finished)
		},
	}
	assert(async.register(d.r, &d.task).kind == .None)
}

// Ends the task and the runtime. Every connection was shut down first.
driver_stop :: proc(d: ^Driver) {
	assert(call(d, .Quit).kind == .None)
	assert(sync.sema_wait_with_timeout(&d.finished, H2_COMMAND_TIMEOUT))
	for &s in d.sockets {
		for message in s.inbox {
			delete(message.data, runtime.heap_allocator())
		}
		delete(s.inbox)
	}
	delete(d.get.body)
	assert(async.wait_idle(d.r).kind == .None)
	async.shutdown(d.r)
	assert(async.join(d.r).kind == .None)
	assert(async.destroy(d.r).kind == .None)
	free(d.r, runtime.heap_allocator())
}

// Runs one command on the task and waits until it is done.
call :: proc(d: ^Driver, command: Command, target := 0) -> async.Error {
	d.target = target
	d.result = {}
	d.sent = false
	sync.atomic_store(&d.command, command)
	async.wake(d.r, &d.task)
	if !sync.sema_wait_with_timeout(&d.done, H2_COMMAND_TIMEOUT) {
		panic("the client task did not finish its command in time")
	}

	return d.result
}

driver_cancel :: proc(data: rawptr) -> async.Resume_Result {
	d := cast(^Driver)data
	for &s in d.sockets {
		if s.bound && !s.ended {
			async.ws_session_destroy(&s.session)
			async.h2_exchange_destroy(&s.x)
			s.ended = true
		}
	}
	if d.get.begun {
		async.h2_exchange_destroy(&d.get.x)
		d.get.begun = false
	}
	result := async.Resume_Result.Done
	for &c in d.conns {
		if c.serving && !c.retired {
			if async.h2_client_cancel(&c.client) != .Done {
				result = .Waiting
			}
		} else if c.dialing && !c.retired {
			if stream_settle(&c.stream) != .Done {
				result = .Waiting
			}
		}
	}

	return result
}

driver_resume :: proc(data: rawptr) -> async.Resume_Result {
	d := cast(^Driver)data
	command := sync.atomic_load(&d.command)
	if command == .Quit {
		sync.atomic_store(&d.command, .None)
		sync.post(&d.done)
		return .Done
	}
	if command != .None && command_step(d, command, true) {
		sync.atomic_store(&d.command, .None)
		sync.post(&d.done)
		command = .None
	}

	result := async.Resume_Result.Waiting
	for &c, i in d.conns {
		if !c.dialing || c.retired {
			continue
		}
		if conn_step(d, &c, i) == .Yield {
			result = .Yield
		}
	}
	if command != .None && command_step(d, command, false) {
		sync.atomic_store(&d.command, .None)
		sync.post(&d.done)
	}

	return result
}

conn_step :: proc(d: ^Driver, c: ^Conn, index: int) -> async.Resume_Result {
	if c.failed {
		settled := stream_settle(&c.stream)
		if settled == .Done {
			c.retired = true
			return .Yield
		}
		return settled
	}
	if !c.serving {
		_ = async.stream_drive(&c.stream)
		error := async.dial_finish(&c.stream)
		if error.kind == .Pending {
			return .Waiting if async.stream_wait(&c.stream, false, false, {}).kind == .Pending else .Yield
		}
		if error.kind == .None {
			error = async.h2_client_begin(&c.client, &d.task, &c.stream, {})
		}
		if error.kind != .None {
			c.error = error
			c.failed = true
			async.stream_abort(&c.stream)
			return .Yield
		}
		c.serving = true
		return .Yield
	}
	result := async.Resume_Result.Waiting
	for &s in d.sockets {
		if s.conn != index || !s.bound || s.ended {
			continue
		}
		// Each session's resume ends with the client's own.
		switch async.ws_session_resume(&s.session) {
		case .Done:
			socket_end(&s)
			result = .Yield
		case .Yield:
			result = .Yield
		case .Waiting:
		}
	}
	// Once more for the client itself: after a session ended, and for the
	// exchanges and the connection when no session is open.
	switch async.h2_client_resume(&c.client) {
	case .Done:
		c.error = async.h2_client_failure(&c.client).error
		c.retired = true
		result = .Yield
	case .Yield:
		result = .Yield
	case .Waiting:
	}

	return result
}

// Aborts a Stream and drives it until it is quiescent.
stream_settle :: proc(s: ^async.Stream) -> async.Resume_Result {
	async.stream_abort(s)
	_ = async.stream_drive(s)
	if async.stream_quiescent(s) {
		return .Done
	}

	return .Waiting if async.stream_wait(s, false, false, {}).kind == .Pending else .Yield
}

socket_end :: proc(s: ^Socket) {
	s.close, _ = async.ws_session_closed(&s.session)
	if s.protocol_n == 0 {
		s.protocol_n = copy(s.protocol[:], async.ws_session_protocol(&s.session))
	}
	async.ws_session_destroy(&s.session)
	async.h2_exchange_destroy(&s.x)
	s.ended = true
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
			s.protocol_n = copy(s.protocol[:], async.ws_session_protocol(session))
		},
		user = s,
	}
}

// One pass over the current command. act: the pass before the connections
// were resumed, when h2_ calls are allowed. True once the command is done,
// with its result in d.result.
command_step :: proc(d: ^Driver, command: Command, act: bool) -> bool {
	#partial switch command {
	case .Dial:
		c := &d.conns[d.target]
		if act && !c.dialing {
			c^ = {}
			config := async.Dial_Config {
				host           = "127.0.0.1",
				port           = d.port,
				deadline       = async.deadline_after(d.r, 5 * time.Second),
				address_policy = count_dial,
				policy_user    = d,
				tls            = async.Dial_TLS {
					server_name        = "localhost",
					roots              = d.roots,
					alpn               = d.alpn[:],
					client_credentials = d.identity,
				},
			}
			c.dialing = true
			if error := async.dial_begin(&c.stream, &d.task, config); error.kind != .None {
				c.failed, c.error = true, error
			}
		}
		if c.serving || c.failed || c.retired {
			d.result = c.error
			return true
		}
	case .Open:
		s := &d.sockets[d.target]
		c := &d.conns[s.conn]
		if act && !s.bound && !s.ended {
			s.driver = d
			s.connecting = true
			options := async.WS_Client_Options {
				authority    = d.authority,
				path         = "/socket",
				origin       = "https://allowed.invalid",
				subprotocols = {"chat.v2"},
			}
			config := async.WS_Config {
				max_frame_bytes = 256 * 1024,
				events          = socket_events(s),
			}
			error := async.ws_connect_h2(&c.client, &s.x, options, &s.session, config)
			if error.kind == .None {
				s.bound = true
			} else if error.kind != .Pending {
				s.error = error
				s.ended = true
			}
		}
		if s.ended {
			d.result = s.error if s.error.kind != .None else s.close.error
			if d.result.kind == .None {
				d.result = {kind = .Closed}
			}
			return true
		}
		if s.bound && async.ws_session_protocol(&s.session) != "" {
			s.protocol_n = copy(s.protocol[:], async.ws_session_protocol(&s.session))
			return true
		}
	case .Get:
		g := &d.get
		c := &d.conns[d.target]
		if !act {
			return false
		}
		if !g.begun {
			clear(&g.body)
			g.status, g.identity_n, g.headed, g.error = 0, 0, false, {}
			request := async.Http_Request {
				method = .GET,
				url    = d.path,
			}
			error := async.h2_exchange_begin(&c.client, &g.x, &request)
			if error.kind == .Pending {
				return false
			}
			if error.kind != .None {
				d.result = error
				return true
			}
			g.begun = true
		}
		if !g.headed {
			head, error := async.h2_exchange_head(&g.x)
			if error.kind == .Pending {
				return false
			}
			if error.kind != .None {
				return get_end(d, error)
			}
			g.headed = true
			g.status = head.status
			for header in head.headers {
				if header.name == "x-client-identity" {
					g.identity_n = copy(g.identity[:], header.value)
				}
			}
		}
		buffer: [4096]u8
		for {
			n, error := async.h2_exchange_read(&g.x, buffer[:])
			if n > 0 {
				append(&g.body, ..buffer[:n])
				continue
			}
			if error.kind == .Peer_Closed {
				return get_end(d, {})
			}
			if error.kind == .Pending || error.kind == .None {
				return false
			}
			return get_end(d, error)
		}
	case .Send:
		s := &d.sockets[d.target]
		if act && !d.sent {
			error := async.ws_message_send(&s.session, d.kind, d.payload)
			if error.kind == .Pending {
				return false
			}
			d.sent = true
			d.result = error
			return true
		}
	case .Recv:
		s := &d.sockets[d.target]
		if len(s.inbox) > 0 {
			d.message = pop_front(&s.inbox)
			return true
		}
		if s.ended {
			d.result = s.close.error if s.close.error.kind != .None else async.Error{kind = .Closed}
			return true
		}
	case .Close:
		s := &d.sockets[d.target]
		if act && !s.closing && !s.ended {
			s.closing = true
			d.result = async.ws_close(&s.session, 1000, "")
		}
		if s.ended {
			return true
		}
	case .Shutdown:
		c := &d.conns[d.target]
		if act && !c.closing && c.serving && !c.retired {
			c.closing = true
			d.result = async.h2_client_shutdown(&c.client, {})
		}
		if c.retired || !c.serving {
			return true
		}
	}

	return false
}

get_end :: proc(d: ^Driver, error: async.Error) -> bool {
	g := &d.get
	g.error = error
	async.h2_exchange_destroy(&g.x)
	g.begun = false
	d.result = error

	return true
}
