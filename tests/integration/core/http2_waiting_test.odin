package saba_core

import rt "base:runtime"
import "core:sync"
import "core:testing"
import "core:time"
import owned "shared:async/owned"
import signal "shared:async/signal"

// What an HTTP/2 connection waits for wakes its task by itself. The task used
// to be polled every millisecond while a stream was open, and that polling
// was the only thing behind several of the wakes these tests pin.

// A deferred handler that answers once its gate is opened. Its poll keeps the
// wake that tells the connection the answer is ready.
Waiting_Gate :: struct {
	open:  bool,
	guard: sync.Mutex,
	wake:  signal.Signal,
}

waiting_gate_poll :: proc(data: rawptr, io: ^Deferred_IO) -> (Response, Deferred_Step) {
	gate := cast(^Waiting_Gate)data
	sync.lock(&gate.guard)
	if gate.wake == (signal.Signal{}) {
		gate.wake, _ = signal.retain(io.wake)
	}
	sync.unlock(&gate.guard)
	if sync.atomic_load(&gate.open) {
		return {status = .OK, body = transmute([]u8)string("later")}, .Ready
	}

	return {}, .Waiting
}

// Whether the handler behind the gate has been polled, and so holds its wake.
waiting_gate_reached :: proc(gate: ^Waiting_Gate) -> bool {
	sync.lock(&gate.guard)
	defer sync.unlock(&gate.guard)
	return gate.wake != (signal.Signal{})
}

// Opens the gate and wakes the connection that waits behind it.
waiting_gate_open :: proc(gate: ^Waiting_Gate) {
	sync.atomic_store(&gate.open, true)
	sync.lock(&gate.guard)
	wake := gate.wake
	sync.unlock(&gate.guard)
	_ = signal.wake(wake)
}

waiting_gate_close :: proc(gate: ^Waiting_Gate) {
	sync.lock(&gate.guard)
	signal.release(&gate.wake)
	sync.unlock(&gate.guard)
}

// The response of a route that answers once gate is opened.
waiting_later :: proc(gate: ^Waiting_Gate, timeout: time.Duration) -> Response {
	return {deferred = {data = gate, poll = waiting_gate_poll, drop = proc(_: rawptr) {}, timeout = timeout}}
}

// A producer that yields WAITING_YIELDS times before its one chunk. A yield
// arms no timer, so each one has to bring the next call by itself: a
// connection that waited for anything between them would not finish in time.
WAITING_YIELDS :: 400

Waiting_Yielder :: struct {
	left: int,
	sent: bool,
}

waiting_yielder_next :: proc(data: rawptr, io: ^Stream_IO) -> Stream_Step {
	producer := cast(^Waiting_Yielder)data
	if producer.sent {
		return .Done
	}
	if producer.left > 0 {
		producer.left -= 1
		return .Yield
	}
	chunk, error := owned.copy_bounded(transmute([]u8)string("yielded"), 7, io.backing_allocator)
	if error.kind != .None {
		return .Failed
	}
	if stream_submit(io, &chunk) != .Accepted {
		owned.destroy(&chunk)
		return .Failed
	}
	producer.sent = true
	return .Chunk
}

// The response of a route that streams from a Waiting_Yielder.
waiting_yields :: proc() -> Response {
	producer := new(Waiting_Yielder, rt.heap_allocator())
	producer.left = WAITING_YIELDS
	return {
		status = .OK,
		stream = {
			data = producer,
			next = waiting_yielder_next,
			drop = proc(data: rawptr) {
				free(cast(^Waiting_Yielder)data, rt.heap_allocator())
			},
			content_length = -1,
			timeout = time.Minute,
		},
	}
}

// Whether the connection takes a turn within limit of the moment it had taken
// since turns. The peer is silent meanwhile, so the turn is the server's own.
h2w_turned :: proc(session: ^HTTP2_Session, since: u64, limit: time.Duration) -> bool {
	until := time.tick_add(time.tick_now(), limit)
	for sync.atomic_load(&session.turns) == since && time.tick_diff(time.tick_now(), until) > 0 {
		time.sleep(time.Millisecond)
	}
	return sync.atomic_load(&session.turns) != since
}

// The session of the connection that served the request, once its handler ran.
h2w_parent :: proc(t: ^testing.T, state: ^H2W_Server) -> ^HTTP2_Session {
	until := time.tick_add(time.tick_now(), 30 * time.Second)
	for sync.atomic_load(&state.parent) == nil && time.tick_diff(time.tick_now(), until) > 0 {
		time.sleep(time.Millisecond)
	}
	parent := sync.atomic_load(&state.parent)
	if !testing.expect(t, parent != nil && parent.http2 != nil, "the request never reached its handler") {
		return nil
	}
	return parent.http2
}

// Reads until the server has sent its SETTINGS and acknowledged the peer's.
// The peer has answered everything by then and sends nothing more by itself,
// so nothing it does wakes the connection afterwards.
h2w_quiet :: proc(t: ^testing.T, peer: ^H2W_Peer) -> bool {
	for {
		frame, ok := h2w_next(peer, true)
		if !testing.expect(t, ok && frame.kind != 7, "connection ended before its settings were exchanged") {
			return false
		}
		if frame.kind == 4 && frame.flags & 1 != 0 {
			return true
		}
	}
}

