package saba_core

import h2 "shared:async/http/v2"
import "core:mem"
import "core:strings"
import budget "shared:async/budget"
import "core:time"
import async "shared:async"
import hpack "shared:async/http/hpack"
import owned "shared:async/owned"
import "core:net"
import http "shared:async/http"
import exchange "shared:async/http/exchange"
import "core:strconv"

// One serialized socket/engine owner, independent lazily allocated request and
// upgrade contexts. Policy grants are bounded by explicit resources/config.
H2_DEFAULT_STREAMS :: 32
H2_MAX_STREAMS :: 256
H2_STREAM_SLOTS :: 8 // Initial metadata only; reserve grows up to the policy bound.
H2_FRAME_BYTES :: 16384
H2_BODY_BUFFER :: 64 * 1024
H2_BODY_CHUNKS :: 8
H2_EVENTS :: 16
H2_CONTROL_FRAMES :: 8
// The engine queues a DATA frame as two parts: its 9-byte header, and its
// payload, sent from the body chunk itself. One write carries one part, so a
// queue of H2_CONTROL_FRAMES frames is at most this many writes.
H2_WRITES :: 2 * H2_CONTROL_FRAMES
// Bodies reach the engine in chunks of one full DATA frame. The engine cuts
// a frame to the chunk, the peer's SETTINGS_MAX_FRAME_SIZE (never below
// H2_FRAME_BYTES) and the flow-control windows, so a chunk leaves no short
// frame behind it.
H2_SEND_CHUNK_BYTES :: H2_FRAME_BYTES
H2_INGRESS :: 16 * 1024
// Response field tables cover the request-side header count limit plus the
// generated :status and content-length. Larger responses become a 500.
H2_NAME_SCRATCH :: 8192
H2_FIELD_CAP :: REQUEST_HEADER_COUNT_LIMIT + 8
// Allowance for peer frames that advance no request (the engine's
// Limits.unproductive_frames): RST_STREAM, provoked stream errors, PING,
// SETTINGS, PRIORITY and empty DATA. A burst, refilled per second by
// h2_refill; a peer that outruns it is closed with ENHANCE_YOUR_CALM.
H2_RESET_BURST :: 200
H2_RESET_REFILL :: 50
H2_BODY_INITIAL :: 4096

Http2_Config :: struct {
	// Zero selects 32; values through 256 bound ordinary and WebSocket streams.
	max_concurrent_streams: int,
}
HTTP2_Session :: struct {
	engine:                                    h2.Connection,
	allocator:                                 mem.Allocator,
	limits:                                    h2.Limits,
	engine_ready, failed, peer_gone, shutdown: bool,
	reap:                                      []h2.Stream_Handle,
	reap_count:                                int,
	requests:                                  []^H2_Request,
	cursor:                                    int,
	idle_deadline, read_expires:               time.Tick,
	// Set once the connection is closing with no streams left: bounds the GOAWAY
	// flush and the peer's acknowledgement. wake_deadline is a periodic owner
	// wake used when no stream or connection deadline is pending.
	close_deadline, wake_deadline:             time.Tick,
	reset_refill:                              time.Tick,
	read_deadline:                             async.Deadline,
	ingress:                                   [H2_INGRESS]u8,
	ingress_len:                               int,
	upgrades:                                  []^H2_Upgrade,
}

h2_make_limits :: proc(streams: int) -> h2.Limits {
	return {
		frame_payload_bytes = H2_FRAME_BYTES,
		streams = streams,
		reserved_streams = 0,
		header_block_bytes = REQUEST_HEADER_LIMIT,
		header_list_bytes = REQUEST_HEADER_LIMIT,
		header_fields = REQUEST_HEADER_COUNT_LIMIT,
		hpack_table_bytes = 4096,
		retained_body_bytes = H2_BODY_BUFFER,
		body_chunks = H2_BODY_CHUNKS,
		events = H2_EVENTS,
		control_frames = H2_CONTROL_FRAMES,
		pending_settings = 4,
		pending_pings = 4,
		continuation_frames = 8,
		work_per_feed = 32 * 1024,
		unproductive_frames = H2_RESET_BURST,
	}
}

http2_config_valid :: proc(config: Http2_Config) -> bool {
	return config.max_concurrent_streams >= 0 && config.max_concurrent_streams <= H2_MAX_STREAMS
}

h2_stream_allowance :: proc(task: ^Connection_Task) -> int {
	configured := task.runtime.config.http2.max_concurrent_streams

	if configured == 0 {
		configured = H2_DEFAULT_STREAMS
	}

	if configured < 1 || configured > H2_MAX_STREAMS {
		return -1
	}

	if !scope_managed(task.resource_connection) {
		return configured
	}

	view, error := budget.snapshot(task.resource_connection)
	if error != .None || view.limits.streams == 0 {
		return 0
	}

	if view.limits.streams > u64(configured) {
		return configured
	}

	return int(view.limits.streams)
}

h2_begin :: proc(task: ^Connection_Task) -> bool {
	if task.http2 != nil {
		return true
	}
	allowance := h2_stream_allowance(task)

	if allowance < 0 {
		return false
	}

	limits := h2_make_limits(allowance)
	limits.body_chunks = max(H2_BODY_CHUNKS, 2 * allowance)
	limits.retained_body_bytes = max(H2_BODY_BUFFER, 2 * allowance * H2_FRAME_BYTES)
	if h2.limits_validate(limits).kind != .None {
		return false
	}
	allocator := connection_storage_allocator(task)
	if allocator.procedure == nil {
		return false
	}
	session, alloc_error := new(HTTP2_Session, allocator)
	if alloc_error != nil || session == nil {
		return false
	}
	session.allocator = allocator
	session.limits = limits
	capacity := max(2, 2 * allowance)
	request_error, reap_error, upgrade_error: mem.Allocator_Error
	session.requests, request_error = make([]^H2_Request, allowance, allocator)
	session.reap, reap_error = make([]h2.Stream_Handle, capacity, allocator)
	session.upgrades, upgrade_error = make([]^H2_Upgrade, allowance, allocator)
	ready := request_error == nil && reap_error == nil && upgrade_error == nil

	if ready {
		options := h2.Engine_Options {
			max_stream_capacity     = capacity,
			header_sections         = 4,
			enable_push             = false,
			promise_policy          = .Decline,
			enable_connect_protocol = true,
		}

		// An absent connection scope is the zero Scope, which leaves the engine unbudgeted.
		ready =
			h2.connection_init(&session.engine, {role = .Server, limits = limits, initial_stream_capacity = min(H2_STREAM_SLOTS, capacity), scope = task.resource_connection}, options, allocator).kind ==
			.None
	}

	if !ready {
		h2_session_free(session)
		return false
	}

	session.engine_ready = true
	session.reset_refill = time.tick_now()
	session.idle_deadline = time.tick_add(time.tick_now(), task.runtime.timeouts.header)
	task.http2 = session

	return true
}

h2_session_free :: proc(session: ^HTTP2_Session) {
	allocator := session.allocator
	delete(session.requests, allocator)
	delete(session.reap, allocator)
	delete(session.upgrades, allocator)
	free(session, allocator)
}

h2_destroy :: proc(task: ^Connection_Task) {
	session := task.http2
	if session == nil {
		return
	}

	for stream in session.upgrades {
		if stream != nil {
			h2_upgrade_release(stream)
		}
	}

	for request in session.requests {
		if request != nil {
			h2_request_release(request, false, .Shutdown)
		}
	}

	task.http2 = nil

	if session.engine_ready {
		if view, borrowed := h2.connection_output_front(&session.engine); borrowed {
			_ = h2.connection_output_advance(&session.engine, view.token, 0)
		}

		for _ in 0 ..< H2_EVENTS {
			event, ok := h2.connection_poll(&session.engine)
			if !ok {
				break
			}
			_ = h2.connection_event_release(&session.engine, event.token)
		}

		_ = h2.connection_destroy(&session.engine)
	}

	h2_session_free(session)
}

