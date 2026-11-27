package saba_development

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:time"

development_test_read :: proc(path: string) -> string {
	bytes, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return ""
	}

	return string(bytes)
}
development_test_wait :: proc(path, text: string, different := "") -> bool {
	deadline := time.tick_add(time.tick_now(), 20 * time.Second)

	for time.tick_diff(time.tick_now(), deadline) > 0 {
		value := development_test_read(path)
		if strings.contains(value, text) && value != different {
			return true
		}
		time.sleep(50 * time.Millisecond)
	}

	return false
}

@(test)
development_rebuild_keeps_failed_builds_running_and_cleans_up :: proc(t: ^testing.T) {
	directory, err := os.make_directory_temp("", "saba-backend-test-*", context.temp_allocator)
	if !testing.expect(t, err == nil, "isolated development directory") {
		return
	}
	defer _ = os.remove_all(directory)
	source := fmt.tprintf("%s/src", directory)
	if !testing.expect(t, os.make_directory_all(source) == nil, "source directory") {
		return
	}
	main_path := fmt.tprintf("%s/main.odin", source)
	value_path := fmt.tprintf("%s/value.json", source)
	if !testing.expect(t, os.write_entire_file(main_path, #load("../../tests/fixtures/apps/development/main.odin", string)) == nil, "prepare development edit") {
		return
	}
	if !testing.expect(t, os.write_entire_file(value_path, "first") == nil, "prepare development edit") {
		return
	}
	binary := fmt.tprintf("%s/supervisor", directory)
	compiler := os.get_env("ODIN", context.temp_allocator)
	if compiler == "" {
		compiler = "odin"
	}
	collection := fmt.tprintf("-collection:shared=%s", os.get_env("SABA_TEST_SHARED", context.temp_allocator))
	build, output, errors, built := os.process_exec(
		{command = {compiler, "build", source, fmt.tprintf("-out:%s", binary), collection}},
		context.temp_allocator,
	)
	if !testing.expectf(t, built == nil && build.success, "compile supervisor: %s%s", string(output), string(errors)) {
		return
	}
	log_path := fmt.tprintf("%s/output.log", directory)
	file, opened := os.create(log_path)
	if !testing.expect(t, opened == nil, "open development log") {
		return
	}
	defer _ = os.close(file)
	process, started := os.process_start({command = {binary}, working_dir = directory, stdout = file, stderr = file})
	if !testing.expect(t, started == nil, "start supervisor") {
		return
	}
	active := true
	defer if active {
		development_stop(process)
	}
	running := fmt.tprintf("%s/running", directory)
	if !testing.expect(t, development_test_wait(running, ":first"), "initial child runs without rebuilding") {
		return
	}
	before := development_test_read(running)
	if !testing.expect(t, os.write_entire_file(value_path, "second") == nil, "prepare development edit") {
		return
	}
	if !testing.expectf(t, development_test_wait(running, ":second"), "successful edit restarts: %s", development_test_read(log_path)) {
		return
	}
	second := development_test_read(running)
	testing.expect(t, second != before, "new child process")
	broken := fmt.tprintf("%s/broken.odin", source)
	if !testing.expect(t, os.write_entire_file(broken, "this is invalid Odin") == nil, "prepare development edit") {
		return
	}
	if !testing.expect(t, development_test_wait(log_path, "Build failed; the previous server is unchanged"), "compiler diagnostics stay visible") {
		return
	}
	time.sleep(700 * time.Millisecond)
	testing.expect(t, development_test_read(running) == second, "compile failure leaves last successful child running")
	if !testing.expect(t, os.remove(broken) == nil, "prepare development edit") {
		return
	}
	if !testing.expect(t, development_test_wait(running, ":second", second), "deleting broken source retries successfully") {
		return
	}
	before = development_test_read(running)
	if !testing.expect(t, os.write_entire_file(fmt.tprintf("%s/notes.md", source), "ignored documentation") == nil, "prepare development edit") {
		return
	}
	time.sleep(750 * time.Millisecond)
	testing.expect(t, development_test_read(running) == before, "documentation does not trigger builds")
	if !testing.expect(t, os.remove(value_path) == nil, "prepare development edit") {
		return
	}
	if !testing.expect(t, development_test_wait(log_path, "value.json"), "missing embedded file fails compilation") {
		return
	}
	testing.expect(t, development_test_read(running) == before, "deleted dependency cannot replace running child")
	if !testing.expect(t, os.write_entire_file(value_path, "third") == nil, "prepare development edit") {
		return
	}
	if !testing.expect(t, development_test_wait(running, ":third"), "recreating dependency recovers") {
		return
	}
	last := development_test_read(running)
	separator := strings.index_byte(last, ':')
	pid, parsed := strconv.parse_int(last[:separator])
	if !testing.expect(t, parsed, "child pid") {
		return
	}
	_ = os.process_terminate(process)
	state, waited := os.process_wait(process, 5 * time.Second)
	if !testing.expect(t, waited == nil && state.exited && state.success, "SIGTERM stops supervisor normally") {
		return
	}
	active = false
	testing.expect(
		t,
		posix.kill(posix.pid_t(pid), posix.Signal(0)) != posix.result(0),
		"stopping supervisor stops its child",
	)
}

@(test)
explicit_watch_roots_do_not_require_sdk_relative_shared_packages :: proc(t: ^testing.T) {
	context.logger = log.nil_logger() // Missing root rejection is intentional.
	testing.expect_value(t, development_compiler({compiler = "/explicit/compiler"}), "/explicit/compiler")
	directory, error := os.make_directory_temp("", "saba-watch-roots-*", context.temp_allocator)
	assert(error == nil)
	defer _ = os.remove_all(directory)
	roots := [1]string{directory}
	paths, valid := development_paths(
		{package_directory = directory, compiler = "/not/executed", watch_directories = roots[:]},
		"/not/executed",
	)
	testing.expect(t, valid)
	testing.expect_value(t, len(paths), 2)
	testing.expect_value(t, paths[1], directory)
	missing := [1]string{fmt.tprintf("%s/missing", directory)}
	_, valid = development_paths({package_directory = directory, watch_directories = missing[:]}, "/not/executed")
	testing.expect(t, !valid)
}

signature_test_write :: proc(path, text: string) {
	assert(os.write_entire_file(path, text) == nil)
}

@(test)
signature_hashes_content_only_when_size_or_mtime_change :: proc(t: ^testing.T) {
	directory, err := os.make_directory_temp("", "saba-signature-test-*", context.temp_allocator)
	if !testing.expect(t, err == nil, "isolated directory") {
		return
	}
	defer _ = os.remove_all(directory)
	first := fmt.tprintf("%s/a.js", directory)
	second := fmt.tprintf("%s/b.js", directory)
	signature_test_write(first, "alpha")
	signature_test_write(second, "beta")
	epoch := time.unix(1_700_000_000, 0)
	assert(os.change_times(first, epoch, epoch) == nil)
	assert(os.change_times(second, epoch, epoch) == nil)

	cache: Signature_Cache
	defer signature_cache_destroy(&cache)
	base, ok := web_signature(directory, &cache)
	testing.expect(t, ok)
	testing.expect_value(t, cache.hashed, 2)
	uncached, _ := web_signature(directory)
	testing.expect_value(t, base, uncached)

	// Unchanged (path, size, mtime): no file is read again.
	again, _ := web_signature(directory, &cache)
	testing.expect_value(t, again, base)
	testing.expect_value(t, cache.hashed, 2)

	// A touch re-reads one file but identical bytes keep the signature.
	later := time.unix(1_700_000_100, 0)
	assert(os.change_times(first, later, later) == nil)
	touched, _ := web_signature(directory, &cache)
	testing.expect_value(t, touched, base)
	testing.expect_value(t, cache.hashed, 3)

	// Same size, new mtime, new bytes: the signature changes.
	signature_test_write(first, "omega")
	latest := time.unix(1_700_000_200, 0)
	assert(os.change_times(first, latest, latest) == nil)
	edited, _ := web_signature(directory, &cache)
	testing.expect(t, edited != base)
	testing.expect_value(t, cache.hashed, 4)
	testing.expect_value(t, len(cache.files), 2)

	// Removed files leave the cache and the signature.
	assert(os.remove(second) == nil)
	removed, _ := web_signature(directory, &cache)
	testing.expect(t, removed != edited)
	testing.expect_value(t, len(cache.files), 1)
	testing.expect_value(t, cache.hashed, 4)
}

// The hot reload scan reads source text only, and never an unbounded file.
@(test)
web_signature_reads_only_bounded_source_text :: proc(t: ^testing.T) {
	directory, err := os.make_directory_temp("", "saba-watch-test-*", context.temp_allocator)
	if !testing.expect(t, err == nil, "isolated directory") {
		return
	}
	defer _ = os.remove_all(directory)
	assert(os.make_directory(fmt.tprintf("%s/node_modules", directory)) == nil)
	assert(os.make_directory(fmt.tprintf("%s/.cache", directory)) == nil)
	page := fmt.tprintf("%s/page.jsx", directory)
	image := fmt.tprintf("%s/photo.png", directory)
	bundle := fmt.tprintf("%s/bundle.js", directory)
	signature_test_write(page, "export default () => null")
	signature_test_write(image, "not really a png")
	signature_test_write(fmt.tprintf("%s/node_modules/dep.js", directory), "export default 1")
	signature_test_write(fmt.tprintf("%s/.cache/state.json", directory), "{}")
	signature_test_write(fmt.tprintf("%s/.env", directory), "SECRET=1")
	// Sparse: larger than the content limit without writing it.
	large, open_error := os.open(bundle, {.Write, .Create})
	assert(open_error == nil)
	_, seek_error := os.seek(large, WATCH_CONTENT_BYTES, .Start)
	assert(seek_error == nil)
	_, write_error := os.write(large, []u8{1})
	assert(write_error == nil)
	os.close(large)

	cache: Signature_Cache
	defer signature_cache_destroy(&cache)
	base, ok := web_signature(directory, &cache)
	testing.expect(t, ok)
	testing.expect_value(t, cache.hashed, 1) // page.jsx alone was read
	testing.expect_value(t, len(cache.files), 3)

	// Nothing under an ignored directory or a dotfile can trigger a reload.
	signature_test_write(fmt.tprintf("%s/node_modules/dep.js", directory), "export default 2")
	signature_test_write(fmt.tprintf("%s/.cache/state.json", directory), `{"n":1}`)
	signature_test_write(fmt.tprintf("%s/.env", directory), "SECRET=2")
	ignored, _ := web_signature(directory, &cache)
	testing.expect_value(t, ignored, base)

	// Unread files still publish a change of size or modification time.
	later := time.time_add(time.now(), time.Hour)
	assert(os.change_times(image, later, later) == nil)
	touched, _ := web_signature(directory, &cache)
	testing.expect(t, touched != base, "a replaced image did not change the signature")
	assert(os.change_times(bundle, later, later) == nil)
	rebuilt, _ := web_signature(directory, &cache)
	testing.expect(t, rebuilt != touched, "a replaced bundle did not change the signature")
	testing.expect_value(t, cache.hashed, 1)

	testing.expect(t, watched_content("a/View.JSX") && watched_content("site.css"))
	testing.expect(t, !watched_content("font.woff2") && !watched_content("archive.zip"))
}

// Only the page this server delivered may subscribe to reload events.
@(test)
reload_socket_rejects_foreign_origins :: proc(t: ^testing.T) {
	testing.expect(t, reload_origin_allowed("", "localhost:8080"))
	testing.expect(t, reload_origin_allowed("http://localhost:8080", "localhost:8080"))
	testing.expect(t, reload_origin_allowed("HTTPS://Dev.Example:8443", "dev.example:8443"))
	testing.expect(t, !reload_origin_allowed("http://evil.example", "localhost:8080"))
	testing.expect(t, !reload_origin_allowed("http://localhost:8080.evil.example", "localhost:8080"))
	testing.expect(t, !reload_origin_allowed("http://localhost:9090", "localhost:8080"))
	testing.expect(t, !reload_origin_allowed("null", "localhost:8080"))
	testing.expect(t, !reload_origin_allowed("http://localhost:8080", ""))

	state: Reload_State
	request := Request {
		method    = "GET",
		path      = "/__reload",
		allocator = context.temp_allocator,
	}
	handshake := []Header {
		{"Host", "localhost:8080"},
		{"Upgrade", "websocket"},
		{"Connection", "Upgrade"},
		{"Sec-WebSocket-Version", "13"},
		{"Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="},
		{"Origin", "http://evil.example"},
	}
	request.headers = handshake
	refused, matched := handle(&state, &request)
	testing.expect(t, matched)
	testing.expect_value(t, refused.status, HTTP_Status.Forbidden)
	testing.expect(t, refused.upgrade.data == nil)

	handshake[5].value = "http://localhost:8080"
	accepted, _ := handle(&state, &request)
	testing.expect_value(t, accepted.status, HTTP_Status.Switching_Protocols)
	if accepted.upgrade.drop != nil {
		accepted.upgrade.drop(accepted.upgrade.data)
	}
	// Non-browser clients send no Origin and keep working.
	request.headers = handshake[:5]
	tool, _ := handle(&state, &request)
	testing.expect_value(t, tool.status, HTTP_Status.Switching_Protocols)
	if tool.upgrade.drop != nil {
		tool.upgrade.drop(tool.upgrade.data)
	}
}

Watch_Step_Fixture :: struct {
	rebuilds: int,
	publish:  bool,
}

// A long session must not accumulate rebuild scratch on the watcher thread.
@(test)
watcher_releases_scratch_storage_after_each_scan :: proc(t: ^testing.T) {
	// The directory name must outlive the private scratch allocator below.
	directory, err := os.make_directory_temp("", "saba-watch-step-*", context.allocator)
	if !testing.expect(t, err == nil, "isolated directory") {
		return
	}
	defer delete(directory)
	defer _ = os.remove_all(directory)
	page := strings.concatenate({directory, "/page.js"})
	defer delete(page)
	signature_test_write(page, "one")

	fixture := Watch_Step_Fixture {
		publish = true,
	}
	state := Reload_State {
		directory = directory,
		reload_data = &fixture,
		before_reload = proc(data: rawptr) -> bool {
			fixture := cast(^Watch_Step_Fixture)data
			fixture.rebuilds += 1
			// What a rebuild does: formatted names and diagnostics in scratch storage.
			for index in 0 ..< 64 {
				_ = fmt.tprintf("/__saba/build/%d/module-%d.js", fixture.rebuilds, index)
			}
			return fixture.publish
		},
	}
	storage := make([]u8, 1 << 20)
	defer delete(storage)
	arena: mem.Arena
	mem.arena_init(&arena, storage)
	context.temp_allocator = mem.arena_allocator(&arena)

	cache: Signature_Cache
	defer signature_cache_destroy(&cache)
	progress: Watch_Progress
	progress.observed, _ = web_signature(directory, &cache)
	progress.published = progress.observed
	mem.arena_free_all(&arena)

	watch_web_step(&state, &progress, &cache)
	testing.expect_value(t, fixture.rebuilds, 0)
	signature_test_write(page, "two!")
	watch_web_step(&state, &progress, &cache) // observed
	testing.expect_value(t, fixture.rebuilds, 0)
	watch_web_step(&state, &progress, &cache) // confirmed and published
	testing.expect_value(t, fixture.rebuilds, 1)
	testing.expect_value(t, sync.atomic_load(&state.version), u64(1))
	testing.expect_value(t, arena.offset, 0)

	// A failed rebuild publishes nothing and still releases its scratch.
	fixture.publish = false
	signature_test_write(page, "three")
	watch_web_step(&state, &progress, &cache)
	watch_web_step(&state, &progress, &cache)
	testing.expect_value(t, fixture.rebuilds, 2)
	testing.expect_value(t, sync.atomic_load(&state.version), u64(1))
	testing.expect_value(t, arena.offset, 0)
}
