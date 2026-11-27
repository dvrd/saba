package saba_core

import "core:fmt"
import "core:net"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import "shared:async/quic"
import "shared:async/tls"
import tlscredentials "shared:async/tls/credentials"
import credential_store "shared:async/tls/credentials/store"
import http3 "shared:async/http/v3"

H3_Limits_Server :: struct {
	config:  Server,
	control: Server_Control,
	ok:      bool,
}

// Answers with the number of request fields and the length of the cookie.
h3_limits_handler :: proc(_: rawptr, _: ^Connection, request: ^Request) -> Response {
	fields, cookie := 0, 0

	for header in request.headers {
		if strings.has_prefix(header.name, "x-field-") {
			fields += 1
		} else if strings.equal_fold(header.name, "cookie") {
			cookie += len(header.value)
		}
	}

	body := fmt.aprintf("%d %d", fields, cookie, allocator = request.allocator)
	return {status = .OK, body = transmute([]u8)body}
}

h3_limits_store :: proc() -> ^credential_store.Store {
	credential, ce := tlscredentials.create(
		#load("../../tests/fixtures/tls/localhost.pem"),
		#load("../../tests/fixtures/tls/rsa2048.pem"),
		{},
		context.allocator,
	)
	assert(ce == .None)
	store, se := credential_store.create({}, context.allocator)
	assert(se.kind == .None)
	assert(credential_store.replace(store, &credential).kind == .None)
	return store
}

h3_limits_start :: proc(fixture: ^H3_Limits_Server) -> (^thread.Thread, int) {
	worker := thread.create_and_start_with_poly_data(fixture, proc(f: ^H3_Limits_Server) {f.ok = serve(f.config)})
	// A startup bound only: generous, since a loaded machine can take seconds
	// to start serve, and nothing here measures it.
	until := time.tick_add(time.tick_now(), 60 * time.Second)

	for !server_ready(&fixture.control) && time.tick_diff(time.tick_now(), until) > 0 {
		thread.yield()
	}

	endpoint, ready := server_http3_endpoint(&fixture.control)
	return worker, endpoint.port if ready else 0
}

h3_limits_roots :: proc() -> tls.Root_Pool {
	roots: tls.Root_Pool
	assert(tls.root_pool_parse(&roots, #load("../../tests/fixtures/tls/localhost.pem")) == nil)
	return roots
}

h3_limits_exchange :: proc(
	pool: ^http3.Pool,
	port: int,
	roots: ^tls.Root_Pool,
	timeout: time.Duration,
	headers: []http3.Field = nil,
) -> http3.Client_Result {
	return http3.pool_exchange_request(
		pool,
		{net.IP4_Loopback, port},
		"127.0.0.1",
		{method = "GET", target = "/limits", authority = "127.0.0.1", headers = headers},
		roots.roots[:roots.count],
		time.time_add(time.now(), timeout),
	)
}

@(test)
http3_serves_requests_within_the_http1_field_limits :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 20 * time.Second)
	store := h3_limits_store()
	defer credential_store.destroy(&store)
	fixture: H3_Limits_Server
	fixture.config = {
		handler = h3_limits_handler,
		control = &fixture.control,
		workers = 1,
		http3 = {enabled = true, endpoint = {net.IP4_Loopback, 0}, credentials = store},
	}
	worker, port := h3_limits_start(&fixture)
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

	// Forty ordinary fields, as a browser sends with client hints and a few
	// application headers.
	names: [40]string
	values: [40]string
	many: [40]http3.Field

	for i in 0 ..< len(many) {
		names[i] = fmt.tprintf("x-field-%02d", i)
		values[i] = fmt.tprintf("value-%02d-%s", i, strings.repeat("v", 40, context.temp_allocator))
		many[i] = {name = names[i], value = values[i]}
	}

	pool := new(http3.Pool)
	defer {
		http3.pool_close(pool)
		free(pool)
	}
	result := h3_limits_exchange(pool, port, &roots, 5 * time.Second, many[:])
	testing.expect(t, result.error == .None, h3_test_error(&result))
	testing.expect_value(t, result.status, 200)
	testing.expect_value(t, h3_test_body(&result), "40 0")

	// A 6 KB cookie, within the HTTP/1 header block limit.
	cookie := strings.repeat("c", 6 * 1024, context.temp_allocator)
	jar := [?]http3.Field{{name = "cookie", value = cookie}}
	result = h3_limits_exchange(pool, port, &roots, 5 * time.Second, jar[:])
	testing.expect(t, result.error == .None, h3_test_error(&result))
	testing.expect_value(t, result.status, 200)
	testing.expect_value(t, h3_test_body(&result), "0 6144")
}