h2_shutdown :: proc(task: ^Connection_Task) {
	session := task.http2
	if session == nil || !session.engine_ready || session.shutdown || session.failed {
		return
	}
	error := h2.connection_shutdown_begin(&session.engine)
	if error.kind == .None || error.kind == .Closed {
		session.shutdown = true
	}
}

h2_remember :: proc(session: ^HTTP2_Session, handle: h2.Stream_Handle) {
	if session == nil || handle.stream_id == 0 {
		return
	}

	for index in 0 ..< session.reap_count {
		if session.reap[index] == handle {
			return
		}
	}

	if session.reap_count >= len(session.reap) {
		return
	}
	session.reap[session.reap_count] = handle
	session.reap_count += 1
}

// Release a finished stream's exchange lease and metadata before the next
// HEADERS frame. The grace barrier can outlive the lease; spare slots cover that.
h2_settle :: proc(task: ^Connection_Task) {
	session := task.http2
	if session == nil || !session.engine_ready || session.failed {
		return
	}

	for _ in 0 ..< H2_STREAM_SLOTS {
		h2_pump_events(task)
		h2_pump_engine(task)
		if session.failed {
			return
		}
		kept := 0
		released := false

		for index in 0 ..< session.reap_count {
			handle := session.reap[index]
			error := h2.connection_reap(&session.engine, handle)

			if error.kind == .Invalid_State {
				session.reap[kept] = handle
				kept += 1
				continue
			}

			released = true
		}

		session.reap_count = kept
		if !released {
			return
		}
	}
}

h2_skip_response_header :: proc(name: string) -> bool {
	switch name {
	case "connection", "proxy-connection", "keep-alive", "upgrade", "transfer-encoding", "te", "content-length":
		return true
	}

	return len(name) > 0 && name[0] == ':'
}

h2_clone :: proc(value: string, allocator: mem.Allocator) -> (string, bool) {
	if len(value) == 0 {
		return "", true
	}
	copy, error := strings.clone(value, allocator)

	return copy, error == nil
}

h2_pump_events :: proc(task: ^Connection_Task) -> bool {
	session := task.http2
	progress := false

	for _ in 0 ..< H2_EVENTS {
		event, ok := h2.connection_poll(&session.engine)
		if !ok {
			break
		}
		taken := false

		// A WebSocket tunnel whose input queue is full defers this DATA event: it
		// stays at the head of the engine queue, unborrowed, and the next poll
		// returns it. Its flow-control credit stays withheld, so the peer is
		// back-pressured instead of losing the stream.
		if data, is_data := event.payload.(h2.Data_Event); is_data {
			if stream := h2_upgrade_find(task, data.stream);
			   stream != nil && stream.accepted && stream.input_count == len(stream.inputs) {
				if h2.connection_event_defer(&session.engine, event.token).kind != .None {
					session.failed = true
				}
				break
			}
		}

		progress = true

		switch value in event.payload {
		case h2.Ready_Event, h2.Peer_Settings_Event, h2.Ping_Ack_Event:
		case h2.Headers_Event:
			if value.kind == .Trailers {
				request := h2_request_find(task, value.stream)

				if request != nil && request.receiving {
					h2_request_trailers(request, value.summary.fields)
					h2_request_complete(&request.task)
				}
			} else if value.kind == .Request {
				opened: bool

				if value.summary.protocol != "" {
					opened = h2_upgrade_open(task, value)
				} else {
					opened = h2_request_open(task, value)
				}

				if !opened {
					_ = h2.connection_reset(&session.engine, value.stream, .Refused_Stream)
					h2_remember(session, value.stream)
				}
			}
		case h2.Data_Event:
			if stream := h2_upgrade_find(task, value.stream); stream != nil {
				// A refused tunnel has no reader: drop the bytes and return their credit.
				if stream.accepted {
					taken = h2_upgrade_data(stream, event, value)

					if !taken {
						_ = h2.connection_reset(&session.engine, value.stream, .Cancel)
						h2_upgrade_release(stream)
					}
				}
			} else if request := h2_request_find(task, value.stream); request != nil {
				taken = h2_request_data(request, event, value)
			}
		case h2.Stream_End_Event:
			if stream := h2_upgrade_find(task, value.stream); stream != nil {
				stream.remote_end = true
			}

			if request := h2_request_find(task, value.stream); request != nil && request.receiving {
				h2_request_complete(&request.task)
			}
		case h2.Reset_Event:
			if stream := h2_upgrade_find(task, value.stream); stream != nil {
				h2_upgrade_reset(stream)
			}

			if request := h2_request_find(task, value.stream); request != nil {
				h2_request_release(request, false, .Peer_Closed)
			}

			h2_remember(session, value.stream)
		case h2.Promise_Event:
		// promise_policy is Decline. Releasing the event is enough.
		case h2.Goaway_Event:
			session.peer_gone = value.code != .No_Error
			h2_shutdown(task)
		case h2.Terminal_Event:
			session.failed = true
		case h2.Not_Processed_Event:
			h2_remember(session, value.stream)
		}

		if !taken {
			_ = h2.connection_event_release(&session.engine, event.token)
		}
	}

	return progress
}

// Rapid reset (CVE-2023-44487) and its relatives: the engine spends one token
// of Limits.unproductive_frames per frame that advances no request and ends
// the connection itself when none are left. It has no clock, so the owner
// returns H2_RESET_REFILL tokens for every whole second that has passed.
h2_refill :: proc(session: ^HTTP2_Session) {
	elapsed := time.tick_diff(session.reset_refill, time.tick_now())

	if elapsed < time.Second {
		return
	}

	seconds := i64(elapsed / time.Second)
	session.reset_refill = time.tick_add(session.reset_refill, time.Duration(seconds) * time.Second)
	_ = h2.connection_unproductive_refill(&session.engine, int(min(seconds * H2_RESET_REFILL, H2_RESET_BURST)))
}

h2_earlier :: proc(deadline: ^time.Tick, candidate: time.Tick) {
	if candidate != (time.Tick{}) && (deadline^ == (time.Tick{}) || time.tick_diff(candidate, deadline^) > 0) {
		deadline^ = candidate
	}
}

// The earliest pending stream or connection deadline. The idle deadline counts
// only while no stream is open, and the close deadline replaces it once the
// connection is closing. An already expired deadline is never returned: the
// owner retires it in this same turn, and a zero transport budget would make
// every read and write time out before it could run.
h2_next_deadline :: proc(task: ^Connection_Task) -> time.Tick {
	session := task.http2
	deadline: time.Tick
	streams := false

	for request in session.requests {
		if request != nil {
			streams = true
			h2_earlier(&deadline, request.body_deadline if request.receiving else request.response_deadline)
		}
	}

	for stream in session.upgrades {
		if stream != nil {
			streams = true
			h2_earlier(&deadline, stream.deadline)
		}
	}

	if session.close_deadline != (time.Tick{}) {
		h2_earlier(&deadline, session.close_deadline)
	} else if !streams {
		h2_earlier(&deadline, session.idle_deadline)
	}

	if deadline == (time.Tick{}) || deadline_expired(deadline) {
		if session.wake_deadline == (time.Tick{}) || deadline_expired(session.wake_deadline) {
			session.wake_deadline = time.tick_add(time.tick_now(), task.runtime.timeouts.idle)
		}

		return session.wake_deadline
	}

	return deadline
}

