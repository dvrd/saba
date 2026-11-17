package saba_core
import http3 "../../http/v3"
import credential_store "core:crypto/tls/credentials/store"
import "core:log"
import "core:net"
import "core:testing"
import "core:time"

@(test)
http3_phase_policy_resolves_existing_timeouts_and_requires_explicit_connect :: proc(t: ^testing.T) {
	defaults := http3_phase_policy(
		{enabled = true, connect_accept = time.Second, connect_close = 2 * time.Second},
		resolve_timeouts({}),
	)
	testing.expect(
		t,
		defaults.enabled &&
		defaults.header == 5 * time.Second &&
		defaults.body == 5 * time.Second &&
		defaults.large_body == 30 * time.Second &&
		defaults.response == 5 * time.Second,
	)
	testing.expect(
		t,
		defaults.large_body_threshold == 4096 &&
		defaults.connect_accept == time.Second &&
		defaults.connect_close == 2 * time.Second,
	)
	explicit := http3_phase_policy(
		{enabled = true, connect_accept = 4 * time.Second, connect_close = 6 * time.Second},
		resolve_timeouts(
			{header = time.Second, body = 2 * time.Second, response = 3 * time.Second, idle = time.Millisecond},
		),
	)
	testing.expect(
		t,
		explicit.header == time.Second &&
		explicit.body == 2 * time.Second &&
		explicit.large_body == 2 * time.Second &&
		explicit.response == 3 * time.Second,
	)
	testing.expect(t, !http3_phase_policy({}, resolve_timeouts({})).enabled)

	for config in ([]Http3_Phase_Config {
			{enabled = true},
			{enabled = true, connect_accept = -1, connect_close = time.Second},
			{enabled = true, connect_accept = time.Second, connect_close = MAX_SERVER_TIMEOUT + 1},
		}) {
		testing.expect(t, !http3_phases_valid(config))
	}

	testing.expect(
		t,
		http3_phases_valid({}) &&
		http3_phases_valid({enabled = true, connect_accept = MAX_SERVER_TIMEOUT, connect_close = time.Nanosecond}),
	)
}

@(test)
http3_phase_policy_is_forwarded_and_idle_handler_budgets_remain_distinct :: proc(t: ^testing.T) {
	identity := https80_make_store(t)
	defer credential_store.destroy(&identity)
	runtime: Server_Runtime
	runtime.config.handler = proc(_: rawptr, _: ^Connection, _: ^Request) -> Response {return {status = .OK}}
	runtime.timeouts = resolve_timeouts(
		{header = time.Second, body = 2 * time.Second, response = 3 * time.Second, idle = time.Millisecond},
	)
	owner := new(Http3)
	defer free(owner)
	owner.runtime = &runtime
	owner.config = {
		enabled = true,
		endpoint = {net.IP4_Loopback, 0},
		credentials = identity,
		request_timeout = 7 * time.Second,
		idle = {timeout = 11 * time.Second},
		handshake_timeout = 13 * time.Second,
		request_phases = {enabled = true, connect_accept = 17 * time.Second, connect_close = 19 * time.Second},
	}

	port, ok := http3_listen(owner)
	testing.expect(t, ok && port > 0)
	defer http3.listener_close(&owner.live)
	policy := owner.live.config.request_phases
	testing.expect(
		t,
		policy.enabled &&
		policy.header == time.Second &&
		policy.body == 2 * time.Second &&
		policy.large_body == 2 * time.Second &&
		policy.response == 3 * time.Second,
	)
	testing.expect(
		t,
		policy.connect_accept == 17 * time.Second &&
		policy.connect_close == 19 * time.Second &&
		policy.large_body_threshold == REQUEST_BODY_LIMIT,
	)
	testing.expect(
		t,
		owner.live.config.idle.timeout == 11 * time.Second &&
		owner.live.config.handshake_timeout == 13 * time.Second &&
		owner.live.config.request_timeout == 7 * time.Second,
	)
}

@(test)
http3_phase_invalid_connect_fails_before_listener_configuration :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()
	identity := https80_make_store(t)
	defer credential_store.destroy(&identity)
	runtime: Server_Runtime
	runtime.config.handler = proc(_: rawptr, _: ^Connection, _: ^Request) -> Response {return {status = .OK}}

	for config in ([]Http3_Phase_Config {
			{enabled = true},
			{enabled = true, connect_accept = time.Second, connect_close = -1},
		}) {
		owner := new(Http3)
		owner.runtime = &runtime
		owner.config = {
			enabled        = true,
			credentials    = identity,
			request_phases = config,
		}
		_, ok := http3_listen(owner)
		testing.expect(t, !ok && !owner.live.have_socket && owner.live.peers == nil)
		free(owner)
	}

	testing.expect(t, !serve({http3 = {request_phases = {enabled = true}}}))
}

