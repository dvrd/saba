package saba_development

import "core:fmt"
import "core:hash"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"
import core "../core"
import rt "base:runtime"
import "core:unicode/utf8"
import async "shared:async"
import codec "../../websocket"

Development :: struct {
	// Empty preserves ODIN environment then the historical "odin" default.
	compiler:          string,
	// Explicit source roots need not live under the compiler's SDK root.
	watch_directories: []string,
	package_directory: string,
	shared_packages:   []string,
	build_arguments:   []string,
}

development_stopping: bool
DEVELOPMENT_CHILD :: "SABA_DEVELOPMENT_CHILD"

development_signal :: proc "c" (signal: posix.Signal) {
	sync.atomic_store(&development_stopping, true)
}

// Call before opening databases or listeners. The supervisor runs the current
// executable as a child; that child returns handled=false and starts normally.
// Only successful, current builds replace the running child.
develop :: proc(config: Development) -> (handled, success: bool) {
	if os.get_env(DEVELOPMENT_CHILD, context.temp_allocator) != "" {
		return false, true
	}
	handled = true

	if !os.is_dir(config.package_directory) {
		log.error("Development package directory is missing")
		return
	}

	compiler := development_compiler(config)
	paths, paths_ready := development_paths(config, compiler)

	if !paths_ready {
		return
	}

	executable, located := os.get_executable_path(context.temp_allocator)

	if located != nil {
		log.error("Could not locate development executable")
		return
	}

	directory, created := os.make_directory_temp("", "saba-development-*", context.temp_allocator)

	if created != nil {
		log.error("Could not create development build directory")
		return
	}

	defer _ = os.remove_all(directory)
	environment := make([dynamic]string, context.temp_allocator)
	inherited, env_error := os.environ(context.temp_allocator)

	if env_error != nil {
		log.error("Could not inherit development environment")
		return
	}

	append(&environment, ..inherited)
	append(&environment, DEVELOPMENT_CHILD + "=1")
	command := make([]string, len(os.args), context.temp_allocator)
	copy(command, os.args)
	command[0] = executable
	observed, scanned := development_signature(paths[:])

	if !scanned {
		return
	}

	child, started := development_start(command, environment[:])

	if started != nil {
		log.error("Could not start development server", started)
		return
	}

	active := true
	defer if active {
		development_stop(child)
	}
	sync.atomic_store(&development_stopping, false)
	old_int := posix.signal(.SIGINT, development_signal)
	old_term := posix.signal(.SIGTERM, development_signal)
	defer {
		_ = posix.signal(.SIGINT, old_int)
		_ = posix.signal(.SIGTERM, old_term)
	}

	log.info("Backend reload enabled: watching application and shared package sources")
	development_supervise(
		config,
		compiler,
		directory,
		executable,
		paths,
		command,
		environment[:],
		&child,
		&active,
		observed,
	)
	if command[0] != executable {
		delete(command[0])
	}

	return true, true
}

development_compiler :: proc(config: Development) -> string {
	if config.compiler != "" {
		return config.compiler
	}
	compiler := os.get_env("ODIN", context.temp_allocator)

	return "odin" if compiler == "" else compiler
}

development_paths :: proc(config: Development, compiler: string) -> ([]string, bool) {
	paths := make([dynamic]string, context.temp_allocator)
	append(&paths, config.package_directory)
	if len(config.watch_directories) > 128 {
		return nil, false
	}

	for directory in config.watch_directories {
		if directory == "" || !os.is_dir(directory) {
			log.error("Development watched directory is missing:", directory)
			return nil, false
		}

		append(&paths, directory)
	}

	if len(config.shared_packages) > 0 {
		state, output, errors, err := os.process_exec({command = {compiler, "root"}}, context.temp_allocator)

		if err != nil || !state.success {
			log.error("Could not locate Odin shared packages", string(errors))
			return nil, false
		}

		root := strings.trim_space(string(output))

		for name in config.shared_packages {
			if name == "" || strings.contains_any(name, "/\\") || name == "." || name == ".." {
				log.error("Invalid shared package name")
				return nil, false
			}

			path, _ := filepath.join({root, "shared", name}, context.temp_allocator)

			if !os.is_dir(path) {
				log.error("Development shared package is missing:", path)
				return nil, false
			}

			append(&paths, path)
		}
	}

	return paths[:], true
}