// A write gets its own budget, the response timeout, ended early only by the
// close deadline once the connection is closing. Stream deadlines are when the
// owner acts on a stream, not how long a frame may take to leave: streams armed
// together expire microseconds apart, and a write bounded by the next one timed
// out, which drops the whole connection.
h2_write_deadline :: proc(task: ^Connection_Task) -> time.Tick {
	session := task.http2
	deadline := time.tick_add(time.tick_now(), task.runtime.timeouts.response)
	if session.close_deadline != (time.Tick{}) {
		h2_earlier(&deadline, session.close_deadline)
	}

	return deadline
}

// Starts the bounded close of an idle or failed connection. True only on a
// state change, so an expired deadline cannot keep the owner turn busy.
h2_check_deadlines :: proc(task: ^Connection_Task) -> bool {
	session := task.http2
	streams := h2_has_streams(task)
	progress := false

	// A connection still working through what the peer sent, or still sending
	// what it owes, is not idle: a burst of small frames read in one go can take
	// longer to answer than the idle timeout. Idleness starts when both are done.
	// The write deadline bounds a peer that never reads.
	if !streams && (session.ingress_len > 0 || h2_output_pending(session)) {
		session.idle_deadline = time.tick_add(time.tick_now(), task.runtime.timeouts.idle)
	}

	if server_is_draining(task.runtime) {
		h2_shutdown(task)
	}

	if session.close_deadline == (time.Tick{}) &&
	   !streams &&
	   (session.shutdown || session.failed || deadline_expired(session.idle_deadline)) {
		session.close_deadline = time.tick_add(time.tick_now(), task.runtime.timeouts.response)
		progress = true
	}

	if session.close_deadline != (time.Tick{}) {
		// SETTINGS still awaiting acknowledgement can defer GOAWAY; keep trying.
		h2_shutdown(task)

		if !session.peer_gone && deadline_expired(session.close_deadline) {
			// The peer neither read the GOAWAY nor closed. Stop waiting for it.
			session.peer_gone = true
			progress = true
		}
	}

	return progress
}

h2_read :: proc(task: ^Connection_Task) -> (bool, bool) {
	session := task.http2
	if session.failed || session.peer_gone {
		return false, false
	}
	if session.ingress_len == len(session.ingress) {
		return false, false
	}
	expires := h2_next_deadline(task)

	if session.read_expires != expires {
		session.read_expires = expires
		session.read_deadline = async.deadline_after(
			&task.runtime.executor,
			max(time.Duration(0), time.tick_diff(time.tick_now(), expires)),
		)
	}

	// Preserve the exact async deadline while a TLS read is outstanding. Rebuilding
	// it from two clock samples would repeatedly cancel the same read under load.
	n, error := transport_read(task, session.ingress[session.ingress_len:], session.read_deadline)

	if n > 0 {
		session.ingress_len += n
		session.idle_deadline = time.tick_add(time.tick_now(), task.runtime.timeouts.idle)
	}

	if error.kind == .Pending {
		return n > 0, true
	}

	if error.kind == .Timeout {
		if task.tls_state != nil && tls_timed_out(task.tls_state.error) {
			task.tls_state.error = nil
		}
		return n > 0, false
	}

	if error.kind != .None || n == 0 {
		session.peer_gone = true
	}

	return n > 0, false
}

h2_feed :: proc(task: ^Connection_Task) -> bool {
	session := task.http2
	if !session.engine_ready {
		return false
	}
	progress := false
	source := session.ingress[:session.ingress_len] if !session.failed else nil
	h2_refill(session)
	fed := h2.connection_feed(&session.engine, source, u32(session.limits.work_per_feed))

	if fed.consumed > 0 {
		remain := session.ingress_len - fed.consumed
		copy(session.ingress[:], session.ingress[fed.consumed:session.ingress_len])
		session.ingress_len = remain
		progress = true
	}

	if fed.error.kind != .None && h2_connection_fatal(fed.error.kind) {
		session.failed = true
		session.ingress_len = 0
	}

	if fed.status == .Backpressure && fed.reason == .Metadata {
		stats, ok := h2.connection_stats(&session.engine)

		if ok && stats.metadata_capacity < stats.max_stream_capacity {
			capacity := min(stats.max_stream_capacity, max(2 * stats.metadata_capacity, 1))

			if h2.connection_reserve_streams(&session.engine, capacity).kind == .None {
				progress = true
			}
		}
	}

	if fed.work_used > 0 {
		progress = true
	}

	return progress
}

h2_output_pending :: proc(session: ^HTTP2_Session) -> bool {
	stats, ok := h2.connection_stats(&session.engine)

	return ok && (stats.output_count > 0 || stats.output_borrowed)
}

// Writes the frames the engine has queued until the queue is empty or the
// transport would block. Returns whether bytes moved and whether the write
// is waiting for the transport.
h2_write :: proc(task: ^Connection_Task) -> (progress: bool, waiting: bool) {
	for _ in 0 ..< H2_WRITES {
		moved, blocked := h2_write_frame(task)
		progress ||= moved

		if blocked {
			return progress, true
		}

		if !moved {
			break
		}
	}

	return progress, false
}

h2_write_frame :: proc(task: ^Connection_Task) -> (bool, bool) {
	session := task.http2
	state := task.tls_state
	if state == nil {
		return false, false
	}
	// A transport that already failed or timed out a write cannot carry more.
	if session.peer_gone && !state.write_started {
		return false, false
	}
	task.deadline = async.deadline_after(
		&task.runtime.executor,
		max(0, time.tick_diff(time.tick_now(), h2_write_deadline(task))),
	)

	if state.write_started {
		n, error := transport_write(task, nil, task.deadline)
		if error.kind == .Pending {
			return false, true
		}
		view, borrowed := h2.connection_output_front(&session.engine)

		if borrowed {
			if error.kind == .None && n > 0 {
				if h2.connection_output_advance(&session.engine, view.token, n).kind != .None {
					session.failed = true
				} else if task.observed {
					task.event.bytes_sent += u64(n)
				}
			} else {
				_ = h2.connection_output_advance(&session.engine, view.token, 0)
				session.peer_gone = true
			}
		}

		return n > 0, false
	}

	if !h2_output_pending(session) {
		return false, false
	}
	view, borrowed := h2.connection_output_front(&session.engine)
	if !borrowed {
		return false, false
	}
	n, error := transport_write(task, view.bytes, task.deadline)
	if error.kind == .Pending {
		return false, true
	}

	if error.kind != .None || n <= 0 {
		_ = h2.connection_output_advance(&session.engine, view.token, 0)
		session.peer_gone = true
		return false, false
	}

	if h2.connection_output_advance(&session.engine, view.token, n).kind != .None {
		session.failed = true
	} else if task.observed {
		task.event.bytes_sent += u64(n)
	}
	return true, false
}

h2_pump_engine :: proc(task: ^Connection_Task) {
	session := task.http2
	work := u32(session.limits.work_per_feed)

	for _ in 0 ..< 4 {
		_ = h2.connection_feed(&session.engine, nil, work)
		flushed := h2.connection_flush(&session.engine, work)
		life := h2.connection_lifecycle(&session.engine, 32)
		if h2_connection_fatal(flushed.error.kind) {
			session.failed = true
		}
		if h2_connection_fatal(life.error.kind) {
			session.failed = true
		}
		if session.failed {
			break
		}
	}
}

h2_connection_fatal :: proc(kind: h2.Error_Kind) -> bool {
	switch kind {
	case .None, .Limit_Exceeded, .Allocation_Failed, .Budget_Rejected, .Closed:
		return false
	case .Invalid_Config,
	     .Invalid_State,
	     .Invalid_Input,
	     .Destination_Undersized,
	     .Overlapping_Buffers,
	     .Protocol_Violation:
		return true
	}

	return true
}