// A connection whose only stream waits for its handler is not polled: its
// task takes a few turns, further and further apart, not one a millisecond.
@(test)
h2_waiting_connection_is_not_polled :: proc(t: ^testing.T) {
	state := H2W_Server {
		idle = H2W_PATIENCE,
	}
	h2w_run(t, &state, proc(t: ^testing.T, state: ^H2W_Server, peer: ^H2W_Peer) {
		wire: [dynamic]u8
		defer delete(wire)
		h2w_get(&wire, 1, "/hold")
		if !testing.expect(t, h2w_preface(peer) && h2w_send(peer, wire[:])) {
			return
		}
		session := h2w_parent(t, state)
		if session == nil {
			return
		}
		// The turns that carried the request are over by now.
		time.sleep(300 * time.Millisecond)
		before := sync.atomic_load(&session.turns)
		time.sleep(time.Second)
		turns := sync.atomic_load(&session.turns) - before
		testing.expectf(t, turns <= 20, "a connection that only waits ran %d turns in a second", turns)
	})
}

// A deferred response wakes its connection through its signal. By the time
// the gate opens the connection's heartbeat has slowed to its longest beat,
// and the gate opens right after one: a connection that waited for the next
// beat would not take a turn within that time.
@(test)
h2_deferred_response_wakes_its_connection :: proc(t: ^testing.T) {
	state := H2W_Server {
		idle     = H2W_PATIENCE,
		response = H2W_PATIENCE - time.Second,
	}
	h2w_run(t, &state, proc(t: ^testing.T, state: ^H2W_Server, peer: ^H2W_Peer) {
		wire: [dynamic]u8
		defer delete(wire)
		h2w_get(&wire, 1, "/later")
		if !testing.expect(t, h2w_preface(peer) && h2w_send(peer, wire[:])) || !h2w_quiet(t, peer) {
			return
		}
		session := h2w_parent(t, state)
		if session == nil {
			return
		}
		// The heartbeat doubles from a millisecond: it is at its longest by now.
		BEAT :: time.Millisecond << H2_HEARTBEAT_SHIFT
		time.sleep(BEAT + BEAT / 2)
		if !testing.expect(t, h2w_turned(session, sync.atomic_load(&session.turns), 3 * BEAT), "the waiting connection took no turn") {
			return
		}
		turn := sync.atomic_load(&session.turns)
		waiting_gate_open(&state.gate)
		testing.expect(
			t,
			h2w_turned(session, turn, BEAT - BEAT / 8),
			"the ready response did not wake its connection before the next beat",
		)
		status := 0
		for status == 0 {
			frame, ok := h2w_next(peer, true)
			if !testing.expect(t, ok && frame.kind != 7 && frame.kind != 3, "the deferred response never arrived") {
				return
			}
			if frame.stream == 1 && frame.kind == 1 {
				status = h2w_status(frame)
			}
		}
		testing.expect_value(t, status, 200)
	})
}

// A connection with no stream open has nothing that would tell it the server
// is draining: its timers, here the header and idle timeouts, are later than
// the drain's own end. It is woken for the drain, and sends its GOAWAY.
@(test)
h2_idle_connection_is_told_when_the_server_drains :: proc(t: ^testing.T) {
	state := H2W_Server {
		idle   = H2W_PATIENCE,
		header = H2W_PATIENCE,
	}
	h2w_run(t, &state, proc(t: ^testing.T, state: ^H2W_Server, peer: ^H2W_Peer) {
		wire: [dynamic]u8
		defer delete(wire)
		h2w_get(&wire, 1, "/empty")
		if !testing.expect(t, h2w_preface(peer) && h2w_send(peer, wire[:])) || !h2w_quiet(t, peer) {
			return
		}
		for {
			frame, ok := h2w_next(peer, true)
			if !testing.expect(t, ok && frame.kind != 7, "connection ended before its first response") {
				return
			}
			if frame.stream == 1 && frame.flags & 1 != 0 && (frame.kind == 0 || frame.kind == 1) {
				break
			}
		}
		session := h2w_parent(t, state)
		if session == nil {
			return
		}
		// The turns of that exchange are over by now: the connection is idle.
		time.sleep(200 * time.Millisecond)
		DRAIN :: 4 * time.Second
		turn := sync.atomic_load(&session.turns)
		if !testing.expect(t, drain_server(&state.control, DRAIN)) {
			return
		}
		testing.expect(t, h2w_turned(session, turn, DRAIN / 2), "the drain did not wake the idle connection")
		for {
			frame, ok := h2w_next(peer, true)
			if !testing.expect(t, ok, "a draining server sent an idle connection no GOAWAY") {
				return
			}
			if frame.kind == 7 {
				testing.expect_value(t, h2w_code(frame), u32(0))
				break
			}
		}
	})
}

// A producer that yields is asked again at once, as on a connection of its
// own. Between two yields nothing else happens on this connection: no byte
// arrives and no timer is set.
@(test)
h2_yielding_producer_is_asked_again_at_once :: proc(t: ^testing.T) {
	state := H2W_Server {
		idle     = H2W_PATIENCE,
		response = H2W_PATIENCE - time.Second,
	}
	h2w_run(t, &state, proc(t: ^testing.T, state: ^H2W_Server, peer: ^H2W_Peer) {
		wire: [dynamic]u8
		defer delete(wire)
		h2w_get(&wire, 1, "/yields")
		if !testing.expect(t, h2w_preface(peer) && h2w_send(peer, wire[:])) {
			return
		}
		body: [dynamic]u8
		defer delete(body)
		for {
			frame, ok := h2w_next(peer, true)
			if !testing.expect(t, ok && frame.kind != 7 && frame.kind != 3, "the yielding producer never finished") {
				return
			}
			if frame.stream != 1 || frame.kind != 0 {
				continue
			}
			append(&body, ..frame.payload)
			if frame.flags & 1 != 0 {
				break
			}
		}
		testing.expect_value(t, string(body[:]), "yielded")
	})
}
