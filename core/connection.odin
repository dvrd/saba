package saba_core

import "core:log"
import "core:mem"
import "core:net"
import "core:crypto/tls"
import "core:sys/posix"
import "core:time"

Connection :: struct {
	_task: ^Connection_Task,
	_secure: bool,
	_peer_identity: tls.Peer_Identity,
	socket:         net.TCP_Socket,
	read_buffer:    []u8,
	read_deadline:  time.Tick,
	write_deadline: time.Tick,
	_timeouts:      Resolved_Timeouts,
}

deadline_expired :: proc(deadline: time.Tick) -> bool {
	return deadline != time.Tick{} && time.tick_diff(time.tick_now(), deadline) <= 0
}

wait_ready :: proc(
	client: net.TCP_Socket,
	events: posix.Poll_Event,
	deadline: time.Tick,
) -> (
	ready, timed_out: bool,
) {
	descriptor := posix.pollfd {
		fd     = posix.FD(client),
		events = events,
	}

	for {
		timeout_ms: i32 = -1
		if deadline != (time.Tick{}) {
			remaining := time.tick_diff(time.tick_now(), deadline)
			if remaining <= 0 do return false, true

			// Round up to milliseconds; -1 means no deadline, and zero means no wait.
			milliseconds := i64(remaining / time.Millisecond + 1)
			timeout_ms = cast(i32)min(milliseconds, cast(i64)max(i32))
		}

		descriptor.revents = {}
		result := posix.poll(&descriptor, 1, timeout_ms)
		if result < 0 {
			err := posix.errno()
			if err == .EINTR do continue
			log.error("Could not wait for socket readiness:", err, "| socket:", client)
			return false, false
		}
		if result == 0 do continue

		if .NVAL in descriptor.revents {
			log.error("Invalid socket while waiting for readiness | socket:", client)
			return false, false
		}

		// On hangup/error, let recv/send report EOF or the underlying socket error.
		if descriptor.revents & events != {} ||
		   .HUP in descriptor.revents ||
		   .ERR in descriptor.revents {
			return true, false
		}

		log.error("Unexpected socket readiness events:", descriptor.revents, "| socket:", client)
		return false, false
	}
}

read_connection :: proc(
	conn: ^Connection,
	buffer: []u8,
) -> (
	received: int,
	err: net.TCP_Recv_Error,
) {
	if conn._secure && len(conn.read_buffer) == 0 do return 0, .Unknown
	for {
		if deadline_expired(conn.read_deadline) do return 0, .Timeout

		if len(conn.read_buffer) > 0 {
			n := copy(buffer, conn.read_buffer)
			conn.read_buffer = conn.read_buffer[n:]

			return n, nil
		}

		n, read_err := net.recv_tcp(conn.socket, buffer)
		if read_err == .Interrupted do continue
		if read_err != .Would_Block do return n, read_err

		ready, timed_out := wait_ready(conn.socket, {.IN}, conn.read_deadline)
		if !ready {
			if timed_out do return 0, .Timeout
			return 0, .Unknown
		}
	}
}

write_connection :: proc(conn: ^Connection, data: []u8) -> (sent: int, err: net.TCP_Send_Error) {
	if conn._secure do return 0, .Unknown
	for {
		if deadline_expired(conn.write_deadline) do return sent, .Timeout
		if sent == len(data) do return sent, nil

		// Bound each call so sustained progress cannot bypass the deadline check.
		chunk := data[sent:min(sent + 64 * mem.Kilobyte, len(data))]
		n, send_err := net.send_tcp(conn.socket, chunk)
		sent += n

		if send_err == .Interrupted do continue
		if send_err == .Would_Block {
			ready, timed_out := wait_ready(conn.socket, {.OUT}, conn.write_deadline)
			if !ready {
				if timed_out do return sent, .Timeout
				return sent, .Unknown
			}
			continue
		}
		if send_err != nil do return sent, send_err
		if n != len(chunk) do return sent, .Connection_Closed
	}
}