h2_finished :: proc(task: ^Connection_Task) -> bool {
	session := task.http2
	if session == nil || !session.engine_ready {
		return true
	}
	pending := h2_output_pending(session)
	writing := task.tls_state != nil && task.tls_state.write_started
	if writing {
		return false
	}
	// Queued frames cannot outlive the transport that would have carried them.
	if session.peer_gone {
		return true
	}
	if pending {
		return false
	}
	if session.failed {
		return true
	}

	if h2_has_streams(task) {
		return false
	}

	if !session.shutdown {
		return false
	}
	stats, ok := h2.connection_shutdown_status(&session.engine)
	if !ok {
		return false
	}

	return stats.phase == .Draining || stats.phase == .Complete || stats.phase == .Aborted
}

h2_step :: proc(task: ^Connection_Task) -> async.Resume_Result {
	session := task.http2
	if session == nil || !session.engine_ready {
		return .Done
	}

	if async.cancelled(&task.task) {
		if !session.failed {
			_ = h2.connection_abort(&session.engine, {kind = .Closed})
		}
		return .Done
	}

	waiting := false
	// Set while every pass of the turn moved something.
	moving := true

	for _ in 0 ..< 8 {
		progress := false
		h2_settle(task)
		if h2_check_deadlines(task) {
			progress = true
		}
		read_progress, read_wait := h2_read(task)
		if read_progress {
			progress = true
		}
		if read_wait {
			waiting = true
		}
		if h2_feed(task) {
			progress = true
		}
		if h2_pump_events(task) {
			progress = true
		}

		if h2_requests_pump(task) {
			progress = true
		}

		if h2_upgrade_pump(task) {
			progress = true
		}
		h2_pump_engine(task)
		if h2_pump_events(task) {
			progress = true
		}
		write_progress, write_wait := h2_write(task)
		if write_progress {
			progress = true
		}
		if write_wait {
			waiting = true
		}
		if h2_finished(task) {
			return .Done
		}
		if progress {
			continue
		}

		// Nothing moved this pass. With no read armed (a full ingress buffer the
		// engine cannot take yet) the timer is the only wake: wait for it rather
		// than yield straight back into the same stalled pass.
		timed := false
		if h2_has_streams(task) {
			timed =
				async.sleep_until_earlier(
					&task.runtime.executor,
					async.deadline_after(&task.runtime.executor, time.Millisecond),
				).kind ==
				.Pending
		}

		if waiting || timed {
			return .Waiting
		}
		moving = false
		break
	}

	if h2_finished(task) {
		return .Done
	}

	// The bounded turn ran out while its work was still moving: more is ready
	// now, whether or not the peer sends another byte. Yielding lets the other
	// tasks of the worker run first and then continues; waiting for a timer
	// here would cap a connection at one turn of output per tick.
	if moving {
		return .Yield
	}

	if h2_has_streams(task) || h2_output_pending(session) {
		_ = async.sleep_until_earlier(
			&task.runtime.executor,
			async.deadline_after(&task.runtime.executor, time.Millisecond),
		)
	}

	if waiting {
		return .Waiting
	}

	return .Yield
}

H2_Upgrade_Input :: struct {
	owner:  h2.Incoming_Data,
	credit: h2.Data_Token,
	offset: int,
}
H2_Upgrade :: struct {
	parent:                                                                       ^Connection_Task,
	handle:                                                                       h2.Stream_Handle,
	connection:                                                                   Connection_Task,
	response:                                                                     Response,
	accepted, headers_sent, remote_end, remote_reset, app_done, fin_sent, failed: bool,
	body_sent:                                                                    int,
	// Bounds every phase the h2 owner drives: the handshake response, a refused
	// tunnel's ordinary response and the final FIN. Zero while an accepted
	// tunnel runs, where the upgraded protocol owns its own timers.
	deadline:                                                                     time.Tick,
	inputs:                                                                       [H2_BODY_CHUNKS]H2_Upgrade_Input,
	input_head, input_count:                                                      int,
}

h2_upgrade_find :: proc(task: ^Connection_Task, handle: h2.Stream_Handle) -> ^H2_Upgrade {
	for stream in task.http2.upgrades {
		if stream != nil && stream.handle == handle {
			return stream
		}
	}

	return nil
}
h2_has_streams :: proc(task: ^Connection_Task) -> bool {
	for stream in task.http2.upgrades {
		if stream != nil {
			return true
		}
	}

	for request in task.http2.requests {
		if request != nil {
			return true
		}
	}

	return false
}
h2_upgrade_release :: proc(stream: ^H2_Upgrade) {
	if stream == nil {
		return
	}

	parent := stream.parent
	session := parent.http2

	for &entry in stream.inputs {
		if entry.credit != (h2.Data_Token{}) {
			_ = h2.connection_discard(&session.engine, entry.credit)
		}

		h2.incoming_data_destroy(&entry.owner)
	}

	task := &stream.connection
	drop_upgrade(task)
	discard_response(&stream.response)
	finish_request_context(task)
	release_task_storage(task)

	for &slot in session.upgrades {
		if slot == stream {
			slot = nil
			break
		}
	}

	h2_remember(session, stream.handle)
	session.idle_deadline = time.tick_add(time.tick_now(), parent.runtime.timeouts.idle)
	free(stream, session.allocator)
}

h2_upgrade_open :: proc(parent: ^Connection_Task, event: h2.Headers_Event) -> bool {
	session := parent.http2
	slot := -1

	for stream, i in session.upgrades {
		if stream == nil {
			slot = i
			break
		}
	}

	if slot < 0 ||
	   event.end_stream ||
	   session.shutdown ||
	   session.close_deadline != (time.Tick{}) ||
	   server_is_draining(parent.runtime) ||
	   !h2_target_valid(event.summary.path) {
		return false
	}

	stream, allocated := new(H2_Upgrade, session.allocator)

	if allocated != nil {
		return false
	}

	stream.parent = parent
	stream.handle = event.stream
	stream.deadline = time.tick_add(time.tick_now(), parent.runtime.timeouts.response)
	task := &stream.connection
	task.runtime = parent.runtime
	task.connection = {
		_task          = task,
		_secure        = true,
		_peer_identity = tls_peer_identity(&parent.connection),
		socket         = net.TCP_Socket(-1),
		_timeouts      = parent.runtime.timeouts,
	}

	if scope_managed(parent.resource_connection) {
		retained, e := budget.retain_scope(parent.resource_connection)

		if e != .None {
			free(stream, session.allocator)
			return false
		}

		task.resource_connection = retained
	}

	session.upgrades[slot] = stream

	if !start_operation_resources(task) {
		h2_upgrade_release(stream)
		return false
	}

	init_connection_arena(task)
	allocator := mem.dynamic_arena_allocator(&task.arena)
	summary := event.summary
	method, method_ok := h2_clone(summary.method, allocator)
	target, target_ok := h2_clone(summary.path, allocator)
	protocol, protocol_ok := h2_clone(summary.protocol, allocator)

	if !method_ok || !target_ok || !protocol_ok {
		h2_upgrade_release(stream)
		return false
	}

	headers, he := make([]Header, len(summary.fields) + 1, allocator)

	if he != nil {
		h2_upgrade_release(stream)
		return false
	}

	count := 0

	for field in summary.fields {
		if len(field.name) == 0 || field.name[0] == ':' {
			continue
		}

		name, nok := h2_clone(field.name, allocator)
		value, vok := h2_clone(field.value, allocator)

		if !nok || !vok {
			h2_upgrade_release(stream)
			return false
		}

		headers[count] = {name, value}
		count += 1
	}

	authority, aok := h2_clone(summary.authority, allocator)

	if !aok {
		h2_upgrade_release(stream)
		return false
	}

	headers[count] = {"host", authority}
	count += 1
	task.request = {
		resources         = task.resource_operation,
		backing_allocator = connection_storage_allocator(task),
		allocator         = allocator,
		method            = method,
		path              = target,
		protocol          = protocol,
		version           = "HTTP/2",
		headers           = headers[:count],
	}

	if at := strings.index_byte(target, '?'); at >= 0 {
		task.request.path = target[:at]
		task.request.query = target[at + 1:]
	}

	response := dispatch_request(task)

	if !resource_copy_response(task, &response) {
		discard_response(&response)
		h2_upgrade_release(stream)
		return false
	}

	if response.status == .None {
		response.status = .OK
	}

	stream.accepted =
		response.upgrade.resume != nil &&
		int(response.status) >= 200 &&
		int(response.status) < 300 &&
		!stream_present(response.stream) &&
		!deferred_present(response.deferred)
	upgrade_present := response.upgrade.resume != nil || response.upgrade.drop != nil || response.upgrade.data != nil

	if upgrade_present && !stream.accepted || stream_present(response.stream) || deferred_present(response.deferred) {
		discard_response(&response)
		response = {
			status = .Not_Implemented,
		}
	}

	if stream.accepted {
		task.upgrade = response.upgrade
		response.upgrade = {}
	}

	stream.response = response

	return true
}

