package saba_upstream

import server "../core"
import "core:net"
import "core:mem"
import "core:sync"
import budget "shared:async/budget"
import "core:time"
import async "shared:async"
import signal "shared:async/signal"
import surf "shared:surf"

// Build runs on the connection owner. Copy any borrowed headers/body needed by
// the outgoing response into allocator. The Surf response is destroyed on return.
Build :: #type proc(source: ^surf.Response, allocator: mem.Allocator) -> (server.Response, bool)

Dispatcher :: struct {
	client:     ^surf.Client,
	runtime:    ^async.Runtime,
	allocator:  mem.Allocator,
	interval:   time.Duration,
	task:       async.Task,
	mu:         sync.Mutex,
	slots:      []Slot,
	pending:    int,
	owners:     int,
	stopped:    bool,
	registered: bool,
}

@(private)
Slot :: struct {
	state: ^State,
	// A fast completion can beat publication of its handle by the submitter.
	early: surf.Request_Handle,
}

@(private)
State :: struct {
	dispatcher: ^Dispatcher,
	handle:     surf.Request_Handle,
	build:      Build,
	lease:      budget.Lease,
	wake:       signal.Signal,
	complete:   bool,
	abandoned:  bool,
}

// Refuses an address set unless every address is global unicast. This is
// Surf's policy: loopback, RFC 1918, 100.64.0.0/10, 169.254.0.0/16, 0.0.0.0/8,
// 224.0.0.0/4, 240.0.0.0/4, ::, ::1, fe80::/10, fc00::/7, ff00::/8,
// 64:ff9b::/96, and the ::ffff: form of each refused IPv4 address.
address_policy_public_only :: surf.address_policy_public_only

// Return false to refuse every address. user is Client_Config.http.address_policy_data.
Address_Policy :: surf.Address_Policy

// Initialize c from config and attach to it and the runtime that hosts it. The
// dispatcher exclusively consumes that surf. Give it one runtime task slot and
// a thread-safe allocator. Keep all three at stable addresses through detach.
// The dispatcher polls the client for completions. While requests are active,
// interval sets the polling cadence; a completion may wait up to one interval
// plus scheduler delay. The task parks without a timer when idle.
//
// Outbound URLs often carry request data, so the client refuses private,
// loopback, link-local and metadata addresses by default: a nil
// config.http.address_policy selects address_policy_public_only. Surf checks the
// policy after DNS and before every dial, including each redirect hop. An
// application whose upstream is internal supplies its own policy, for example
// one that accepts only that upstream's addresses, with any state it needs in
// config.http.address_policy_data. A refused dial answers 502 Bad Gateway.
//
// On success the application owns c as before: close it, detach, then destroy
// it. On failure c is left zeroed.
attach :: proc(
	d: ^Dispatcher,
	c: ^surf.Client,
	runtime: ^async.Runtime,
	config: surf.Client_Config,
	allocator: mem.Allocator,
	interval: time.Duration = time.Millisecond,
) -> bool {
	if d == nil ||
	   d.client != nil ||
	   c == nil ||
	   runtime == nil ||
	   interval <= 0 ||
	   allocator.procedure == nil ||
	   .Free not_in mem.query_features(allocator) {
		return false
	}
	config := config
	if config.http.address_policy == nil {
		config.http.address_policy = address_policy_public_only
		config.http.address_policy_data = nil
	}
	if surf.client_init(c, runtime, config, allocator).kind != .None {
		return false
	}
	attached := false
	defer if !attached {
		_ = surf.client_close(c)
		_ = surf.client_destroy(c)
	}
	capacities := config.capacities.? or_else surf.DEFAULT_CAPACITIES
	if capacities.requests < 1 {
		return false
	}
	slots, err := make([]Slot, capacities.requests, allocator)
	if err != nil {
		return false
	}
	d^ = {
		client    = c,
		runtime   = runtime,
		allocator = allocator,
		interval  = interval,
		slots     = slots,
	}
	d.task = {
		data      = d,
		resume    = dispatch,
		on_cancel = stop_dispatch,
	}
	if async.register(runtime, &d.task).kind != .None {
		delete(slots, allocator)
		d^ = {}
		return false
	}
	d.registered = true
	attached = true
	return true
}

