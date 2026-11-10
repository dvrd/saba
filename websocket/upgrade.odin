package saba_websocket

import core "../core"
import codec "../../websocket"
import rt "base:runtime"
import "core:strings"

@(private)
Upgrade_Fields :: struct {
	key, version, origin: string,
	origin_present, upgrade_seen, connection_seen: bool,
	offered: [MAX_SUBPROTOCOLS]string,
	offered_count: int,
}

@(private)
request_fields :: proc(request: ^core.Request) -> (Upgrade_Fields, Error) {
	fields: Upgrade_Fields
	if request == nil || request.method != "GET" || request.version != "HTTP/1.1" ||
	   len(request.headers) > core.REQUEST_HEADER_COUNT_LIMIT ||
	   request.content_length != 0 || request.chunked || len(request.body) != 0 {
		return {}, {kind = .Invalid_Request, status = .Bad_Request}
	}
	key_seen, version_seen, host_seen := false, false, false
	for header in request.headers {
		value := codec.upgrade_trim_ows(header.value)
		if strings.equal_fold(header.name, "Host") {
			if host_seen || !codec.upgrade_host_valid(value) do return {}, {kind = .Invalid_Request, status = .Bad_Request}
			host_seen = true
		} else if strings.equal_fold(header.name, "Sec-WebSocket-Key") {
			if key_seen do return {}, {kind = .Invalid_Request, status = .Bad_Request}
			fields.key, key_seen = value, true
		} else if strings.equal_fold(header.name, "Sec-WebSocket-Version") {
			if version_seen do return {}, {kind = .Invalid_Request, status = .Bad_Request}
			fields.version, version_seen = value, true
		} else if strings.equal_fold(header.name, "Origin") {
			if fields.origin_present || value == "" || !codec.upgrade_origin_valid(value) {
				return {}, {kind = .Invalid_Request, status = .Bad_Request}
			}
			fields.origin, fields.origin_present = value, true
		} else if strings.equal_fold(header.name, "Upgrade") || strings.equal_fold(header.name, "Connection") {
			upgrade := strings.equal_fold(header.name, "Upgrade")
			wanted := "websocket" if upgrade else "upgrade"
			found, valid := codec.upgrade_list_contains(value, wanted, upgrade)
			if !valid do return {}, {kind = .Invalid_Request, status = .Bad_Request}
			if upgrade {fields.upgrade_seen = fields.upgrade_seen || found}
			else {fields.connection_seen = fields.connection_seen || found}
		} else if strings.equal_fold(header.name, "Sec-WebSocket-Protocol") {
			remaining := value
			for token in strings.split_iterator(&remaining, ",") {
				if fields.offered_count == MAX_SUBPROTOCOLS do return {}, {kind = .Invalid_Request, status = .Bad_Request}
				fields.offered[fields.offered_count] = codec.upgrade_trim_ows(token)
				fields.offered_count += 1
			}
		}
	}
	if !host_seen || !fields.upgrade_seen || !fields.connection_seen ||
	   !codec.upgrade_request_fields_valid(fields.key, fields.version, "websocket", "upgrade") {
		return {}, {kind = .Invalid_Request, status = .Bad_Request}
	}
	if error := codec.upgrade_protocols_validate(fields.offered[:fields.offered_count]); error != .None {
		return {}, {kind = .Invalid_Request, status = .Bad_Request, upgrade = error}
	}
	return fields, {}
}

// Application ownership transfers only on success. Dispose an unused successful
// Response with core.discard_response; its drop remains exact even if 101 fails.
// Config hooks run only now; request headers and policy_data are not retained.
@(private)
prepare_upgrade :: proc(request: ^core.Request, config: Config, app: Application) -> (core.Response, Error) {
	resolved, validation := config_normalize(config)
	if validation.kind != .None {validation.status = .Internal_Server_Error; return {}, validation}
	fields, error := request_fields(request)
	if error.kind != .None do return {}, error
	allowed := !fields.origin_present
	if resolved.check_origin != nil {
		allowed = resolved.check_origin(resolved.policy_data, request, fields.origin, fields.origin_present)
	}
	if !allowed do return {}, {kind = .Origin_Rejected, status = .Forbidden}
	protocol := ""
	if resolved.select_subprotocol != nil {
		selected, accepted := resolved.select_subprotocol(resolved.policy_data, request,
			fields.offered[:fields.offered_count])
		if !accepted do return {}, {kind = .Protocol_Rejected, status = .Bad_Request}
		protocol = selected
		if selected != "" {
			found := false
			for offer in fields.offered[:fields.offered_count] {if selected == offer do found = true}
			if !found || codec.upgrade_protocols_validate([]string{selected}) != .None {
				return {}, {kind = .Protocol_Rejected, status = .Bad_Request}
			}
		}
	}
	session, allocation := new_session(core.request_connection_resources(request.cancellation),
		resolved, app, rt.heap_allocator())
	if allocation.kind != .None {allocation.status = .Internal_Server_Error; return {}, allocation}
	committed := false
	defer if !committed do drop_session(session)
	retained, retained_ok := core.retain_request_context(request.cancellation)
	if !retained_ok do return {}, {kind = .Invalid_Context, status = .Internal_Server_Error}
	session.request_context = retained
	if protocol != "" {
		copy, copy_error := strings.clone(protocol, session.allocator)
		if copy_error != nil do return {}, {kind = .Allocation_Failed, allocation = copy_error, status = .Internal_Server_Error}
		session.protocol = copy
	}
	accept, accept_error := make([]u8, 28, request.allocator)
	if accept_error != nil do return {}, {kind = .Allocation_Failed, allocation = accept_error, status = .Internal_Server_Error}
	accepted := codec.upgrade_accept_encoded(fields.key)
	copy(accept, accepted[:])
	count := 2
	if protocol != "" do count += 1
	headers, headers_error := make([]core.Header, count, request.allocator)
	if headers_error != nil do return {}, {kind = .Allocation_Failed, allocation = headers_error, status = .Internal_Server_Error}
	headers[0], headers[1] = {"Upgrade", "websocket"}, {"Sec-WebSocket-Accept", string(accept)}
	if protocol != "" do headers[2] = {"Sec-WebSocket-Protocol", session.protocol}
	session.owns_app, committed = true, true
	return {status = .Switching_Protocols, headers = headers,
		upgrade = {data = session, resume = resume_session, drop = drop_session}}, {}
}

// On rejection the returned ordinary HTTP response carries the typed error's
// status; no Application ownership transfers. The caller still drops its data.
upgrade :: proc(request: ^core.Request, config: Config, app: Application) -> (core.Response, Error) {
	response, error := prepare_upgrade(request, config, app)
	if error.kind != .None {
		if error.status == .None do error.status = .Internal_Server_Error
		return {status = error.status}, error
	}
	return response, {}
}
