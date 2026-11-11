package saba_core

import h2 "shared:http/v2"
import "core:mem"
import "core:strings"
import budget "core:sync/budget"
import "core:time"
import async "shared:async"

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
H2_INGRESS :: 16 * 1024
H2_NAME_SCRATCH :: 2048
H2_FIELD_CAP :: 64

Http2_Config :: struct {
 // Zero selects 32; values through 256 bound ordinary and WebSocket streams.
 max_concurrent_streams:int,
}
HTTP2_Session :: struct {
 engine:h2.Connection,
 allocator:mem.Allocator,
 limits:h2.Limits,
 engine_ready,failed,peer_gone,shutdown:bool,
 reap:[]h2.Stream_Handle,
 reap_count:int,
 requests:[]^H2_Request,
 cursor:int,
 idle_deadline,read_expires:time.Tick,
 read_deadline:async.Deadline,
 ingress:[H2_INGRESS]u8,
 ingress_len:int,
 upgrades:[]^H2_Upgrade,
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
	}
}

// Exactly the negotiated token. Absent ALPN, http/1.1 and h3 stay off this path.
h2_selected_protocol :: proc(protocol: string) -> bool {
	return protocol == "h2"
}

http2_config_valid :: proc(config:Http2_Config)->bool {return config.max_concurrent_streams>=0 && config.max_concurrent_streams<=H2_MAX_STREAMS}

@(private)
h2_stream_allowance :: proc(task: ^Connection_Task) -> int {
	configured:=task.runtime.config.http2.max_concurrent_streams
 if configured==0 {configured=H2_DEFAULT_STREAMS}
 if configured<1 || configured>H2_MAX_STREAMS {return -1}
 if !budget.same_scope(task.resource_connection, task.resource_connection) {return configured}
	view, error := budget.snapshot(task.resource_connection)
	if error != .None || view.limits.streams == 0 do return 0
	if view.limits.streams > u64(configured) {return configured}
	return int(view.limits.streams)
}

@(private)
h2_begin :: proc(task: ^Connection_Task) -> bool {
	if task.http2 != nil do return true
	allowance := h2_stream_allowance(task)
	if allowance<0 {return false}
 limits := h2_make_limits(allowance)
 limits.body_chunks=max(H2_BODY_CHUNKS,2*allowance)
 limits.retained_body_bytes=max(H2_BODY_BUFFER,2*allowance*H2_FRAME_BYTES)
	if h2.limits_validate(limits).kind != .None do return false
	allocator := connection_storage_allocator(task)
	if allocator.procedure == nil do return false
	session, alloc_error := new(HTTP2_Session, allocator)
	if alloc_error != nil || session == nil do return false
	session.allocator = allocator
	session.limits = limits
 requests,request_error:=make([]^H2_Request,allowance,allocator)
 reap,reap_error:=make([]h2.Stream_Handle,max(2,2*allowance),allocator)
 upgrades,upgrade_error:=make([]^H2_Upgrade,allowance,allocator)
 if request_error!=nil || reap_error!=nil || upgrade_error!=nil {delete(requests,allocator);delete(reap,allocator);delete(upgrades,allocator);free(session,allocator);return false}
 session.requests=requests;session.reap=reap;session.upgrades=upgrades
	scope: budget.Scope
	if budget.same_scope(task.resource_connection, task.resource_connection) {
		scope = task.resource_connection
	}
	options := h2.Engine_Options{
		max_stream_capacity = max(2,2*allowance),
		control_frame_bytes = 256,
		header_sections = 4,
		enable_push = false,
		promise_policy = .Decline,
		enable_connect_protocol = true,
	}
	init_error := h2.connection_init(&session.engine, {
		role = .Server, limits = limits, initial_stream_capacity = min(H2_STREAM_SLOTS,max(2,2*allowance)), scope = scope,
	}, options, allocator)
	if init_error.kind != .None {
		delete(session.requests,allocator);delete(session.reap,allocator);delete(session.upgrades,allocator)
  free(session, allocator)
		return false
	}
	session.engine_ready = true
	session.idle_deadline = time.tick_add(time.tick_now(), task.runtime.timeouts.header)
	task.http2 = session
	return true
}