h2_upgrade_data :: proc(stream: ^H2_Upgrade, event: h2.Event_View, value: h2.Data_Event) -> bool {
	session := stream.parent.http2

	if stream.input_count == len(stream.inputs) {
		return false
	}

	at := (stream.input_head + stream.input_count) % len(stream.inputs)
	entry := &stream.inputs[at]

	if h2.connection_data_take(&session.engine, event.token, &entry.owner).kind != .None {
		return false
	}

	entry.credit = value.consumption
	stream.input_count += 1

	if value.end_stream {
		stream.remote_end = true
	}

	return true
}
h2_upgrade_read :: proc(data: rawptr, destination: []u8, deadline: async.Deadline) -> (int, async.Error) {
	stream := cast(^H2_Upgrade)data
	session := stream.parent.http2

	if stream.remote_reset {
		return 0, {kind = .Cancelled}
	}

	if h2_upgrade_expired(stream, deadline) {
		return 0, {kind = .Timeout}
	}

	if len(destination) == 0 {
		return 0, {}
	}

	for stream.input_count > 0 {
		entry := &stream.inputs[stream.input_head]
		bytes, ok := h2.incoming_data_bytes(&entry.owner)

		if !ok {
			return 0, {kind = .Closed}
		}

		n := copy(destination, bytes[entry.offset:])
		entry.offset += n

		if n > 0 {
			_ = h2.connection_consume(&session.engine, entry.credit, u32(n))
		}

		if entry.offset == len(bytes) {
			if len(bytes) == 0 {
				_ = h2.connection_discard(&session.engine, entry.credit)
			}

			h2.incoming_data_destroy(&entry.owner)
			entry^ = {}
			stream.input_head = (stream.input_head + 1) % len(stream.inputs)
			stream.input_count -= 1
		}

		// Empty/padding-only DATA is legal HTTP2 framing, not WebSocket EOF.
		if n > 0 {
			return n, {}
		}
	}

	if stream.remote_end {
		return 0, {kind = .Peer_Closed}
	}

	return 0, {kind = .Pending}
}
h2_upgrade_write :: proc(data: rawptr, source: []u8, deadline: async.Deadline) -> (int, async.Error) {
	stream := cast(^H2_Upgrade)data

	if stream.remote_reset {
		return 0, {kind = .Cancelled}
	}

	if h2_upgrade_expired(stream, deadline) {
		return 0, {kind = .Timeout}
	}

	if stream.fin_sent {
		return 0, {kind = .Closed}
	}

	amount := min(len(source), H2_SEND_CHUNK_BYTES)

	if amount == 0 {
		return 0, {}
	}

	chunk, e := owned.copy_bounded(source[:amount], H2_SEND_CHUNK_BYTES, connection_storage_allocator(&stream.connection))

	if e.kind != .None {
		return 0, {kind = .Allocation_Failed}
	}

	error := h2.connection_send_data(&stream.parent.http2.engine, stream.handle, &chunk, false)

	if error.kind != .None {
		owned.destroy(&chunk)
		return 0, {kind = .Pending if error.kind == .Limit_Exceeded else .Closed}
	}

	return amount, {}
}
h2_upgrade_wait :: proc(data: rawptr, read, write: bool, deadline: async.Deadline) -> async.Error {
	stream := cast(^H2_Upgrade)data

	if stream.remote_reset {
		return {kind = .Cancelled}
	}

	if read && (stream.input_count > 0 || stream.remote_end) {
		return {}
	}

	if deadline.epoch != 0 {
		return async.sleep_until_earlier(&stream.parent.runtime.executor, deadline)
	}

	return {kind = .Pending}
}

h2_upgrade_io :: proc(stream: ^H2_Upgrade) -> Upgrade_IO {
	return {
		runtime = &stream.parent.runtime.executor,
		connection = &stream.connection.connection,
		stream_data = stream,
		stream_read = h2_upgrade_read,
		stream_write = h2_upgrade_write,
		stream_wait = h2_upgrade_wait,
	}
}

// origin-form or the OPTIONS asterisk. The engine also admits an empty path
// for non-HTTP schemes and plain CONNECT, which no handler expects.
h2_target_valid :: proc(path: string) -> bool {
	return path == "*" || (len(path) > 0 && path[0] == '/')
}

h2_status_digits :: proc(status: HTTP_Status) -> [3]u8 {
	code := int(status)

	return {u8('0' + code / 100), u8('0' + code / 10 % 10), u8('0' + code % 10)}
}

// Appends the ASCII-lowercased name to scratch and returns the view of it.
// The caller has already checked len(name) <= len(scratch)-used^.
h2_append_lower :: proc(scratch: []u8, used: ^int, name: string) -> string {
	start := used^

	for byte in transmute([]u8)name {
		lower := byte

		if lower >= 'A' && lower <= 'Z' {
			lower += 32
		}

		scratch[used^] = lower
		used^ += 1
	}

	return string(scratch[start:used^])
}

// Appends the lowercased, non-connection-specific headers as HPACK fields.
// False means the field table or name scratch is full.
h2_append_response_fields :: proc(
	fields: []hpack.Field,
	count: ^int,
	names: []u8,
	used: ^int,
	headers: []Header,
	never_index_set_cookie: bool,
	trailers := false,
) -> bool {
	for header in headers {
		if count^ == len(fields) || len(header.name) > len(names) - used^ {
			return false
		}

		lower := h2_append_lower(names, used, header.name)

		if h2_skip_response_header(lower) || trailers && trailer_field_forbidden(lower) {
			continue
		}

		fields[count^] = {lower, header.value, never_index_set_cookie && lower == "set-cookie"}
		count^ += 1
	}

	return true
}