// The Surf client bounds response bytes via its http.max_body_size and allocator
// scope. Each accepted Saba request also holds one job lease through upstream
// retirement. Surf copies the outbound request synchronously during submission.
response :: proc(
	d: ^Dispatcher,
	request: ^server.Request,
	outbound: surf.Request,
	build: Build,
	timeout: time.Duration = 0,
) -> server.Response {
	if d == nil ||
	   d.client == nil ||
	   request == nil ||
	   build == nil ||
	   timeout < 0 ||
	   timeout > server.MAX_SERVER_TIMEOUT {
		return {status = .Internal_Server_Error}
	}
	sync.lock(&d.mu)
	stopped := d.stopped
	sync.unlock(&d.mu)
	if stopped {
		return {status = .Service_Unavailable}
	}
	// A request whose deadline has passed was fully received; the upstream is
	// what did not answer in time. 408 would invite the browser to replay it.
	if server.request_cancelled(request.cancellation) {
		if server.request_context_status(request.cancellation) == .Deadline {
			return {status = .Gateway_Timeout}
		}
		return {status = .Service_Unavailable}
	}
	deadline: time.Tick
	remaining := timeout
	if cutoff := server.request_deadline(request.cancellation); cutoff != (time.Tick{}) {
		inherited := time.tick_diff(time.tick_now(), cutoff)
		if inherited <= 0 {
			return {status = .Gateway_Timeout}
		}
		if remaining == 0 || inherited < remaining {
			remaining = inherited
		}
	}
	if remaining > 0 {
		deadline = time.tick_add(time.tick_now(), remaining)
	}
	lease: budget.Lease
	if request.resources != (budget.Scope{}) {
		cause: budget.Error
		lease, cause = budget.reserve(
			request.resources,
			{jobs = 1, bytes = size_of(State)},
			.Running,
		)
		if cause != .None {
			return {status = .Service_Unavailable}
		}
	}
	state, err := new(State, d.allocator)
	if err != nil {
		budget.release(&lease)
		return {status = .Service_Unavailable}
	}
	state.dispatcher, state.build, state.lease = d, build, lease
	handle, cause := surf.client_submit(d.client, outbound, deadline)
	if cause.kind != .None {
		dispose(state)
		return {status = failure_status(cause)}
	}
	state.handle = handle
	sync.lock(&d.mu)
	slot := &d.slots[handle.slot]
	assert(slot.state == nil)
	d.owners += 1
	if slot.early == handle {
		slot.early = {}
		state.complete = true
	} else {
		slot.state = state
		d.pending += 1
		if d.pending == 1 && !d.stopped {
			_ = async.wake(d.runtime, &d.task)
		}
	}
	sync.unlock(&d.mu)
	return {deferred = {data = state, poll = poll, drop = drop, timeout = timeout}}
}

@(private)
failure_status :: proc(error: surf.Client_Error) -> server.HTTP_Status {
	transport := error.http.transport
	if error.http.kind == .Deadline_Failed ||
	   transport == net.TCP_Recv_Error.Timeout ||
	   transport == net.TCP_Send_Error.Timeout ||
	   transport == net.Dial_Error.Timeout {
		return .Gateway_Timeout
	}
	// The address policy refused every address of the upstream. The gateway
	// could not reach an upstream it may use; the client did nothing wrong.
	if error.http.kind == .Address_Rejected {
		return .Bad_Gateway
	}
	if error.kind == .Closed ||
	   error.kind == .Capacity ||
	   error.kind == .Allocation_Failed ||
	   error.http.kind == .Allocation_Failed {
		return .Service_Unavailable
	}
	return .Bad_Gateway
}

@(private)
dispose :: proc(state: ^State) {
	budget.release(&state.lease)
	free(state, state.dispatcher.allocator)
}

@(private)
publish :: proc(d: ^Dispatcher, handle: surf.Request_Handle) {
	sync.lock(&d.mu)
	slot := &d.slots[handle.slot]
	state := slot.state
	if state == nil {
		slot.early = handle
		sync.unlock(&d.mu)
		return
	}
	assert(state.handle == handle)
	slot^ = {}
	d.pending -= 1
	state.complete = true
	abandoned := state.abandoned
	wake, _ := signal.retain(state.wake)
	sync.unlock(&d.mu)

	if abandoned {
		_ = surf.client_release(d.client, handle)
		dispose(state)
	} else {
		_ = signal.wake(wake)
	}
	signal.release(&wake)
}

