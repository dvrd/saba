package server

import core "core"
import application "application"
import db "shared:kakunou"
import "core:mem"
import "core:testing"
import "core:log"
import "core:time"

@(test)
facade_handler_view_preserves_typed_database_and_io_without_allocation :: proc(t: ^testing.T) {
	database: db.SQLite_DB
	buffer := []u8{'a', 'b'}
	transport := core.Connection {
		read_buffer = buffer,
	}

	config := Server {
		database = &database,
		handler = proc(conn: ^Connection, request: ^Request) -> Response {
			assert(conn.database != nil)
			one: [1]u8
			n, error := read_connection(conn, one[:])
			assert(n == 1 && error == nil && one[0] == 'a')
			conn.write_deadline = time.tick_add(time.tick_now(), time.Second)
			return {status = .OK}
		},
	}

	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	request := Request {
		method    = "GET",
		path      = "/plain",
		allocator = mem.tracking_allocator(&tracker),
	}

	view := application.Dispatch_Context {
		connection = &transport,
		request    = &request,
	}

	response := legacy_dispatch(&config, &view)
	testing.expect_value(t, response.status, .OK)
	testing.expect_value(t, len(transport.read_buffer), 1)
	testing.expect_value(t, transport.read_buffer[0], u8('b'))
	testing.expect(t, transport.write_deadline != time.Tick{})
	testing.expect_value(t, tracker.total_memory_allocated, i64(0))
}

@(test)
facade_http3_configuration_reaches_owned_runtime :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()
	// Without forwarding enabled HTTP3, the remembered stop would instead make
	// the ordinary TCP server return success. Missing credentials must fail first.
	control: Server_Control
	stop_server(&control)
	config := Server {
		control = &control,
		http3 = Http3_Config{enabled = true},
		handler = proc(_: ^Connection, _: ^Request) -> Response {return {}},
	}

	testing.expect(t, !serve(config))
	endpoint, ready := server_http3_endpoint(&control)
	testing.expect(t, !ready && endpoint.port == 0)
}

@(test)
facade_http3_invalid_request_timeout_reaches_prebind_validation :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()

	for duration in ([]time.Duration{-1, 24 * time.Hour + 1}) {
		control: Server_Control
		stop_server(&control)
		config := Server {
			control = &control,
			http3 = {request_timeout = duration},
			handler = proc(_: ^Connection, _: ^Request) -> Response {return {status = .OK}},
		}

		testing.expect(t, !serve(config))
	}
}

@(test)
facade_invalid_backlog_reaches_core_validation :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()
	// Without forwarding, the remembered stop would make the server that bound
	// with the default backlog return success.
	control: Server_Control
	stop_server(&control)
	config := Server {
		control = &control,
		backlog = -1,
		handler = proc(_: ^Connection, _: ^Request) -> Response {return {status = .OK}},
	}

	testing.expect(t, !serve(config))
}

@(test)
facade_http3_phase_configuration_remains_explicit :: proc(t: ^testing.T) {
	config := Server {
		http3 = {
			request_phases = Http3_Phase_Config {
				enabled = true,
				connect_accept = time.Second,
				connect_close = 2 * time.Second,
			},
		},
	}

	testing.expect(
		t,
		config.http3.request_phases.enabled &&
		config.http3.request_phases.connect_accept == time.Second &&
		config.http3.request_phases.connect_close == 2 * time.Second,
	)
	testing.expect(t, !Server{}.http3.request_phases.enabled)
}