h2_upgrade_headers :: proc(stream: ^H2_Upgrade) -> bool {
	if stream.headers_sent {
		return true
	}

	fields: [H2_FIELD_CAP]hpack.Field
	names: [H2_NAME_SCRATCH]u8
	used := 0
	count := 1
	status := h2_status_digits(stream.response.status)
	fields[0] = {":status", string(status[:]), false}

	if !h2_append_response_fields(fields[:], &count, names[:], &used, stream.response.headers, true) {
		// The response cannot be represented: answer 500 and never start the tunnel.
		drop_upgrade(&stream.connection)
		discard_response(&stream.response)
		stream.response = {
			status = .Internal_Server_Error,
		}
		stream.accepted = false
		count = 1
		status = h2_status_digits(stream.response.status)
		fields[0] = {":status", string(status[:]), false}
	}

	end := !stream.accepted && len(stream.response.body) == 0
	e := h2.connection_send_headers(&stream.parent.http2.engine, stream.handle, fields[:count], end)

	if e.kind == .Limit_Exceeded {
		return false
	}

	if e.kind != .None {
		_ = h2.connection_reset(&stream.parent.http2.engine, stream.handle, .Cancel)
		stream.app_done = true
		stream.failed = true
		return true
	}

	stream.headers_sent = true
	stream.fin_sent = end

	if stream.accepted {
		stream.deadline = {}
	}

	return true
}
h2_upgrade_pump :: proc(parent: ^Connection_Task) -> bool {
	progress := false

	for stream in parent.http2.upgrades {
		if stream == nil {
			continue
		}

		// A peer that withholds flow-control credit or never reads cannot pin the
		// stream: the owner-driven phases share one response budget.
		if deadline_expired(stream.deadline) {
			_ = h2.connection_reset(&parent.http2.engine, stream.handle, .Cancel)
			h2_upgrade_release(stream)
			progress = true
			continue
		}

		if !h2_upgrade_headers(stream) {
			continue
		}

		if stream.failed {
			h2_upgrade_release(stream)
			progress = true
			continue
		}

		if stream.fin_sent {
			stream.connection.response_finished = true
			h2_upgrade_release(stream)
			progress = true
			continue
		}

		if !stream.accepted {
			if stream.body_sent < len(stream.response.body) {
				part := stream.response.body[stream.body_sent:][:min(
					H2_SEND_CHUNK_BYTES,
					len(stream.response.body) - stream.body_sent,
				)]
				n, e := h2_upgrade_write(stream, part, {})

				if e.kind == .None {
					stream.body_sent += n
					progress = progress || n > 0
				}

				if stream.body_sent < len(stream.response.body) {
					continue
				}
			}

			stream.app_done = true
		} else if !stream.app_done {
			io := h2_upgrade_io(stream)
			result := stream.connection.upgrade.resume(stream.connection.upgrade.data, &io)

			if result == .Done {
				stream.app_done = true
				stream.deadline = time.tick_add(time.tick_now(), parent.runtime.timeouts.response)
				drop_upgrade(&stream.connection)
				progress = true
			}

			if result == .Yield {
				progress = true
			}
		}

		if stream.app_done && !stream.fin_sent {
			empty, allocation := owned.allocate(0, connection_storage_allocator(&stream.connection))

			if allocation.kind != .None {
				continue
			}

			e := h2.connection_send_data(&parent.http2.engine, stream.handle, &empty, true)

			if e.kind == .Limit_Exceeded {
				owned.destroy(&empty)
				continue
			}

			if e.kind != .None {
				owned.destroy(&empty)
			}

			stream.fin_sent = e.kind == .None

			if e.kind != .None {
				_ = h2.connection_reset(&parent.http2.engine, stream.handle, .Cancel)
			}
		}

		if stream.fin_sent || stream.app_done {
			stream.connection.response_finished = stream.fin_sent
			h2_upgrade_release(stream)
			progress = true
		}
	}

	return progress
}

h2_upgrade_expired :: proc(stream: ^H2_Upgrade, deadline: async.Deadline) -> bool {
	return deadline.epoch != 0 && async.deadline_after(&stream.parent.runtime.executor, 0).at >= deadline.at
}

h2_upgrade_reset :: proc(stream: ^H2_Upgrade) {
	stream.remote_reset = true
	cancel_request_context(stream.connection.request.cancellation, .Peer_Closed)

	if stream.accepted && stream.headers_sent && !stream.app_done {
		io := h2_upgrade_io(stream)
		// One final serialized callback observes cancellation; the owner retires the
		// stream regardless of whether application code correctly returns Done.
		_ = stream.connection.upgrade.resume(stream.connection.upgrade.data, &io)
	}

	h2_upgrade_release(stream)
}

