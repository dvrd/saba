package saba_development

import "core:hash"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

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
		[]Header {
			{"Content-Type", "text/javascript; charset=utf-8"},
			{"Cache-Control", "no-store"},
		},
		transmute([]u8)RELOAD_CLIENT,
	)
}


reload_html_response :: proc(response: Response) -> bool {
	if response.status != .None && response.status != .OK do return false

	for header in response.headers {
		if !strings.equal_fold(header.name, "Content-Type") do continue

		media_type := header.value
		if separator := strings.index_byte(media_type, ';'); separator >= 0 {
			media_type = media_type[:separator]
		}

		return strings.equal_fold(strings.trim_space(media_type), "text/html")
	}

	return false
}

inject_reload_client :: proc(
	html: []u8,
	allocator := context.allocator,
) -> (
	injected: []u8,
	ok: bool,
) {
	if strings.contains(string(html), RELOAD_CLIENT_TAG) do return nil, true

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
		if info.type != .Regular do continue

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
		if !ok do continue

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
