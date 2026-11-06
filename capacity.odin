package server

import "core:log"
import "core:sync"
import "core:time"

import async "shared:async"

@(private)
CAPACITY_GROWTH_RETRY_INTERVAL :: time.Second
@(private)
CAPACITY_WARNING_INTERVAL :: 10 * time.Second

// Current is allocated admission capacity; maximum is the configured ceiling.
// Active includes setup, HTTP and reload WebSockets. Counters live until serve
// returns. Growth retains storage; request bodies remain allocated on demand.
Connection_Capacity :: struct {
	active, current, maximum, peak:                                  int,
	growths, growth_failures, rejected_capacity, admission_failures: u64,
}

// Copy pressure statistics without opening an HTTP connection. False means the
// server is not published; no runtime pointer escapes this call. Keep control
// at a stable address until serve returns.
server_capacity :: proc(control: ^Server_Control) -> (Connection_Capacity, bool) {
	if control == nil do return {}, false
	sync.lock(&control._mutex)
	defer sync.unlock(&control._mutex)
	runtime := control._server
	if runtime == nil do return {}, false
	sync.lock(&runtime.capacity_mutex)
	defer sync.unlock(&runtime.capacity_mutex)
	result := runtime.capacity_state
	result.active = sync.atomic_load(&runtime.active_connections)
	return result, true
}

@(private)
server_limits :: proc(config: Server) -> (int, int, int, bool) {
	maximum := config.max_connections
	if maximum == 0 do maximum = DEFAULT_MAX_CONNECTIONS
	initial := config.initial_connections
	if initial == 0 do initial = min(DEFAULT_INITIAL_CONNECTIONS, maximum)
	workers := config.workers
	if workers == 0 do workers = DEFAULT_WORKERS
	// Reserve a listener slot and one retiring task per worker. Socket tokens
	// have 32-bit indices. Bound arithmetic before deriving reserve sizes.
	invalid_setting := ""
	switch {
	case config.handler == nil:
		invalid_setting = "handler (required)"
	case maximum <= 0 || maximum > int(max(i32)) - 1:
		invalid_setting = "max_connections (must fit a positive socket capacity)"
	case initial <= 0 || initial > maximum:
		invalid_setting = "initial_connections (must be positive and <= max_connections)"
	case workers <= 0 || workers > max(int) / size_of(rawptr) - maximum - 1:
		invalid_setting = "workers (must be positive and fit runtime bookkeeping)"
	}
	if invalid_setting != "" {
		log.errorf(
			"Invalid server %s: initial_connections=%d, max_connections=%d, workers=%d",
			invalid_setting,
			initial,
			maximum,
			workers,
		)
		return 0, 0, 0, false
	}
	return initial, maximum, workers, true
}

// Only the accept task changes capacity. The mutex also protects snapshots.
// Evaluate projected occupancy so growth is complete before publishing the task
// that crosses 80%. A failed attempt is retried at most once per second.
@(private)
server_capacity_admit :: proc(runtime: ^Server_Runtime) -> bool {
	sync.lock(&runtime.capacity_mutex)
	event: Capacity_Event
	defer {
		sync.unlock(&runtime.capacity_mutex)
		server_capacity_log(event)
	}
	state := &runtime.capacity_state
	active := sync.atomic_load(&runtime.active_connections)
	threshold := state.current - state.current / 5
	if active + 1 >= threshold {
		event = server_capacity_grow_locked(runtime, active)
	}
	if active >= state.current {
		state.rejected_capacity += 1
		return false
	}
	state.peak = max(state.peak, active + 1)
	return true
}

@(private)
server_capacity_grow_locked :: proc(runtime: ^Server_Runtime, active: int) -> Capacity_Event {
	state := &runtime.capacity_state
	if state.current == state.maximum {
		return server_capacity_warn_locked(runtime, "configured ceiling", active)
	}
	now := time.tick_now()
	if runtime.capacity_retry_pending && time.tick_diff(now, runtime.capacity_retry_at) > 0 {
		return {}
	}
	target := state.current + min(state.current, state.maximum - state.current)
	workers := runtime.config.workers
	if workers == 0 do workers = DEFAULT_WORKERS
	err := async.reserve(&runtime.executor, {target + workers + 1, target + 1})
	if err.kind == .Stopping do return {}
	if err.kind != .None {
		state.growth_failures += 1
		runtime.capacity_retry_pending = true
		runtime.capacity_retry_at = time.tick_add(now, CAPACITY_GROWTH_RETRY_INTERVAL)
		return server_capacity_warn_locked(runtime, "storage expansion failed", active, err)
	}
	previous := state.current
	state.current = target
	state.growths += 1
	runtime.capacity_retry_pending = false
	return {previous = previous, state = state^, active = active}
}

@(private)
server_capacity_allocation_failed :: proc(runtime: ^Server_Runtime) {
	sync.lock(&runtime.capacity_mutex)
	runtime.capacity_state.admission_failures += 1
	event := server_capacity_warn_locked(
		runtime,
		"connection admission failed",
		sync.atomic_load(&runtime.active_connections),
	)
	sync.unlock(&runtime.capacity_mutex)
	server_capacity_log(event)
}

@(private)
server_capacity_warn_locked :: proc(
	runtime: ^Server_Runtime,
	reason: string,
	active: int,
	err: async.Error = {},
) -> Capacity_Event {
	now := time.tick_now()
	if runtime.capacity_warned && time.tick_diff(now, runtime.capacity_warning_at) > 0 {
		return {}
	}
	runtime.capacity_warned = true
	runtime.capacity_warning_at = time.tick_add(now, CAPACITY_WARNING_INTERVAL)
	return {state = runtime.capacity_state, active = active, reason = reason, error = err}
}

@(private)
Capacity_Event :: struct {
	state:            Connection_Capacity,
	active, previous: int,
	reason:           string,
	error:            async.Error,
}

@(private)
server_capacity_log :: proc(event: Capacity_Event) {
	state := event.state
	if event.previous > 0 {
		log.infof(
			"Connection capacity expanded: %d -> %d (active=%d, maximum=%d)",
			event.previous,
			state.current,
			event.active,
			state.maximum,
		)
	} else if event.reason != "" {
		log.warnf(
			"Connection capacity pressure: %s (active=%d, capacity=%d, maximum=%d, " +
			"rejected=%d, growth_failures=%d, admission_failures=%d, error=%v)",
			event.reason,
			event.active,
			state.current,
			state.maximum,
			state.rejected_capacity,
			state.growth_failures,
			state.admission_failures,
			event.error,
		)
	}
}
