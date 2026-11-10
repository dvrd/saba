package saba_core

import async "shared:async"
import tls "core:crypto/tls"
import "core:testing"
import "core:time"

@(test)
https80_secure_connection_and_detached_upgrade_never_use_raw_socket_helpers :: proc(t: ^testing.T) {
	conn := Connection{_secure = true}
	data: [4]u8
	n, read_error := read_connection(&conn, data[:])
	testing.expect_value(t, n, 0)
	testing.expect(t, read_error != nil)
	sent, write_error := write_connection(&conn, []u8{1, 2})
	testing.expect_value(t, sent, 0)
	testing.expect(t, write_error != nil)
	io := Upgrade_IO{connection = &conn}
	upgrade_n, upgrade_error := upgrade_read(&io, data[:], {})
	testing.expect_value(t, upgrade_n, 0)
	testing.expect_value(t, upgrade_error.kind, .Unsupported)
	upgrade_n, upgrade_error = upgrade_write(&io, []u8{3}, {})
	testing.expect_value(t, upgrade_n, 0)
	testing.expect_value(t, upgrade_error.kind, .Unsupported)
	conn.read_buffer = []u8{'p', 'r', 'e'}
	n, read_error = read_connection(&conn, data[:])
	testing.expect_value(t, n, 3)
	testing.expect_value(t, string(data[:n]), "pre")
	testing.expect_value(t, read_error, nil)
	n, read_error = read_connection(&conn, data[:])
	testing.expect_value(t, n, 0)
	testing.expect(t, read_error != nil)
}

@(test)
https80_phase_change_preserves_authenticated_staging_and_clears_only_internal_cancel :: proc(t: ^testing.T) {
	runtime: Server_Runtime
	assert(async.init(&runtime.executor, {workers = 1, task_capacity = 1, io_capacity = 1}).kind == .None)
	defer assert(async.destroy(&runtime.executor).kind == .None)
	for cancelled in ([]bool{false, true}) {
		state := TLS_State{read_started = true, read_done = true, read_phase = .Await_Response,
			read_deadline = {epoch = 1, at = 100}, read = {result = {count = 6}}}
		if cancelled {state.read.result.err.kind = .Cancelled}
		copy(state.input[:], "abcdef")
		task := Connection_Task{runtime = &runtime, tls_state = &state, phase = .Idle}
		// A new request has a different deadline and may consume the already
		// authenticated prefix in several reads after the old arena is gone.
		deadline := async.deadline_after(&runtime.executor, time.Second)
		first, second: [3]u8
		n, error := transport_read(&task, first[:], deadline)
		testing.expect_value(t, n, 3)
		testing.expect_value(t, error.kind, .None)
		testing.expect_value(t, string(first[:]), "abc")
		testing.expect(t, state.read_started && state.read_done)
		n, error = transport_read(&task, second[:], deadline)
		testing.expect_value(t, n, 3)
		testing.expect_value(t, error.kind, .None)
		testing.expect_value(t, string(second[:]), "def")
		testing.expect(t, !state.read_started && !state.read_done && !state.read_retarget)
		testing.expect_value(t, state.input_at, 0)
		testing.expect_value(t, state.error.kind, .None)
	}
}

@(test)
https80_retarget_never_hides_peer_close_or_protocol_failure :: proc(t: ^testing.T) {
	state := TLS_State{read_started = true, read_done = true, read_phase = .Await_Response,
		read = {result = {count = 0, err = {kind = .Peer_Closed}}}}
	task := Connection_Task{tls_state = &state, phase = .Idle}
	data: [1]u8
	n, error := transport_read(&task, data[:], {})
	testing.expect_value(t, n, 0)
	testing.expect_value(t, error.kind, .Peer_Closed)
	testing.expect_value(t, state.error.kind, .Peer_Closed)
	testing.expect(t, !state.read_started && !state.read_done)
}