development_start :: proc(command, environment: []string) -> (os.Process, os.Error) {
	return os.process_start(
		{command = command, env = environment, stdin = os.stdin, stdout = os.stdout, stderr = os.stderr},
	)
}

// The caller owns the process handle and command storage until shutdown. This
// loop ends on SIGINT/SIGTERM; no build can replace a child after that signal.
development_supervise :: proc(
	config: Development,
	compiler, directory, executable: string,
	paths, command, environment: []string,
	child: ^os.Process,
	active: ^bool,
	observed_start: u64,
) {
	observed, published := observed_start, observed_start
	generation := 0
	for !sync.atomic_load(&development_stopping) {
		time.sleep(250 * time.Millisecond)

		if active^ {
			state, err := os.process_wait(child^, 0)

			if err == nil && state.exited {
				active^ = false
				log.error("Development server exited; edit a watched file to rebuild")
			}
		}

		current, valid := development_signature(paths[:])

		if !valid {
			continue
		}

		if current != observed {
			observed = current
			continue
		}

		if current == published {
			continue
		}
		published = current
		generation += 1
		// Scratch output never overwrites the executable that is still serving.
		next := fmt.aprintf("%s/server-%d", directory, generation)
		built, build_started := development_build(config, compiler, next)
		latest, checked := development_signature(paths[:])

		if !built || !checked || latest != current || sync.atomic_load(&development_stopping) {
			_ = os.remove(next)
			delete(next)

			if !sync.atomic_load(&development_stopping) {
				if !built {
					log.error("Build failed; the previous server is unchanged. " + "Save a correction to retry.")
				} else {
					log.info("Sources changed during the build; waiting for the latest edits")
				}
			}

			continue
		}

		log.infof(
			"Backend rebuilt in %.2f seconds; restarting",
			f64(time.tick_since(build_started)) / f64(time.Second),
		)
		if active^ {
			development_stop(child^)
		}
		active^ = false
		previous := command[0]
		command[0] = next
		next_child, start_error := development_start(command, environment)
		child^ = next_child

		if start_error != nil {
			log.error("Could not start rebuilt server", start_error)
		} else {
			active^ = true
			log.info("Backend restarted; connected browsers will refresh")
		}

		if previous != executable {
			_ = os.remove(previous)
			delete(previous)
		}
	}
}

development_build :: proc(config: Development, compiler, next: string) -> (bool, time.Tick) {
	args := make([dynamic]string)
	append(&args, compiler, "build", config.package_directory, "-warnings-as-errors")
	optimized := false

	for argument in config.build_arguments {
		if strings.has_prefix(argument, "-o:") {
			optimized = true
		}
	}

	if !optimized {
		append(&args, "-o:none")
	}
	append(&args, ..config.build_arguments)
	flag := fmt.aprintf("-out:%s", next)
	append(&args, flag)
	log.info("Server source changed; rebuilding while the current server stays available")
	build_started := time.tick_now()
	builder, err := os.process_start({command = args[:], stdout = os.stdout, stderr = os.stderr})
	built := false

	if err == nil {
		builder_running := true

		for !sync.atomic_load(&development_stopping) {
			state, waiting := os.process_wait(builder, 100 * time.Millisecond)

			if waiting == nil && state.exited {
				builder_running = false
				built = state.success && state.exit_code == 0
				break
			}

			if waiting != nil && waiting != os.General_Error.Timeout {
				development_stop(builder)
				builder_running = false
				break
			}
		}

		if builder_running {
			development_stop(builder)
		}
	}

	delete(args)
	delete(flag)

	return built, build_started
}

development_stop :: proc(process: os.Process) {
	_ = os.process_terminate(process)
	state, err := os.process_wait(process, 2 * time.Second)

	if err != nil || !state.exited {
		_ = os.process_kill(process)
		_, _ = os.process_wait(process)
	}
}

