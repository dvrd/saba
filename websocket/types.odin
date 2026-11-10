// Application WebSocket sessions on Saba's existing HTTP/TLS connection task.
package saba_websocket

import core "../core"
import codec "../../websocket"
import async "../../async"
import "core:mem"
import charged "core:mem/budget"
import budget "core:sync/budget"
import "core:time"

Config :: struct {
	max_frame_bytes, max_message_bytes, max_output_bytes, output_capacity: int,
	max_fragments: int,
	idle_timeout, frame_timeout, message_timeout, write_timeout, close_timeout: time.Duration,
	check_origin: proc(data: rawptr, request: ^core.Request, origin: string, present: bool) -> bool,
	select_subprotocol: proc(data: rawptr, request: ^core.Request, offered: []string) -> (string, bool),
	policy_data: rawptr,
}
// All callbacks run serially on the existing task and must not block. IO and
// message bytes borrow only through callback return. data survives until drop.
Application :: struct {
	data: rawptr,
	on_open: proc(data: rawptr, io: ^IO),
	on_message: proc(data: rawptr, io: ^IO, opcode: codec.Opcode, payload: []u8),
	on_writable: proc(data: rawptr, io: ^IO),
	on_close: proc(data: rawptr, event: ^Close_Event),
	drop: proc(data: rawptr),
}
Error_Kind :: enum {
	None, Invalid_Config, Invalid_Context, Invalid_Request, Origin_Rejected,
	Protocol_Rejected, Allocation_Failed, Budget_Rejected, Invalid_Close,
}
Error :: struct {
	kind: Error_Kind,
	status: core.HTTP_Status,
	allocation: mem.Allocator_Error,
	budget: budget.Error,
	upgrade: codec.Upgrade_Error,
}
Send_Result :: enum {Accepted, Backpressure, Closed, Invalid, Limit_Exceeded, Allocation_Failed}
Close_Reason :: enum {
	Not_Opened, Owner_Stopped, Shutdown, Peer_Close, Peer_EOF, Application_Close,
	Protocol_Error, Timeout, IO_Error,
}
Stats :: struct {
	frames_in, frames_out, messages_in, messages_out: u64,
	queued_bytes, peak_output_bytes, queued_messages, peak_output_messages: int,
	message_capacity, peak_message_bytes: int,
}
Close_Event :: struct {
	clean: bool,
	reason: Close_Reason,
	code, peer_code: u16,
	transport: async.Error,
	frame: codec.Frame_Error,
	message: codec.Message_Error,
	stats: Stats,
}
// A call-scoped capability. Do not retain, copy for later use, or call concurrently.
IO :: struct {
	_session: ^Session,
	_transport: ^core.Upgrade_IO,
	_active: bool,
}

@(private)
Output :: struct {opcode: codec.Opcode, payload: []u8, offset: int, deadline: async.Deadline}
@(private)
Session :: struct {
	config: Config,
	app: Application,
	allocator: mem.Allocator,
	binding: charged.Binding,
	request_context: core.Request_Context,
	owns_app, opened, dropped, writable_wanted: bool,
	protocol: string,
	metrics: Stats,
	event: Close_Event,
	outputs: []Output,
	output_head, output_count: int,
	frame_wire: []u8,
	frame_used, frame_sent: int,
	frame_final: bool,
	control: [127]u8,
	control_used, control_sent: int,
	control_close: bool,
	close_requested, close_sent, peer_closed, abort_after_close: bool,
	close_payload: [125]u8,
	close_size: int,
	close_deadline, control_deadline: async.Deadline,
	input_header: [14]u8,
	header_used, header_expected: int,
	reading_payload: bool,
	header: codec.Frame_Header,
	payload: []u8,
	payload_used: int,
	control_input: [125]u8,
	message: codec.Message_State,
	fragments: int,
	read_deadline, message_deadline: async.Deadline,
}