@(test)
http3_refuses_connections_beyond_the_per_address_limit :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	store := h3_limits_store()
	defer credential_store.destroy(&store)
	fixture: H3_Limits_Server
	fixture.config = {
		handler = h3_limits_handler,
		control = &fixture.control,
		workers = 1,
		http3 = {enabled = true, endpoint = {net.IP4_Loopback, 0}, credentials = store},
	}
	worker, port := h3_limits_start(&fixture)
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

	// Each pool holds its own connection, all from 127.0.0.1.
	pools: [HTTP3_CONNECTIONS_PER_ADDRESS]^http3.Pool

	for &pool in pools {
		pool = new(http3.Pool)
	}

	defer for pool in pools {
		http3.pool_close(pool)
		free(pool)
	}

	for i in 0 ..< len(pools) {
		result := h3_limits_exchange(pools[i], port, &roots, 5 * time.Second)
		testing.expectf(t, result.error == .None && result.status == 200, "connection %d: %s", i, h3_test_error(&result))
	}

	// A failed exchange leaves the client's thread unfit for further ones, so
	// connections expected to fail are opened from a thread of their own.
	over := h3_limits_isolated_exchange(port, 2 * time.Second)
	testing.expectf(t, over != 200, "connection over the limit was served: %d", over)

	// The connections already held keep being served.
	for i in 0 ..< len(pools) {
		again := h3_limits_exchange(pools[i], port, &roots, 5 * time.Second)
		testing.expectf(t, again.error == .None && again.status == 200, "held connection %d: %s", i, h3_test_error(&again))
	}
}

// One exchange on a new connection, from a thread of its own. Returns the
// response status, or zero when the exchange failed.
h3_limits_isolated_exchange :: proc(port: int, timeout: time.Duration) -> int {
	Isolated :: struct {
		port:    int,
		timeout: time.Duration,
		status:  int,
	}
	isolated := Isolated {
		port    = port,
		timeout = timeout,
	}
	worker := thread.create_and_start_with_poly_data(&isolated, proc(i: ^Isolated) {
		roots := h3_limits_roots()
		defer tls.root_pool_destroy(&roots)
		pool := new(http3.Pool)
		defer {
			http3.pool_close(pool)
			free(pool)
		}
		result := h3_limits_exchange(pool, i.port, &roots, i.timeout)

		if result.error == .None {
			i.status = result.status
		}
	})
	thread.join(worker)
	thread.destroy(worker)
	return isolated.status
}

@(test)
http3_limits_resolve_to_production_defaults :: proc(t: ^testing.T) {
	config: Http3_Config
	limits := http3_limits(config)
	testing.expect_value(t, limits.max_request_fields, REQUEST_HEADER_COUNT_LIMIT)
	testing.expect(t, limits.max_request_field_bytes >= REQUEST_HEADER_LIMIT)
	testing.expect_value(t, limits.max_request_field_bytes, http3.REQUEST_FIELD_BYTES)
	testing.expect_value(t, limits.max_connections_per_address, HTTP3_CONNECTIONS_PER_ADDRESS)
	testing.expect_value(t, limits.retry_above, 0)
	// A per-address limit of the whole table or more is lifted; one below it binds.
	testing.expect_value(t, http3_limits({max_connections = 16, max_connections_per_address = 16}).max_connections_per_address, 0)
	testing.expect_value(t, http3_limits({max_connections = 16, max_connections_per_address = 15}).max_connections_per_address, 15)

	tokens: quic.Retry_Tokens
	config.retry = &tokens
	limits = http3_limits(config)
	testing.expect_value(t, limits.retry_above, http3.LISTENER_CONNECTIONS / 2)
	config.max_connections = 100
	testing.expect_value(t, http3_limits(config).retry_above, 50)
	config.retry_every_connection = true
	testing.expect_value(t, http3_limits(config).retry_above, 0)

	testing.expect(t, http3_limits_valid({}))
	testing.expect(t, !http3_limits_valid({max_request_fields = http3.MAX_REQUEST_FIELDS + 1}))
	testing.expect(t, !http3_limits_valid({max_request_field_bytes = -1}))
	testing.expect(t, !http3_limits_valid({max_request_field_bytes = http3.MAX_REQUEST_FIELD_BYTES + 1}))
	testing.expect(t, !http3_limits_valid({max_connections_per_address = -1}))
	testing.expect(t, !http3_limits_valid({retry_above = -1}))
	testing.expect(t, !http3_limits_valid({max_connections = http3.MAX_LISTENER_CONNECTIONS + 1}))
	testing.expect(t, !http3_limits_valid({max_connections = 8, retry_above = 9}))
	testing.expect(t, !http3_limits_valid({retry_above = 4, retry_every_connection = true}))
}