development_signature :: proc(paths: []string) -> (signature: u64, ok: bool) {
	ok = true

	for path in paths {
		walker := os.walker_create(path)

		for info in os.walker_walk(&walker) {
			if info.type == .Directory {
				name := filepath.base(info.fullpath)

				if name == ".git" || name == ".cruft" || name == "node_modules" {
					os.walker_skip_dir(&walker)
				}
			}

			if info.type != .Regular {
				continue
			}
			extension := filepath.ext(info.fullpath)
			if extension != ".odin" &&
			   extension != ".js" &&
			   extension != ".json" &&
			   extension != ".sql" &&
			   extension != ".html" &&
			   extension != ".css" &&
			   extension != ".c" &&
			   extension != ".h" {
				continue
			}

			if strings.contains(info.fullpath, "/.git/") {
				continue
			}
			bytes, err := os.read_entire_file(info.fullpath, context.allocator)

			if err != nil {
				ok = false
				break
			}

			signature ~= hash.fnv64a(bytes, hash.fnv64a(transmute([]byte)info.fullpath))
			delete(bytes)
		}

		_, err := os.walker_error(&walker)
		os.walker_destroy(&walker)
		if err != nil {
			ok = false
		}
		if !ok {
			return
		}
	}

	return
}

RELOAD_CLIENT :: #load("reload_client.js", string)
RELOAD_CLIENT_TAG :: `<script type="module" src="/__reload/client.js"></script>`

RELOAD_INTERVAL :: 250 * time.Millisecond

Reload_State :: struct {
	directory:         string,
	version:           u64,
	stopped:           bool,
	initial_signature: u64,
	logger:            log.Logger,
}

reload_client_response :: proc(request: ^Request) -> Response {
	return make_response(
		request,
		.OK,
		[]Header{{"Content-Type", "text/javascript; charset=utf-8"}, {"Cache-Control", "no-store"}},
		transmute([]u8)RELOAD_CLIENT,
	)
}

reload_html_response :: proc(response: Response) -> bool {
	if response.status != .None && response.status != .OK {
		return false
	}

	for header in response.headers {
		if !strings.equal_fold(header.name, "Content-Type") {
			continue
		}

		media_type := header.value

		if separator := strings.index_byte(media_type, ';'); separator >= 0 {
			media_type = media_type[:separator]
		}

		return strings.equal_fold(strings.trim_space(media_type), "text/html")
	}

	return false
}

inject_reload_client :: proc(html: []u8, allocator := context.allocator) -> (injected: []u8, ok: bool) {
	if strings.contains(string(html), RELOAD_CLIENT_TAG) {
		return nil, true
	}

	position := strings.index(string(html), "</head>")

	if position < 0 {
		log.error("Missing </head> in development HTML")

		return nil, false
	}

	development_html, allocation_err := make([]u8, len(html) + len(RELOAD_CLIENT_TAG), allocator)

	if allocation_err != nil {
		log.error("Could not allocate development HTML:", allocation_err)

		return nil, false
	}

	injected = development_html
	used := copy(injected, html[:position])
	used += copy(injected[used:], RELOAD_CLIENT_TAG)
	copy(injected[used:], html[position:])

	return injected, true
}

web_signature :: proc(directory: string) -> (signature: u64, ok: bool) {
	walker := os.walker_create(directory)
	defer os.walker_destroy(&walker)

	ok = true

	for info in os.walker_walk(&walker) {
		if info.type != .Regular {
			continue
		}

		data, err := os.read_entire_file(info.fullpath, context.allocator)

		if err != nil {
			log.error("Could not read watched file:", info.fullpath, err)
			ok = false
			return
		}

		file_hash := hash.fnv64a(transmute([]u8)info.fullpath)
		file_hash = hash.fnv64a(data, file_hash)

		signature ~= file_hash

		if free_err := delete(data); free_err != nil {
			log.error("Could not free watched file:", free_err)
			ok = false
		}
	}

	if path, err := os.walker_error(&walker); err != nil {
		log.error("Could not scan watched directory:", path, err)
		ok = false
	}

	return
}