@(private)
h2_destroy :: proc(task: ^Connection_Task) {
	session := task.http2
	if session == nil do return
	for stream in session.upgrades {if stream!=nil {h2_upgrade_release(stream)}}
	for request in session.requests {if request!=nil {h2_request_release(request,false,.Shutdown)}}
 task.http2 = nil
	if session.engine_ready {
		if view, borrowed := h2.connection_output_front(&session.engine); borrowed {
			_ = h2.connection_output_release(&session.engine, view.token)
		}
		for _ in 0 ..< H2_EVENTS {
			event, ok := h2.connection_poll(&session.engine)
			if !ok do break
			_ = h2.connection_event_release(&session.engine, event.token)
		}
		_ = h2.connection_destroy(&session.engine)
	}
	delete(session.requests,session.allocator);delete(session.reap,session.allocator);delete(session.upgrades,session.allocator)
 free(session, session.allocator)
}

@(private)
h2_shutdown :: proc(task: ^Connection_Task) {
	session := task.http2
	if session == nil || !session.engine_ready || session.shutdown || session.failed do return
	error := h2.connection_shutdown_begin(&session.engine)
	if error.kind == .None || error.kind == .Closed do session.shutdown = true
}

@(private)
h2_remember :: proc(session: ^HTTP2_Session, handle: h2.Stream_Handle) {
	if session == nil || handle.stream_id == 0 do return
	for index in 0 ..< session.reap_count {
		if session.reap[index] == handle do return
	}
	if session.reap_count >= len(session.reap) do return
	session.reap[session.reap_count] = handle
	session.reap_count += 1
}

// Release a finished stream's exchange lease and metadata before the next
// HEADERS frame. The grace barrier can outlive the lease; spare slots cover that.
@(private)
h2_settle :: proc(task: ^Connection_Task) {
	session := task.http2
	if session == nil || !session.engine_ready || session.failed do return
	for _ in 0 ..< H2_STREAM_SLOTS {
		h2_pump_events(task)
		h2_pump_engine(task)
		if session.failed do return
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
		if !released do return
	}
}

@(private)
h2_skip_response_header :: proc(name: string) -> bool {
	switch name {
	case "connection", "proxy-connection", "keep-alive", "upgrade", "transfer-encoding", "te", "content-length":
		return true
	}
	return len(name) > 0 && name[0] == ':'
}

@(private)
h2_clone :: proc(value: string, allocator: mem.Allocator) -> (string, bool) {
	if len(value) == 0 do return "", true
	copy, error := strings.clone(value, allocator)
	return copy, error == nil
}