// Only the parent task touches the engine or socket. A lazy request context owns
// the arena, cancellation, continuation and producer until its own stream ends.
H2_Request :: struct {
	parent:                                                            ^Connection_Task,
	task:                                                              Connection_Task,
	handle:                                                            h2.Stream_Handle,
	receiving, have_length, request_open, ready, headers_sent, failed: bool,
	// The peer has not ended its side of the stream; it may still be sending a
	// body the server has stopped reading (an early 413 or 400).
	body_open:                                                         bool,
	// The response is complete and queued; the stream is reset with NO_ERROR
	// once that output has drained, unless the peer ends its side first.
	awaiting_reset:                                                    bool,
	expected, limit, body_len, offset, producer_offset:                int,
	body_deadline, response_deadline:                                  time.Tick,
	response:                                                          Response,
}
h2_request_allocator :: proc(task: ^Connection_Task) -> mem.Allocator {
	allocator := budget.allocator(task.resource_binding)

	if allocator.procedure == nil {
		allocator = connection_storage_allocator(task)
	}

	return allocator
}
h2_request_find :: proc(parent: ^Connection_Task, handle: h2.Stream_Handle) -> ^H2_Request {
	for request in parent.http2.requests {
		if request != nil && request.handle == handle {
			return request
		}
	}

	return nil
}
h2_request_release :: proc(request: ^H2_Request, success: bool, status: Request_Status) {
	parent := request.parent
	task := &request.task
	session := parent.http2

	if !success {
		cancel_request_context(task.request.cancellation, status)
	}

	task.response_finished = success
	drop_deferred(task)
	drop_response_stream(task)
	discard_response(&request.response)
	finish_request_context(task)
	observe_finish(task)
	release_task_storage(task)

	for &slot in session.requests {
		if slot == request {
			slot = nil
			break
		}
	}

	h2_remember(session, request.handle)
	session.idle_deadline = time.tick_add(time.tick_now(), parent.runtime.timeouts.idle)
	free(request, session.allocator)
}
h2_request_open :: proc(parent: ^Connection_Task, event: h2.Headers_Event) -> bool {
	session := parent.http2
	slot := -1

	for request, i in session.requests {
		if request == nil {
			slot = i
			break
		}
	}

	if slot < 0 ||
	   session.shutdown ||
	   session.close_deadline != (time.Tick{}) ||
	   server_is_draining(parent.runtime) {
		return false
	}

	request, error := new(H2_Request, session.allocator)

	if error != nil {
		return false
	}

	request.parent = parent
	request.handle = event.stream
	task := &request.task
	task.runtime = parent.runtime
	task.http2 = session
	task.http2_request = request
	task.connection = {
		_task          = task,
		_secure        = true,
		_peer_identity = tls_peer_identity(&parent.connection),
		socket         = net.TCP_Socket(-1),
		_timeouts      = parent.runtime.timeouts,
	}

	if scope_managed(parent.resource_connection) {
		retained, e := budget.retain_scope(parent.resource_connection)

		if e != .None {
			free(request, session.allocator)
			return false
		}

		task.resource_connection = retained
	}

	session.requests[slot] = request

	if !start_operation_resources(task) {
		h2_request_release(request, false, .Unavailable)
		return false
	}

	init_connection_arena(task)
	previous_temp := context.temp_allocator
	defer context.temp_allocator = previous_temp
	context.temp_allocator = mem.dynamic_arena_allocator(&task.arena)

	if parent.observed && !parent.observation_finished {
		task.observed = parent.observed
		task.observed_at = parent.observed_at
		task.event = parent.event
		parent.observed = false
		parent.observation_finished = true
	} else {
		observe_start(task)
	}

	if !h2_request_decode(task, event.summary, event.end_stream) {
		_ = h2.connection_reset(&session.engine, event.stream, .Cancel)
		h2_request_release(request, false, .Failed)
	}

	return true
}
h2_request_complete :: proc(task: ^Connection_Task) {
	request := task.http2_request

	if request.failed || !request.request_open || request.ready || task.deferred.poll != nil {
		return
	}

	request.receiving = false
	previous_temp := context.temp_allocator
	defer context.temp_allocator = previous_temp
	context.temp_allocator = task.request.allocator

	if request.have_length && request.body_len != request.expected {
		request.failed = true
		return
	}

	task.request.body = task.request.body[:request.body_len]
	request.response_deadline = time.tick_add(time.tick_now(), task.runtime.timeouts.response)
	response := dispatch_request(task)

	if !h2_queue_response(task, response) {
		request.failed = true
	}
}
h2_request_emergency :: proc(task: ^Connection_Task, status: HTTP_Status) -> bool {
	request := task.http2_request
	drop_deferred(task)
	drop_response_stream(task)
	discard_response(&request.response)

	if request.headers_sent {
		request.failed = true
		return true
	}

	request.response = {
		status = status,
	}

	request.ready = true
	request.receiving = false

	if task.observed {
		task.event.status = status
	}

	if request.response_deadline == (time.Tick{}) {
		request.response_deadline = time.tick_add(time.tick_now(), task.runtime.timeouts.response)
	}

	return true
}
h2_queue_response :: proc(task: ^Connection_Task, response: Response) -> bool {
	request := task.http2_request

	if request == nil {
		discarded := response
		discard_response(&discarded)
		return false
	}

	if resource_pressure(task) {
		discarded := response
		discard_response(&discarded)
		return h2_request_emergency(task, .Service_Unavailable)
	}

	if deferred_present(response.deferred) {
		if !start_deferred(task, response, &request.parent.task) {
			return false
		}

		request.response_deadline = task.deferred_expires
		return true
	}

	prepared := response
	content_coding_prepare(&task.request, &prepared)
	if prepared.upgrade.resume != nil ||
	   prepared.upgrade.drop != nil ||
	   prepared.upgrade.data != nil ||
	   prepared.status == .Switching_Protocols {
		discard_response(&prepared)
		prepared = {
			status = .Not_Implemented,
		}
	}

	if !resource_copy_response(task, &prepared) {
		discard_response(&prepared)
		return h2_request_emergency(task, .Service_Unavailable)
	}

	if prepared.status == .None {
		prepared.status = .OK
	}

	request.response = prepared
	request.ready = true
	request.response_deadline = time.tick_add(time.tick_now(), task.runtime.timeouts.response)

	if task.observed {
		task.event.status = prepared.status
	}

	if stream_present(prepared.stream) {
		request.response.stream = {}

		if !queue_stream_response(task, prepared) {
			return false
		}

		if task.streaming != nil {
			request.response_deadline = task.streaming.expires
		}
	}

	return true
}
h2_request_trailers :: proc(request: ^H2_Request, fields: []hpack.Field) {
	task := &request.task
	allocator := mem.dynamic_arena_allocator(&task.arena)
	trailers, e := make([]Header, len(fields), allocator)

	if e != nil {
		request.failed = true
		return
	}

	for field, i in fields {
		name, nok := h2_clone(field.name, allocator)
		value, vok := h2_clone(field.value, allocator)

		if !nok || !vok {
			request.failed = true
			return
		}

		trailers[i] = {name, value}
	}

	task.request.trailers = trailers
}
h2_request_data :: proc(request: ^H2_Request, event: h2.Event_View, value: h2.Data_Event) -> bool {
	engine := &request.parent.http2.engine
	incoming: h2.Incoming_Data

	if h2.connection_data_take(engine, event.token, &incoming).kind != .None {
		return false
	}

	bytes, ok := h2.incoming_data_bytes(&incoming)

	if ok && request.receiving && !request.failed {
		if len(bytes) > request.limit - request.body_len {
			_ = h2_request_emergency(&request.task, .Content_Too_Large)
		} else if !h2_request_body_reserve(request, request.body_len + len(bytes)) {
			request.failed = true
		} else {
			copy(request.task.request.body[request.body_len:], bytes)
			request.body_len += len(bytes)

			if request.task.observed {
				request.task.event.bytes_received += u64(len(bytes))
			}
		}
	}

	_ = h2.connection_discard(engine, value.consumption)
	h2.incoming_data_destroy(&incoming)

	if value.end_stream {
		request.body_open = false
	}

	if value.end_stream && request.receiving {
		h2_request_complete(&request.task)
	}

	return true
}
// The body buffer follows the bytes actually received. A HEADERS frame alone
// never commits the whole limit, however large the application sets it.
h2_request_body_reserve :: proc(request: ^H2_Request, need: int) -> bool {
	body := request.task.request.body

	if need <= len(body) {
		return true
	}

	capacity := max(need, min(request.limit, max(2 * len(body), H2_BODY_INITIAL)))
	grown, error := mem.alloc_bytes_non_zeroed(capacity, 1, mem.dynamic_arena_allocator(&request.task.arena))

	if error != nil {
		return false
	}

	copy(grown, body[:request.body_len])
	request.task.request.body = grown

	return true
}