watch_web :: proc(state: ^Reload_State) {
	context.logger = state.logger

	observed := state.initial_signature
	published := state.initial_signature

	for !sync.atomic_load(&state.stopped) {
		time.sleep(RELOAD_INTERVAL)

		current, ok := web_signature(state.directory)
		if !ok {
			continue
		}

		// Wait for two matching scans before publishing a change.
		if current != observed {
			observed = current
			continue
		}

		if current != published {
			version := sync.atomic_load(&state.version)
			sync.atomic_store(&state.version, version + 1)

			published = current
		}
	}
}

Session_Phase :: enum {
	Header,
	Frame,
	Write,
}
Reload_Session :: struct {
	state:                      ^Reload_State,
	phase:                      Session_Phase,
	initialized:                bool,
	version:                    u64,
	deadline:                   async.Deadline,
	input:                      [131]u8,
	used, expected:             int,
	output:                     [256]u8,
	output_used, output_offset: int,
	close_after:                bool,
}

// This adapter owns WebSocket framing/session storage; core drives only the
// optional continuation on its existing task and destroys it exactly once.
handle :: proc(state: ^Reload_State, request: ^Request) -> (Response, bool) {
	if core.match_route(request, "GET", "/__reload/client.js") {
		return reload_client_response(request), true
	}
	if !core.match_route(request, "GET", "/__reload") {
		return {}, false
	}
	accept_storage, allocation_error := make([]u8, 28, request.allocator)
	if allocation_error != nil {
		return {status = .Internal_Server_Error}, true
	}
	accept, status := websocket_accept(request, accept_storage)
	if status != .None {
		return {status = status}, true
	}
	response := make_response(
		request,
		.Switching_Protocols,
		{{"Upgrade", "websocket"}, {"Sec-WebSocket-Accept", accept}},
	)
	if response.status != .Switching_Protocols {
		return response, true
	}
	session, error := new(Reload_Session, rt.heap_allocator())
	if error != nil {
		return {status = .Internal_Server_Error}, true
	}
	session.state = state
	session.version = sync.atomic_load(&state.version)
	response.upgrade = {
		data   = session,
		resume = resume_session,
		drop   = drop_session,
	}

	return response, true
}

drop_session :: proc(data: rawptr) {
	free(cast(^Reload_Session)data, rt.heap_allocator())
}

reset_session_read :: proc(session: ^Reload_Session, io: ^core.Upgrade_IO) {
	session.used, session.expected = 0, 2
	session.phase = .Header
	session.deadline = async.deadline_after(io.runtime, RELOAD_INTERVAL)
	io.connection.read_deadline = time.tick_add(time.tick_now(), RELOAD_INTERVAL)
}

queue_session_output :: proc(session: ^Reload_Session, io: ^core.Upgrade_IO, count: int, close_after: bool) {
	session.output_used, session.output_offset = count, 0
	session.close_after = close_after
	session.phase = .Write
	session.deadline = async.deadline_after(io.runtime, RESPONSE_SEND_TIMEOUT)
	io.connection.write_deadline = time.tick_add(time.tick_now(), RESPONSE_SEND_TIMEOUT)
}

append_websocket_frame :: proc(storage: []u8, opcode: Opcode, payload: []u8) -> int {
	assert(len(payload) <= 125 && len(storage) >= len(payload) + 2)
	storage[0], storage[1] = 0x80 | u8(opcode), u8(len(payload))
	copy(storage[2:], payload)

	return len(payload) + 2
}

queue_session_close :: proc(session: ^Reload_Session, io: ^core.Upgrade_IO, code: u16, reason: string) {
	payload: [125]u8
	assert(len(reason) <= 123)
	payload[0], payload[1] = u8(code >> 8), u8(code & 255)
	copy(payload[2:], reason)
	count := append_websocket_frame(session.output[:], .Close, payload[:2 + len(reason)])
	queue_session_output(session, io, count, true)
}