@(private)
h2_pump_events :: proc(task: ^Connection_Task) -> bool {
	session := task.http2
	progress := false
	for _ in 0 ..< H2_EVENTS {
		event, ok := h2.connection_poll(&session.engine)
		if !ok do break
		progress = true
		taken := false
		switch value in event.payload {
		case h2.Ready_Event, h2.Peer_Settings_Event, h2.Ping_Ack_Event:
  case h2.Headers_Event:
   if value.kind==.Trailers {
    if request:=h2_request_find(task,value.stream);request!=nil && request.receiving {h2_request_trailers(request,value.summary.fields);h2_request_complete(&request.task)}
   } else if value.kind==.Request && value.summary.protocol!="" {
    if !h2_upgrade_open(task,value) {_=h2.connection_reset(&session.engine,value.stream,.Refused_Stream);h2_remember(session,value.stream)}
   } else if value.kind==.Request {
    if !h2_request_open(task,value) {_=h2.connection_reset(&session.engine,value.stream,.Refused_Stream);h2_remember(session,value.stream)}
   }
  case h2.Data_Event:
   if stream:=h2_upgrade_find(task,value.stream);stream!=nil {
    taken=h2_upgrade_data(stream,event,value)
    if !taken {_=h2.connection_reset(&session.engine,value.stream,.Cancel);h2_upgrade_release(stream)}
   } else if request:=h2_request_find(task,value.stream);request!=nil {taken=h2_request_data(request,event,value)}
  case h2.Stream_End_Event:
   if stream:=h2_upgrade_find(task,value.stream);stream!=nil {stream.remote_end=true}
   if request:=h2_request_find(task,value.stream);request!=nil && request.receiving {h2_request_complete(&request.task)}
  case h2.Reset_Event:
   if stream:=h2_upgrade_find(task,value.stream);stream!=nil {h2_upgrade_reset(stream)}
   if request:=h2_request_find(task,value.stream);request!=nil {h2_request_release(request,false,.Peer_Closed)}
   h2_remember(session,value.stream)
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

@(private)
h2_next_deadline :: proc(task: ^Connection_Task) -> time.Tick {
	session := task.http2
	deadline := session.idle_deadline
	for request in session.requests {if request!=nil {
  candidate:=request.body_deadline if request.receiving else request.response_deadline
  if candidate!=(time.Tick{}) && (deadline==(time.Tick{}) || time.tick_diff(candidate,deadline)>0) {deadline=candidate}
 }}
	if deadline == {} {return time.tick_add(time.tick_now(),task.runtime.timeouts.header)}
 return deadline
}
@(private)
h2_wait_budget :: proc(task:^Connection_Task)->time.Duration {
	remaining := time.tick_diff(time.tick_now(), h2_next_deadline(task))
	if remaining < 0 do return 0
	return remaining
}

@(private)
h2_check_deadlines :: proc(task: ^Connection_Task) -> bool {
	session := task.http2
 if h2_request_count(task)==0 && h2_upgrade_count(task)==0 && deadline_expired(session.idle_deadline) {h2_shutdown(task);return true}
	if server_is_draining(task.runtime) {
		h2_shutdown(task)
	}
	return false
}

@(private)
h2_read :: proc(task: ^Connection_Task) -> (bool, bool) {
	session := task.http2
	if session.failed || session.peer_gone do return false, false
	if session.ingress_len == len(session.ingress) do return false, false
	expires:=h2_next_deadline(task)
 if session.read_expires!=expires {
  session.read_expires=expires
  session.read_deadline=async.deadline_after(&task.runtime.executor,max(time.Duration(0),time.tick_diff(time.tick_now(),expires)))
 }
 // Preserve the exact async deadline while a TLS read is outstanding. Rebuilding
 // it from two clock samples would repeatedly cancel the same read under load.
	n, error := transport_read(task, session.ingress[session.ingress_len:], session.read_deadline)
	if n > 0 {
		session.ingress_len += n
		session.idle_deadline = time.tick_add(time.tick_now(), task.runtime.timeouts.idle)
	}
	if error.kind == .Pending do return n > 0, true
	if error.kind == .Timeout {
		if task.tls_state != nil && task.tls_state.error.kind == .Timeout do task.tls_state.error = {}
		return n > 0, false
	}
	if error.kind != .None || (error.kind == .None && n == 0) {
		session.peer_gone = true
	}
	return n > 0, false
}

@(private)
h2_feed :: proc(task: ^Connection_Task) -> bool {
	session := task.http2
	if !session.engine_ready do return false
	progress := false
	source := session.ingress[:session.ingress_len] if !session.failed else nil
	fed := h2.connection_feed(&session.engine, source, u32(session.limits.work_per_feed))
	if fed.consumed > 0 {
		remain := session.ingress_len - fed.consumed
		for index in 0 ..< remain {
			session.ingress[index] = session.ingress[fed.consumed + index]
		}
		session.ingress_len = remain
		progress = true
	}
	if fed.error.kind != .None && h2_connection_fatal(fed.error.kind) {
		session.failed = true
		session.ingress_len = 0
	}
	if fed.status==.Backpressure && fed.reason==.Metadata {
  stats,ok:=h2.connection_stats(&session.engine)
  if ok && stats.metadata_capacity<stats.max_stream_capacity {
   capacity:=min(stats.max_stream_capacity,max(2*stats.metadata_capacity,1))
   if h2.connection_reserve_streams(&session.engine,capacity).kind==.None {progress=true}
  }
 }
 if fed.work_used > 0 do progress = true
	return progress
}

@(private)
h2_output_pending :: proc(session: ^HTTP2_Session) -> bool {
	stats, ok := h2.connection_stats(&session.engine)
	return ok && (stats.output_count > 0 || stats.output_borrowed)
}

@(private)
h2_write :: proc(task: ^Connection_Task) -> (bool, bool) {
	session := task.http2
	state := task.tls_state
	if state == nil do return false, false
	task.deadline = async.deadline_after(&task.runtime.executor, h2_wait_budget(task))
	if state.write_started {
		n, error := transport_write(task, nil, task.deadline)
  if error.kind == .Pending do return false, true
		view, borrowed := h2.connection_output_front(&session.engine)
		if borrowed {
			if error.kind == .None && n > 0 {
				if h2.connection_output_advance(&session.engine, view.token, n).kind != .None {
					session.failed = true
				} else if task.observed do task.event.bytes_sent += u64(n)
			} else {
				_ = h2.connection_output_release(&session.engine, view.token)
				session.peer_gone = true
			}
		}
		return n > 0, false
	}
	if !h2_output_pending(session) do return false, false
	view, borrowed := h2.connection_output_front(&session.engine)
	if !borrowed do return false, false
	n, error := transport_write(task, view.bytes, task.deadline)
	if error.kind == .Pending do return false, true
	if error.kind != .None || n <= 0 {
		_ = h2.connection_output_release(&session.engine, view.token)
		session.peer_gone = true
		return false, false
	}
	if h2.connection_output_advance(&session.engine, view.token, n).kind != .None {
		session.failed = true
	} else if task.observed do task.event.bytes_sent += u64(n)
	return true, false
}

@(private)
h2_pump_engine :: proc(task: ^Connection_Task) {
	session := task.http2
	work := u32(session.limits.work_per_feed)
	for _ in 0 ..< 4 {
		_ = h2.connection_feed(&session.engine, nil, work)
		flushed := h2.connection_flush(&session.engine, work)
		life := h2.connection_lifecycle(&session.engine, 32)
		if h2_connection_fatal(flushed.error.kind) do session.failed = true
		if h2_connection_fatal(life.error.kind) do session.failed = true
		if session.failed do break
	}
}

@(private)
h2_connection_fatal :: proc(kind: h2.Error_Kind) -> bool {
	switch kind {
	case .None, .Limit_Exceeded, .Allocation_Failed, .Budget_Rejected, .Closed:
		return false
	case .Invalid_Config, .Invalid_State, .Invalid_Input, .Destination_Undersized, .Overlapping_Buffers, .Protocol_Violation:
		return true
	}
	return true
}

@(private)
h2_finished :: proc(task: ^Connection_Task) -> bool {
	session := task.http2
	if session == nil || !session.engine_ready do return true
	pending := h2_output_pending(session)
	writing := task.tls_state != nil && task.tls_state.write_started
	if pending || writing do return false
	if session.failed || session.peer_gone do return true
	if h2_upgrade_count(task)>0 || h2_request_count(task)>0 do return false
	if !session.shutdown do return false
	stats, ok := h2.connection_shutdown_status(&session.engine)
	if !ok do return false
	return stats.phase == .Draining || stats.phase == .Complete || stats.phase == .Aborted
}

@(private)
h2_step :: proc(task: ^Connection_Task) -> async.Resume_Result {
	session := task.http2
	if session == nil || !session.engine_ready do return .Done
	if async.cancelled(&task.task) {
		if !session.failed do _ = h2.connection_abort(&session.engine, {kind = .Closed})
		return .Done
	}
	waiting := false
	for _ in 0 ..< 8 {
		progress := false
		h2_settle(task)
		if h2_check_deadlines(task) do progress = true
		read_progress, read_wait := h2_read(task)
		if read_progress do progress = true
		if read_wait do waiting = true
		if h2_feed(task) do progress = true
		if h2_pump_events(task) do progress = true
		if h2_requests_pump(task) {progress=true}
		if h2_upgrade_pump(task) do progress = true
		h2_pump_engine(task)
		if h2_pump_events(task) do progress = true
		write_progress, write_wait := h2_write(task)
		if write_progress do progress = true
		if write_wait do waiting = true
		if h2_finished(task) do return .Done
		if progress do continue
		if h2_upgrade_count(task)>0 || h2_request_count(task)>0 {_=async.sleep_until_earlier(&task.runtime.executor,async.deadline_after(&task.runtime.executor,time.Millisecond))}
		if waiting do return .Waiting
		break
	}
	if h2_finished(task) do return .Done
 // The bounded turn may exhaust its work while the read is still armed. Ready
 // response queues need another owner turn even when the peer sends no bytes.
 if h2_request_count(task)>0 || h2_upgrade_count(task)>0 || h2_output_pending(session) {
  _=async.sleep_until_earlier(&task.runtime.executor,async.deadline_after(&task.runtime.executor,time.Millisecond))
 }
	if waiting do return .Waiting
	return .Yield
}
