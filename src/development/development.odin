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
import codec "shared:async/websocket"

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

// Set when the terminal interrupted the whole process group: the child received
// the same SIGINT and is already draining.
development_interrupted: bool

development_signal :: proc "c" (signal: posix.Signal) {
	if signal == .SIGINT {
		sync.atomic_store(&development_interrupted, true)
	}
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
	cache: Signature_Cache
	defer signature_cache_destroy(&cache)
	observed, scanned := development_signature(paths[:], &cache)

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
	sync.atomic_store(&development_interrupted, false)
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
		&cache,
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
	cache: ^Signature_Cache,
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

		current, valid := development_signature(paths[:], cache)

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
		before := published
		published = current
		generation += 1
		// Scratch output never overwrites the executable that is still serving.
		next := fmt.aprintf("%s/server-%d", directory, generation)
		built, build_started := development_build(config, compiler, next)
		latest, checked := development_signature(paths[:], cache)

		if !built || !checked || latest != current || sync.atomic_load(&development_stopping) {
			_ = os.remove(next)
			delete(next)
			// The sources could not be read back, so nothing says this build is
			// stale or current. Build them again rather than wait for an edit.
			if built && !checked {
				published = before
			}

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
	// A second signal makes a draining server stop at once. After Ctrl-C the
	// child has its own SIGINT, so it gets the same two seconds before that.
	if sync.atomic_load(&development_interrupted) {
		if state, err := os.process_wait(process, 2 * time.Second); err == nil && state.exited {
			return
		}
	}
	_ = os.process_terminate(process)
	state, err := os.process_wait(process, 2 * time.Second)

	if err != nil || !state.exited {
		_ = os.process_kill(process)
		_, _ = os.process_wait(process)
	}
}

// Files are compared by (path, size, modification time) first; the content is
// read and hashed only when those change. A touch re-hashes but, with identical
// bytes, leaves the signature (and therefore the rebuild decision) unchanged.
File_Stamp :: struct {
	size:  i64,
	mtime: time.Time,
	hash:  u64,
	seen:  u64,
}

Signature_Cache :: struct {
	files:  map[string]File_Stamp,
	scan:   u64,
	// Files whose content was read and hashed, for tests and diagnostics.
	hashed: int,
}

signature_cache_destroy :: proc(cache: ^Signature_Cache) {
	for path in cache.files {
		delete(path)
	}

	delete(cache.files)
	cache^ = {}
}

signature_cache_begin :: proc(cache: ^Signature_Cache) {
	if cache != nil {
		cache.scan += 1
	}
}

// Forgets files that were not seen by the finished scan; a failed scan may
// have stopped early, so it keeps everything.
signature_cache_finish :: proc(cache: ^Signature_Cache, complete: bool) {
	if cache == nil || !complete {
		return
	}

	stale := make([dynamic]string)
	defer delete(stale)

	for path, stamp in cache.files {
		if stamp.seen != cache.scan {
			append(&stale, path)
		}
	}

	for path in stale {
		delete_key(&cache.files, path)
		delete(path)
	}
}

// Path and content folded into one value, so a rename changes the signature.
file_signature :: proc(
	info: os.File_Info,
	cache: ^Signature_Cache,
	content := true,
) -> (
	signature: u64,
	ok: bool,
) {
	if cache != nil {
		stamp, found := cache.files[info.fullpath]

		if found && stamp.size == info.size && stamp.mtime == info.modification_time {
			stamp.seen = cache.scan
			cache.files[info.fullpath] = stamp

			return stamp.hash, true
		}
	}

	if !content || info.size > WATCH_CONTENT_BYTES {
		// Never read: a change of size or modification time is the whole signal.
		stamp := [2]i64{info.size, time.to_unix_nanoseconds(info.modification_time)}
		signature = hash.fnv64a(
			(cast([^]byte)&stamp)[:size_of(stamp)],
			hash.fnv64a(transmute([]byte)info.fullpath),
		)
		if cache != nil {
			entry := File_Stamp{info.size, info.modification_time, signature, cache.scan}
			if _, found := cache.files[info.fullpath]; found {
				cache.files[info.fullpath] = entry
			} else {
				cache.files[strings.clone(info.fullpath)] = entry
			}
		}
		return signature, true
	}

	bytes, err := os.read_entire_file(info.fullpath, context.allocator)

	if err != nil {
		return 0, false
	}

	defer delete(bytes)
	signature = hash.fnv64a(bytes, hash.fnv64a(transmute([]byte)info.fullpath))

	if cache != nil {
		cache.hashed += 1
		stamp := File_Stamp{info.size, info.modification_time, signature, cache.scan}

		if _, found := cache.files[info.fullpath]; found {
			cache.files[info.fullpath] = stamp
		} else {
			cache.files[strings.clone(info.fullpath)] = stamp
		}
	}

	return signature, true
}

development_signature :: proc(paths: []string, cache: ^Signature_Cache = nil) -> (signature: u64, ok: bool) {
	ok = true
	signature_cache_begin(cache)
	defer signature_cache_finish(cache, ok)

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
			file_signature, readable := file_signature(info, cache)

			if !readable {
				ok = false
				break
			}

			signature ~= file_signature
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

// The hot reload scan reads only source text, and only up to this size. Images,
// fonts, media, archives and anything larger are compared by size and
// modification time, so a large web root costs a directory walk per scan.
WATCH_CONTENT_BYTES :: 8 << 20

watched_content :: proc(name: string) -> bool {
	extension := filepath.ext(name)
	for known in ([]string {
			".js",
			".jsx",
			".mjs",
			".css",
			".html",
			".htm",
			".json",
			".svg",
			".txt",
			".md",
			".xml",
			".webmanifest",
			".odin",
			".sql",
		}) {
		if strings.equal_fold(extension, known) {
			return true
		}
	}
	return false
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
	before_reload:     proc(rawptr) -> bool,
	reload_data:       rawptr,
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

web_signature :: proc(directory: string, cache: ^Signature_Cache = nil, skip_build_archives := false) -> (signature: u64, ok: bool) {
	walker := os.walker_create(directory)
	defer os.walker_destroy(&walker)

	ok = true
	signature_cache_begin(cache)
	defer signature_cache_finish(cache, ok)

	for info in os.walker_walk(&walker) {
		if info.type == .Directory {
			// Never served, and often very large.
			if strings.has_prefix(info.name, ".") || info.name == "node_modules" {
				os.walker_skip_dir(&walker)
			}
			continue
		}
		if info.type != .Regular || strings.has_prefix(info.name, ".") {
			continue
		}
		if skip_build_archives && (strings.has_suffix(info.name, ".saba-build.json") || strings.has_suffix(info.name, ".saba-build.json.staging")) {
			continue
		}

		file_signature, readable := file_signature(info, cache, watched_content(info.name))

		if !readable {
			log.error("Could not read watched file:", info.fullpath)
			ok = false
			return
		}

		signature ~= file_signature
	}

	if path, err := os.walker_error(&walker); err != nil {
		log.error("Could not scan watched directory:", path, err)
		ok = false
	}

	return
}

Watch_Progress :: struct {
	observed, published: u64,
}

watch_web :: proc(state: ^Reload_State) {
	context.logger = state.logger

	progress := Watch_Progress{state.initial_signature, state.initial_signature}
	cache: Signature_Cache
	defer signature_cache_destroy(&cache)

	for !sync.atomic_load(&state.stopped) {
		time.sleep(RELOAD_INTERVAL)
		watch_web_step(state, &progress, &cache)
	}
}

// One scan and, when two scans agree on a change, one publication. Scratch
// storage used by the scan and by a rebuild is released before returning, so a
// long session does not accumulate it on the watcher thread.
watch_web_step :: proc(state: ^Reload_State, progress: ^Watch_Progress, cache: ^Signature_Cache) {
	defer free_all(context.temp_allocator)

	current, ok := web_signature(state.directory, cache, state.before_reload != nil)
	if !ok {
		return
	}

	// Wait for two matching scans before publishing a change.
	if current != progress.observed {
		progress.observed = current
		return
	}

	if current != progress.published {
		progress.published = current
		if state.before_reload != nil && !state.before_reload(state.reload_data) {
			return
		}
		version := sync.atomic_load(&state.version)
		sync.atomic_store(&state.version, version + 1)
	}
}

// A browser sends Origin with every WebSocket handshake. Only the page this
// server itself delivered may subscribe; clients that send none are not browsers.
reload_origin_allowed :: proc(origin, host: string) -> bool {
	if origin == "" {
		return true
	}
	authority := origin
	if len(origin) >= 8 && strings.equal_fold(origin[:8], "https://") {
		authority = origin[8:]
	} else if len(origin) >= 7 && strings.equal_fold(origin[:7], "http://") {
		authority = origin[7:]
	} else {
		return false
	}
	return host != "" && strings.equal_fold(authority, host)
}

Session_Phase :: enum {
	Header,
	Frame,
	Write,
}
Reload_Session :: struct {
	state:                      ^Reload_State,
	request_context:            core.Request_Context,
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
	// A browser that already holds an HTTP/2 or HTTP/3 connection opens the
	// socket as Extended CONNECT (RFC 8441, RFC 9220): no Upgrade handshake
	// fields, and a 200 instead of a 101.
	extended := request.method == "CONNECT" && request.protocol == "websocket" && request.path == "/__reload"
	if !extended && !core.match_route(request, "GET", "/__reload") {
		return {}, false
	}
	if !reload_origin_allowed(header_value(request, "Origin"), header_value(request, "Host")) {
		return {status = .Forbidden}, true
	}
	response: Response
	if extended {
		response = {status = .OK}
	} else {
		accept_storage, allocation_error := make([]u8, 28, request.allocator)
		if allocation_error != nil {
			return {status = .Internal_Server_Error}, true
		}
		accept, status := websocket_accept(request, accept_storage)
		if status != .None {
			return {status = status}, true
		}
		response = make_response(
			request,
			.Switching_Protocols,
			{{"Upgrade", "websocket"}, {"Sec-WebSocket-Accept", accept}},
		)
		if response.status != .Switching_Protocols {
			return response, true
		}
	}
	session, error := new(Reload_Session, rt.heap_allocator())
	if error != nil {
		return {status = .Internal_Server_Error}, true
	}
	session.state = state
	session.version = sync.atomic_load(&state.version)
	// Lets the session end when the server drains instead of holding it open
	// for the whole drain timeout. Without a context it ends on state.stopped.
	session.request_context, _ = core.retain_request_context(request.cancellation)
	response.upgrade = {
		data   = session,
		resume = resume_session,
		drop   = drop_session,
	}

	return response, true
}

drop_session :: proc(data: rawptr) {
	session := cast(^Reload_Session)data
	core.release_request_context(&session.request_context)
	free(session, rt.heap_allocator())
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
		if sync.atomic_load(&session.state.stopped) || core.request_server_stopping(session.request_context) {
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
send_bytes :: core.send_bytes
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

valid_close_code :: proc(code: u16) -> bool {
	return (code >= 1000 && code <= 1003) || (code >= 1007 && code <= 1014) || (code >= 3000 && code <= 4999)
}