resume_session :: proc(data: rawptr, io: ^core.Upgrade_IO) -> async.Resume_Result {
	session := cast(^Reload_Session)data

	if !session.initialized {
		session.initialized = true
		reset_session_read(session, io)
	}

	if session.phase == .Write {
		if session.output_offset == session.output_used {
			if session.close_after {
				return .Done
			}
			reset_session_read(session, io)
			return .Yield
		}

		n, error := core.upgrade_write(io, session.output[session.output_offset:session.output_used], session.deadline)
		if error.kind == .Pending {
			return .Waiting
		}
		if error.kind != .None {
			return .Done
		}
		session.output_offset += n
		return .Yield
	}

	used := session.used

	if session.phase == .Header && used == 0 {
		if sync.atomic_load(&session.state.stopped) {
			return .Done
		}

		if sync.atomic_load(&session.state.version) != session.version {
			count := append_websocket_frame(session.output[:], .Text, transmute([]u8)string("reload"))
			payload := []u8 {
				u8(REGULAR_CLOSE >> 8),
				u8(REGULAR_CLOSE & 255),
				'r',
				'e',
				'l',
				'o',
				'a',
				'd',
				'i',
				'n',
				'g',
			}

			count += append_websocket_frame(session.output[count:], .Close, payload)
			queue_session_output(session, io, count, true)
			return .Yield
		}
	}

	target := session.expected
	if session.phase == .Header && used == 0 {
		target = 1
	}
	n, error := core.upgrade_read(io, session.input[used:target], session.deadline)
	if error.kind == .Pending {
		return .Waiting
	}

	if error.kind == .Timeout && used == 0 && session.phase == .Header {
		reset_session_read(session, io)
		return .Yield
	}

	if error.kind != .None {
		return .Done
	}
	session.used += n
	used = session.used

	if used == 1 {
		session.deadline = async.deadline_after(io.runtime, REQUEST_HEADER_TIMEOUT)
		io.connection.read_deadline = time.tick_add(time.tick_now(), REQUEST_HEADER_TIMEOUT)
		return .Yield
	}

	if used < session.expected {
		return .Yield
	}
	header := session.input[:2]
	opcode := Opcode(header[0] & 15)
	length := int(header[1] & 127)

	if session.phase == .Header {
		code: u16 = PROTOCOL_ERROR
		reason: string

		if header[0] & 0x70 != 0 {
			reason = "reserved bits must be zero"
		} else if header[1] & 0x80 == 0 {
			reason = "client frames must be masked"
		} else if opcode == .Text || opcode == .Binary {
			code = UNSUPPORTED_DATA
			reason = "reload endpoint accepts control frames only"
		} else if opcode != .Close && opcode != .Ping && opcode != .Pong {
			reason = "unsupported opcode"
		} else if header[0] & 0x80 == 0 {
			reason = "control frames must not be fragmented"
		} else if length > 125 {
			reason = "control payload exceeds125bytes"
		} else if opcode == .Close && length == 1 {
			reason = "close payload must be empty or contain at least2bytes"
		}

		if reason != "" {
			queue_session_close(session, io, code, reason)
			return .Yield
		}

		session.expected = 6 + length
		session.phase = .Frame
		return .Yield
	}

	mask := session.input[2:6]
	payload := session.input[6:6 + length]
	for &value, i in payload {
		value ~= mask[i % 4]
	}
	#partial switch opcode {
	case .Close:
		if length >= 2 {
			code := u16(payload[0]) << 8 | u16(payload[1])

			if !valid_close_code(code) {
				queue_session_close(session, io, PROTOCOL_ERROR, "invalid close code")
				return .Yield
			}

			if !utf8.valid_string(string(payload[2:])) {
				queue_session_close(session, io, INVALID_PAYLOAD_DATA, "close reason must be valid UTF-8")
				return .Yield
			}
		}
		count := append_websocket_frame(session.output[:], .Close, payload)
		queue_session_output(session, io, count, true)
	case .Ping:
		count := append_websocket_frame(session.output[:], .Pong, payload)
		queue_session_output(session, io, count, false)
	case .Pong:
		reset_session_read(session, io)
	case:
		return .Done
	}

	return .Yield
}