@(test)
https80_old_empty_cancel_or_timeout_retires_before_fresh_read_submission :: proc(t: ^testing.T) {
	for timeout in ([]bool{false, true}) {
		state := TLS_State{read_started = true, read_done = true, read_phase = .Await_Response,
			read = {result = {err = {kind = .Cancelled}}}}
		if timeout {state.read.result.err.kind = .Timeout}
		task := Connection_Task{tls_state = &state, phase = .Headers}
		data: [1]u8
		// No Core owner is installed in this pure fixture. A fresh submission
		// therefore fails; returning Pending would retain the obsolete read.
		n, error := transport_read(&task, data[:], {})
		testing.expect_value(t, n, 0)
		testing.expect_value(t, error.kind, .Network_Error)
		testing.expect(t, !state.read_started && !state.read_done && !state.read_retarget)
	}
}

@(test)
https80_transport_deadlines_reject_foreign_epochs_before_consuming_completions :: proc(t: ^testing.T) {
	runtime, foreign_runtime: Server_Runtime
	assert(async.init(&runtime.executor, {workers = 1, task_capacity = 1, io_capacity = 1}).kind == .None)
	defer assert(async.destroy(&runtime.executor).kind == .None)
	assert(async.init(&foreign_runtime.executor, {workers = 1, task_capacity = 1, io_capacity = 1}).kind == .None)
	defer assert(async.destroy(&foreign_runtime.executor).kind == .None)
	own := async.deadline_after(&runtime.executor, time.Second)
	other := async.deadline_after(&foreign_runtime.executor, time.Second)
	assert(own.epoch != 0 && other.epoch != 0 && own.epoch != other.epoch)
	state: TLS_State
	task := Connection_Task{runtime = &runtime, tls_state = &state, phase = .Headers}
	for invalid in ([]async.Deadline{{at = 1}, {at = -1}, other}) {
		state = {read_started = true, read_done = true, read_phase = .Headers,
			read_deadline = own, read = {result = {count = 1}},
			write_started = true, write_done = true, write = {result = {count = 1}}}
		state.input[0] = 'x'
		testing.expect(t, !tls_deadline_valid(&task, invalid))
		data: [1]u8
		n, error := transport_read(&task, data[:], invalid)
		testing.expect_value(t, n, 0)
		testing.expect_value(t, error.kind, .Invalid_Config)
		n, error = transport_write(&task, []u8{'w'}, invalid)
		testing.expect_value(t, n, 0)
		testing.expect_value(t, error.kind, .Invalid_Config)
		testing.expect(t, state.read_started && state.read_done && !state.read_retarget)
		testing.expect(t, state.write_started && state.write_done)
		testing.expect_value(t, state.input_at, 0)
		testing.expect_value(t, state.error.kind, .None)
		testing.expect_value(t, data[0], u8(0))
	}
	for valid in ([]async.Deadline{{}, own}) {
		state = {read_started = true, read_done = true, read_phase = .Headers,
			read_deadline = valid, read = {result = {count = 1}},
			write_started = true, write_done = true, write = {result = {count = 1}}}
		state.input[0] = 'x'
		testing.expect(t, tls_deadline_valid(&task, valid))
		data: [1]u8
		n, error := transport_read(&task, data[:], valid)
		testing.expect_value(t, n, 1)
		testing.expect_value(t, error.kind, .None)
		testing.expect_value(t, data[0], u8('x'))
		n, error = transport_write(&task, []u8{'w'}, valid)
		testing.expect_value(t, n, 1)
		testing.expect_value(t, error.kind, .None)
		testing.expect(t, !state.read_started && !state.read_done)
		testing.expect(t, !state.write_started && !state.write_done)
	}
}

@(test)
https80_handshake_callback_preserves_first_failure_and_retains_new_protocol_error :: proc(t: ^testing.T) {
	state := TLS_State{error = {kind = .Cancelled}}
	op := tls.Server_Async_Handshake_Operation{user_data = &state, err = {kind = .Closed}}
	tls_handshake_done(&op)
	testing.expect(t, state.handshake_done)
	testing.expect_value(t, state.error.kind, .Cancelled)
	state = {}
	op = {user_data = &state, err = {kind = .Protocol_Failed},
		result = {kind = .Handshake, engine = .Finished_Failed}}
	tls_handshake_done(&op)
	testing.expect(t, state.handshake_done)
	testing.expect_value(t, state.error.kind, .Protocol_Failed)
}