@(test)
http3_phase_stream_budget_preserves_explicit_sse_lifetime_and_inherited_deadline :: proc(t: ^testing.T) {
	runtime: Server_Runtime
	owner: Http3
	probe: H3_Probe
	h3_unit_init(&runtime, &owner, &probe)
	defer h3_unit_destroy(&runtime)
	runtime.timeouts = resolve_timeouts({response = 10 * time.Second})
	owner.config.handler = proc(data: rawptr, _: ^Connection, _: ^Request) -> Response {
		return {
			status = .OK,
			stream = {
				data = data,
				next = h3_idle_next,
				drop = h3_probe_drop,
				content_length = -1,
				timeout = time.Minute,
			},
		}
	}

	for inherited, i in ([]time.Duration{0, 2 * time.Second}) {
		runtime.config.handler_timeout = inherited
		request := http3.Server_Request {
			method = "GET",
			target = "/sse",
		}

		response: http3.Server_Response
		before := time.tick_now()
		testing.expect_value(t, http3_poll(&owner, &request, &response), .Ready)
		after := time.tick_now()
		state := cast(^Http3_Request)request.user_data
		earliest := time.tick_diff(after, state.connection.streaming.expires)
		latest := time.tick_diff(before, state.connection.streaming.expires)
		testing.expect(
			t,
			response.response_timeout > 0 &&
			response.response_timeout >= earliest &&
			response.response_timeout <= latest,
		)

		if inherited == 0 {
			testing.expect(t, response.response_timeout > 59 * time.Second && response.response_timeout <= time.Minute)
		} else {
			testing.expect(t, response.response_timeout > time.Second && response.response_timeout <= 2 * time.Second)
		}

		response.stream.drop(response.stream.data)
		http3_release(&owner, &request)
		http3_release(&owner, &request)
		testing.expect_value(t, probe.drops, i + 1)
	}
}

@(test)
http3_phase_expired_producer_boundary_reports_failed_and_drops_once :: proc(t: ^testing.T) {
	runtime: Server_Runtime
	owner: Http3
	probe: H3_Probe
	h3_unit_init(&runtime, &owner, &probe)
	defer h3_unit_destroy(&runtime)
	request := http3.Server_Request {
		method = "GET",
		target = "/idle",
	}

	response: http3.Server_Response
	testing.expect_value(t, http3_poll(&owner, &request, &response), .Ready)
	state := cast(^Http3_Request)request.user_data
	// The producer's precise Tick deadline can expire just before the native
	// millisecond-ceiled phase. Native Failed must cancel only this stream.
	state.connection.streaming.expires = time.tick_add(time.tick_now(), -time.Nanosecond)
	destination: [1]u8
	n, status := response.stream.next(response.stream.data, destination[:])
	testing.expect(t, n == 0 && status == .Failed)
	response.stream.drop(response.stream.data)
	http3_release(&owner, &request)
	http3_release(&owner, &request)
	testing.expect_value(t, probe.drops, 1)
	testing.expect_value(t, runtime.active_connections, 0)
}

@(test)
http3_phase_shorter_deferred_timeout_reports_failure_and_releases_once :: proc(t: ^testing.T) {
	runtime: Server_Runtime
	owner: Http3
	probe: H3_Probe
	h3_unit_init(&runtime, &owner, &probe)
	defer h3_unit_destroy(&runtime)
	request := http3.Server_Request {
		method = "GET",
		target = "/pending",
	}

	response: http3.Server_Response
	testing.expect_value(t, http3_poll(&owner, &request, &response), .Pending)
	state := cast(^Http3_Request)request.user_data
	state.connection.deferred_expires = time.tick_add(time.tick_now(), -time.Nanosecond)
	testing.expect_value(t, http3_poll(&owner, &request, &response), .Failed)
	testing.expect(t, request_cancelled(state.connection.request.cancellation))
	http3_release(&owner, &request)
	http3_release(&owner, &request)
	testing.expect_value(t, probe.drops, 1)
	testing.expect_value(t, runtime.active_connections, 0)
}