Request :: core.Request
Response :: core.Response
Header :: core.Header
Connection :: core.Connection
HTTP_Status :: core.HTTP_Status
make_response :: core.make_response
header_value :: core.header_value
send_response :: core.send_response
send_empty_response :: core.send_empty_response
send_bytes :: core.send_bytes
read_connection :: core.read_connection
REQUEST_HEADER_TIMEOUT :: core.REQUEST_HEADER_TIMEOUT
RESPONSE_SEND_TIMEOUT :: core.RESPONSE_SEND_TIMEOUT

Opcode :: enum u8 {
	Continue = 0x00,
	Text     = 0x01,
	Binary   = 0x02,
	// 0x03–0x07 | Reserved for future data-frame types
	Close    = 0x08,
	Ping     = 0x09,
	Pong     = 0x0a,
	// 0x0b–0x0f | Reserved for future control-frame types
}

REGULAR_CLOSE :: 1000
PROTOCOL_ERROR :: 1002
UNSUPPORTED_DATA :: 1003
INVALID_PAYLOAD_DATA :: 1007

// Returns an accept value borrowing caller storage; no stack-backed value escapes.
websocket_accept :: proc(request: ^Request, storage: []u8) -> (string, HTTP_Status) {
	key := header_value(request, "Sec-WebSocket-Key")
	if !codec.upgrade_request_fields_valid(
		key,
		header_value(request, "Sec-WebSocket-Version"),
		header_value(request, "Upgrade"),
		header_value(request, "Connection"),
	) {
		return "", .Bad_Request
	}

	accepted := codec.upgrade_accept_encoded(key)

	if len(storage) < len(accepted) {
		return "", .Internal_Server_Error
	}

	copy(storage, accepted[:])

	return string(storage[:len(accepted)]), .None
}

upgrade_websocket :: proc(conn: ^Connection, request: ^Request) -> bool {
	storage: [28]u8
	accept, status := websocket_accept(request, storage[:])

	if status != .None {
		send_empty_response(conn, status)
		return false
	}

	return send_response(
		conn,
		{
			status = .Switching_Protocols,
			headers = []Header{{"Upgrade", "websocket"}, {"Sec-WebSocket-Accept", accept}},
		},
	)
}

send_websocket_frame :: proc(conn: ^Connection, opcode: Opcode, payload: []u8) -> bool {
	if len(payload) > 125 {
		log.error("WebSocket control payload exceeds 125 bytes")
		return false
	}

	frame: [127]u8
	frame[0] = 0x80 | cast(u8)opcode
	frame[1] = cast(u8)len(payload)
	copy(frame[2:], payload)

	conn.write_deadline = time.tick_add(time.tick_now(), RESPONSE_SEND_TIMEOUT)

	return send_bytes(conn, frame[:2 + len(payload)], "WebSocket frame")
}

send_websocket_close :: proc(conn: ^Connection, code: u16, reason: string) -> bool {
	if len(reason) > 123 {
		log.error("WebSocket close reason exceeds 123 bytes")
		return false
	}

	payload: [125]u8
	payload[0] = u8(code >> 8)
	payload[1] = u8(code & 0xff)
	copy(payload[2:], transmute([]u8)reason)

	return send_websocket_frame(conn, .Close, payload[:2 + len(reason)])
}

read_websocket_bytes :: proc(conn: ^Connection, buffer: []u8) -> bool {
	used := 0

	for used < len(buffer) {
		n, err := read_connection(conn, buffer[used:])

		if err != nil {
			log.error("Could not read WebSocket frame:", err, "| socket:", conn.socket)

			return false
		}

		if n == 0 {
			log.error("Client disconnected during WebSocket frame", "| socket:", conn.socket)

			return false
		}

		used += n
	}

	return true
}

valid_close_code :: proc(code: u16) -> bool {
	return (code >= 1000 && code <= 1003) || (code >= 1007 && code <= 1014) || (code >= 3000 && code <= 4999)
}