// Headers are copied by the engine before these bounded stack buffers expire.
h2_request_headers :: proc(request: ^H2_Request, trailers: bool) -> h2.Error {
	fields: [H2_FIELD_CAP]hpack.Field
	names: [H2_NAME_SCRATCH]u8
	used, count := 0, 0
	status: [3]u8
	length: [32]u8

	if !trailers {
		status = h2_status_digits(request.response.status)
		fields[0] = {":status", string(status[:]), false}
		count = 1
	}

	headers := request.response.headers

	if trailers {
		headers = request.response.trailers
	}

	if !h2_append_response_fields(fields[:], &count, names[:], &used, headers, false, trailers) {
		if trailers {
			// Unrepresentable trailers are dropped; the caller then ends with DATA.
			request.response.trailers = nil
			return {kind = .Limit_Exceeded}
		}

		// Too many or too long header names for one field section. The peer gets
		// an ordinary 500 rather than a reset stream.
		_ = h2_request_emergency(&request.task, .Internal_Server_Error)
		status = h2_status_digits(request.response.status)
		fields[0] = {":status", string(status[:]), false}
		count, used = 1, 0
	}

	code := int(request.response.status)
	if !trailers &&
	   count < len(fields) &&
	   code >= 200 &&
	   code != 204 &&
	   code != 304 &&
	   (http.response_body_allowed(code, request.task.request.method) || request.task.request.method == "HEAD") {
		size := i64(len(request.response.body))

		if request.task.streaming != nil {
			size = request.task.streaming.producer.content_length
		}
		if size >= 0 {
			fields[count] = {"content-length", strconv.write_int(length[:], size, 10), false}
			count += 1
		}
	}

	if trailers {
		return h2.connection_send_trailers(&request.parent.http2.engine, request.handle, fields[:count])
	}

	return h2.connection_send_headers(&request.parent.http2.engine, request.handle, fields[:count], false)
}
h2_request_output :: proc(request: ^H2_Request) -> bool {
	task := &request.task
	engine := &request.parent.http2.engine

	if !request.ready {
		return false
	}

	if pending, ok := h2.connection_stream_output_pending(engine, request.handle); !ok || pending {
		return false
	}

	// RFC 9113 section 8.1: a server that answered before the request was
	// complete may reset the stream with NO_ERROR, so the client stops
	// sending a body that will not be read.
	if request.awaiting_reset {
		if request.body_open {
			_ = h2.connection_reset(engine, request.handle, .No_Error)
		}
		h2_request_release(request, true, .Completed)
		return true
	}

	if !request.headers_sent {
		error := h2_request_headers(request, false)

		if error.kind == .Limit_Exceeded {
			return false
		}

		if error.kind != .None {
			request.failed = true
			return false
		}

		request.headers_sent = true
		return true
	}

	source: []u8
	done := !http.response_body_allowed(int(request.response.status), task.request.method)

	if !done && task.streaming != nil {
		stream := task.streaming

		if !stream.pending && !stream.terminal {
			if produce_stream(task) == .Done {
				request.failed = true
				return false
			}
		}

		if stream.pending {
			body, ok := exchange.body(&stream.exchange)

			if !ok {
				request.failed = true
				return false
			}

			source = body[request.producer_offset:]
		}

		done = stream.terminal
	} else if !done {
		source = request.response.body[request.offset:]
		done = len(source) == 0
	}

	if len(source) > 0 {
		amount := min(len(source), H2_SEND_CHUNK_BYTES)
		chunk, e := owned.copy_bounded(source[:amount], H2_SEND_CHUNK_BYTES, request.parent.http2.allocator)

		if e.kind != .None {
			request.failed = true
			return false
		}

		error := h2.connection_send_data(engine, request.handle, &chunk, false)

		if error.kind != .None {
			owned.destroy(&chunk)

			if error.kind != .Limit_Exceeded {
				request.failed = true
			}

			return false
		}

		if task.streaming != nil {
			request.producer_offset += amount

			if amount == len(source) {
				request.producer_offset = 0
				task.streaming.pending = false

				if !exchange.release_body(&task.streaming.exchange) {
					request.failed = true
				}
			}
		} else {
			request.offset += amount
		}

		return true
	}

	if !done {
		return false
	}

	if len(request.response.trailers) > 0 {
		error := h2_request_headers(request, true)

		if error.kind == .Limit_Exceeded {
			return false
		}

		if error.kind != .None {
			request.failed = true
			return false
		}
	} else {
		empty, allocation := owned.copy_bounded(nil, 0, request.parent.http2.allocator)

		if allocation.kind != .None {
			request.failed = true
			return false
		}

		// A zero-byte DATA FIN has no payload backing and consumes no body credit.
		error := h2.connection_send_data(engine, request.handle, &empty, true)

		if error.kind != .None {
			owned.destroy(&empty)

			if error.kind != .Limit_Exceeded {
				request.failed = true
			}

			return false
		}
	}

	if request.response.close_connection {
		h2_shutdown(request.parent)
	}

	if request.body_open {
		request.awaiting_reset = true
		return true
	}

	h2_request_release(request, true, .Completed)

	return true
}
h2_requests_pump :: proc(parent: ^Connection_Task) -> bool {
	previous_temp := context.temp_allocator
	defer context.temp_allocator = previous_temp
	session := parent.http2
	progress := false
	count := len(session.requests)

	for i in 0 ..< count {
		index := (session.cursor + i) % count
		request := session.requests[index]

		if request == nil {
			continue
		}

		task := &request.task
		context.temp_allocator = mem.dynamic_arena_allocator(&task.arena)
		if task.deferred.poll != nil && !request.failed {
			response, result := poll_deferred(task)
			switch result {
			case .Waiting:
			case .Ready:
				if !h2_queue_response(task, response) {
					request.failed = true
				}
				progress = true
			case .Cancelled, .Failed, .Invalid:
				request.failed = true
			}
		} else {
			deadline := request.body_deadline if request.receiving else request.response_deadline
			if deadline_expired(deadline) {
				cancel_request_context(task.request.cancellation, .Deadline)
				request.failed = true
			}
			if request_cancelled(task.request.cancellation) {
				request.failed = true
			}
		}

		if request.failed {
			_ = h2.connection_reset(&session.engine, request.handle, .Cancel)
			h2_request_release(request, false, .Failed)
			progress = true
			continue
		}

		progress = h2_request_output(request) || progress
	}

	if count > 0 {
		session.cursor = (session.cursor + 1) % count
	}

	return progress
}
h2_request_decode :: proc(task: ^Connection_Task, summary: h2.Header_Summary, end_stream: bool) -> bool {
	session := task.http2_request
	session.body_open = !end_stream

	if task.observation_finished {
		task.observed = false
		task.observation_finished = false
		task.response_finished = false
		task.event = {}
		observe_start(task)
	}

	allocator := mem.dynamic_arena_allocator(&task.arena)
	method, method_ok := h2_clone(summary.method, allocator)
	path_raw, path_ok := h2_clone(summary.path, allocator)
	authority, authority_ok := h2_clone(summary.authority, allocator)

	if !method_ok || !path_ok || !authority_ok {
		session.failed = true
		return false
	}

	path, query := path_raw, ""

	if mark := strings.index(path, "?"); mark >= 0 {
		query = path[mark + 1:]
		path = path[:mark]
	}

	regular := 0
	has_host := false

	for field in summary.fields {
		if len(field.name) == 0 || field.name[0] == ':' {
			continue
		}
		if strings.equal_fold(field.name, "host") {
			has_host = true
		}
		regular += 1
	}

	if !has_host && authority != "" {
		regular += 1
	}

	if regular > REQUEST_HEADER_COUNT_LIMIT {
		observe_failure(task, .Protocol_Error)
		return false
	}

	headers, header_error := make([]Header, regular, allocator)

	if header_error != nil {
		session.failed = true
		return false
	}

	index := 0

	for field in summary.fields {
		if len(field.name) == 0 || field.name[0] == ':' {
			continue
		}
		name, name_ok := h2_clone(field.name, allocator)
		value, value_ok := h2_clone(field.value, allocator)

		if !name_ok || !value_ok {
			session.failed = true
			return false
		}

		headers[index] = {name, value}
		index += 1
	}

	if !has_host && authority != "" {
		headers[index] = {"host", authority}
		index += 1
	}

	limit := REQUEST_BODY_LIMIT
	request := Request {
		resources         = task.resource_operation,
		backing_allocator = h2_request_allocator(task),
		allocator         = allocator,
		method            = method,
		path              = path,
		query             = query,
		version           = "HTTP/2",
		headers           = headers[:index],
		request_id        = task.event.request_id,
		_observe          = task.observed,
	}

	task.request = request

	if task.runtime.config.request_body_limit != nil {
		limit = task.runtime.config.request_body_limit(&task.request)
	}

	if limit < 0 {
		observe_failure(task, .Protocol_Error)
		return false
	}

	expected := 0
	have_length := false

	if !h2_target_valid(path) {
		observe_failure(task, .Protocol_Error)
		return h2_request_emergency(task, .Bad_Request)
	}

	if length, present := summary.content_length.?; present {
		if length > u64(max(int)) || int(length) > limit {
			observe_failure(task, .Protocol_Error)
			return h2_request_emergency(task, .Content_Too_Large)
		}

		expected = int(length)
		have_length = true
	}

	capacity := expected if have_length else limit

	task.request.has_content_length = have_length
	task.request.content_length = expected
	session.have_length = have_length
	session.expected = expected
	session.limit = capacity
	session.body_len = 0
	session.request_open = true
	session.receiving = !end_stream
	duration := body_timeout(task.runtime.timeouts, expected if have_length else 0)
	session.body_deadline = time.tick_add(time.tick_now(), duration)
	if task.observed {
		task.event.method = method
	}
	if end_stream {
		h2_request_complete(task)
	}

	return true
}