@(private)
dispatch :: proc(data: rawptr) -> async.Resume_Result {
	d := cast(^Dispatcher)data
	// One timer for the client's queue. Limit each resume so a burst of
	// completions shares the worker with network and protocol tasks.
	for _ in 0 ..< 32 {
		next, ok := surf.client_poll(d.client)
		if !ok {
			sync.lock(&d.mu)
			idle := d.pending == 0
			sync.unlock(&d.mu)
			if idle {
				return .Waiting
			}
			deadline := async.deadline_after(d.runtime, d.interval)
			#partial switch async.sleep_until(d.runtime, deadline).kind {
			case .Pending:
				return .Waiting
			case .None:
				return .Yield
			case:
				return stop_dispatch(data)
			}
		}
		publish(d, next.request)
	}
	return .Yield
}

@(private)
stop_dispatch :: proc(data: rawptr) -> async.Resume_Result {
	d := cast(^Dispatcher)data
	sync.lock(&d.mu)
	defer sync.unlock(&d.mu)
	d.stopped = true
	for &slot in d.slots {
		if slot.state != nil {
			_ = signal.wake(slot.state.wake)
		}
	}
	return .Done
}

@(private)
poll :: proc(data: rawptr, io: ^server.Deferred_IO) -> (server.Response, server.Deferred_Step) {
	state := cast(^State)data
	d := state.dispatcher
	sync.lock(&d.mu)
	if !state.complete {
		if d.stopped {
			sync.unlock(&d.mu)
			return {status = .Service_Unavailable}, .Ready
		}
		if state.wake == (signal.Signal{}) {
			ok: bool
			state.wake, ok = signal.retain(io.wake)
			if !ok {
				sync.unlock(&d.mu)
				return {}, .Failed
			}
		}
		sync.unlock(&d.mu)
		return {}, .Waiting
	}
	sync.unlock(&d.mu)
	source: surf.Response
	cause := surf.client_take(d.client, state.handle, &source)
	if cause.kind != .None {
		return {status = failure_status(cause)}, .Ready
	}
	state.handle = {}
	defer surf.response_destroy(&source)
	result, ok := state.build(&source, io.allocator)
	if !ok {
		server.discard_response(&result)
		return {}, .Failed
	}
	return result, .Ready
}

@(private)
drop :: proc(data: rawptr) {
	state := cast(^State)data
	d := state.dispatcher
	sync.lock(&d.mu)
	d.owners -= 1
	state.abandoned = true
	handle, complete, wake := state.handle, state.complete, state.wake
	state.wake = {}
	sync.unlock(&d.mu)
	signal.release(&wake)
	if !complete {
		// The dispatcher owns disposal from here. Cancellation can race
		// physical completion/reuse; the Surf handle includes a generation.
		_ = surf.client_cancel(d.client, handle)
		return
	}
	if handle != {} {
		_ = surf.client_release(d.client, handle)
	}
	dispose(state)
}

// Stop and join the Saba server before detach; serialize controller calls.
// A false result means a continuation, callback, or cancelled request still
// owns state. Allow Surf to retire it and retry. This also drains completions
// after runtime shutdown. Destroy the client and runtime after detach succeeds.
detach :: proc(d: ^Dispatcher) -> bool {
	if d == nil || d.client == nil {
		return false
	}
	sync.lock(&d.mu)
	busy := d.owners != 0
	was_stopped := d.stopped
	if !busy {
		d.stopped = true
	}
	sync.unlock(&d.mu)
	if busy {
		return false
	}
	if d.registered {
		cause := async.unregister(d.runtime, &d.task)
		if cause.kind == .Task_Busy {
			tasks := [1]^async.Task{&d.task}
			cause = async.retire_group_unstarted(d.runtime, tasks[:])
		}
		if cause.kind != .None {
			// The dispatcher task is still registered and can keep serving. A
			// failed detach must not leave every later request answered 503.
			sync.lock(&d.mu)
			d.stopped = was_stopped
			wake := d.pending > 0 && !was_stopped
			sync.unlock(&d.mu)
			if wake {
				_ = async.wake(d.runtime, &d.task)
			}
			return false
		}
		d.registered = false
	}
	for {
		next, ok := surf.client_poll(d.client)
		if !ok {
			break
		}
		publish(d, next.request)
	}
	if d.pending != 0 {
		return false
	}
	delete(d.slots, d.allocator)
	d^ = {}
	return true
}
