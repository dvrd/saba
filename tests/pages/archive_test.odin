package saba_pages_test

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import assets "shared:saba/assets"
import core "shared:saba/core"
import modules "shared:saba/modules"
import pages "shared:saba/pages"

Delivery_Fixture :: struct {
	directory, work, archive: string,
	source:                   string,
	mount:                    pages.Page_Mount,
}

delivery_write :: proc(path, text: string) {
	assert(os.write_entire_file(path, text) == nil)
}

delivery_page :: proc(label: string) -> string {
	return fmt.tprintf(
		"import {{extra}} from './data.js'; export const title = '%s'; export default function App() {{return <main><h1>%s</h1><output>{{extra()}}</output></main>}}",
		label,
		label,
	)
}

// One compiled page over a module mount, with an archive directory beside it.
delivery_fixture :: proc(label := "Alpha") -> Delivery_Fixture {
	directory, err := os.make_directory_temp("", "saba-delivery-test-*", context.allocator)
	assert(err == nil)
	fixture := Delivery_Fixture {
		directory = directory,
		work      = fmt.aprintf("%s/modules", directory),
		archive   = fmt.aprintf("%s/builds", directory),
	}
	assert(os.make_directory(fixture.work) == nil)
	delivery_write(fmt.tprintf("%s/page.jsx", fixture.work), delivery_page(label))
	delivery_write(fmt.tprintf("%s/data.js", fixture.work), "export const extra = () => 'ready'")
	// Owned storage: each case may edit its own page and variant.
	variants := make([]pages.Template_Variant, 1)
	variants[0] = {
		language       = "en",
		module_url     = "/ui/page.js",
		source_file    = fmt.aprintf("%s/page.jsx", fixture.work),
		recovery_label = "Reload",
	}
	compiled := make([]pages.Compiled_Page, 1)
	compiled[0] = {
		path     = "/",
		variants = variants,
	}
	fixture.source = variants[0].source_file
	fixture.mount = {
		templates = {archive_directory = fixture.archive, pages = compiled},
	}
	return fixture
}

delivery_destroy :: proc(fixture: ^Delivery_Fixture) {
	delete(fixture.source)
	delete(fixture.mount.templates.pages[0].variants)
	delete(fixture.mount.templates.pages)
	os.remove_all(fixture.directory)
	delete(fixture.work)
	delete(fixture.archive)
	delete(fixture.directory)
}

delivery_prepare :: proc(
	fixture: Delivery_Fixture,
	allocator: mem.Allocator,
) -> (
	pages.Page_Cache,
	bool,
) {
	mods, ok := modules.prepare_module_mounts(
		{{directory = fixture.work, prefix = "/ui/"}},
		false,
		allocator,
	)
	if !ok {
		return {}, false
	}
	return pages.prepare_pages(fixture.mount, false, allocator, mods)
}

delivery_get :: proc(cache: pages.Page_Cache, path: string, allocator: mem.Allocator) -> core.Response {
	request := core.Request {
		method    = "GET",
		path      = path,
		allocator = allocator,
	}
	response, _ := pages.serve_build_asset(&request, cache)
	return response
}

delivery_archive :: proc(fixture: Delivery_Fixture, id: string, retired_at: i64, body: string) {
	files := make(map[string]string, context.temp_allocator)
	files["/ui/old.js"] = body
	data, err := json.marshal(
		pages.Retained_Build{id = id, files = files, retired_at = retired_at},
		allocator = context.temp_allocator,
	)
	assert(err == nil)
	assert(os.write_entire_file(fmt.tprintf("%s/%s.saba-build.json", fixture.archive, id), data) == nil)
}

delivery_archived :: proc(fixture: Delivery_Fixture, id: string) -> (pages.Retained_Build, bool) {
	bytes, err := os.read_entire_file(
		fmt.tprintf("%s/%s.saba-build.json", fixture.archive, id),
		context.temp_allocator,
	)
	if err != nil {
		return {}, false
	}
	archive: pages.Retained_Build
	parsed := json.unmarshal(bytes, &archive, allocator = context.temp_allocator) == nil
	return archive, parsed
}

Captured_Log :: struct {
	errors, warnings: int,
	text:             strings.Builder,
}

capture_logger :: proc(captured: ^Captured_Log) -> log.Logger {
	return {
		procedure = proc(
			data: rawptr,
			level: log.Level,
			text: string,
			options: log.Options,
			location := #caller_location,
		) {
			captured := cast(^Captured_Log)data
			if level >= .Error {
				captured.errors += 1
			} else if level >= .Warning {
				captured.warnings += 1
			}
			strings.write_string(&captured.text, text)
			strings.write_byte(&captured.text, '\n')
		},
		data = captured,
		lowest_level = .Debug,
	}
}

// Finding 1: the generation is named by what it serves, not by the process.
@(test)
build_identity_follows_content :: proc(t: ^testing.T) {
	fixture := delivery_fixture()
	defer delivery_destroy(&fixture)
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)

	first, ok := delivery_prepare(fixture, allocator)
	if !testing.expect(t, ok, "first build failed") {
		return
	}
	// A second process, or a restart, over the same sources and the same archive.
	second, again := delivery_prepare(fixture, allocator)
	if !testing.expect(t, again, "preparing the same content twice failed") {
		return
	}
	testing.expect_value(t, second.build.id, first.build.id)
	testing.expect_value(t, len(first.build.id), 32)
	html := string(first.build.documents["/"].variants["en"].body)
	testing.expect_value(t, string(second.build.documents["/"].variants["en"].body), html)
	testing.expect(t, strings.contains(html, fmt.tprintf(`data-generation="%s"`, first.build.id)))
	testing.expect(t, !strings.contains(html, "pending-"), "the document kept its build placeholder")
	entry := delivery_get(
		second,
		fmt.tprintf("/__saba/build/%s/__saba/entry-0-0.js", first.build.id),
		allocator,
	)
	testing.expect_value(t, entry.status, core.HTTP_Status.OK)
	testing.expect(t, strings.contains(string(entry.body), first.build.id))
	testing.expect(t, !strings.contains(string(entry.body), "pending-"))
	// Another host with its own checkout path and no shared archive agrees.
	elsewhere := delivery_fixture()
	defer delivery_destroy(&elsewhere)
	elsewhere.mount.templates.archive_directory = ""
	remote, built := delivery_prepare(elsewhere, allocator)
	testing.expect(t, built)
	testing.expect_value(t, remote.build.id, first.build.id)
	testing.expect_value(t, string(remote.build.documents["/"].variants["en"].body), html)
	// Still the active generation: it has not started a retention period.
	archive, stored := delivery_archived(fixture, first.build.id)
	testing.expect(t, stored && archive.retired_at == 0)

	delivery_write(fmt.tprintf("%s/data.js", fixture.work), "export const extra = () => 'changed'")
	changed, published := delivery_prepare(fixture, allocator)
	if !testing.expect(t, published) {
		return
	}
	testing.expect(t, changed.build.id != first.build.id, "different bytes shared a generation")
	old_module := fmt.tprintf("/__saba/build/%s/ui/data.js", first.build.id)
	retained := delivery_get(changed, old_module, allocator)
	testing.expect(t, strings.contains(string(retained.body), "'ready'"))
	current := delivery_get(changed, fmt.tprintf("/__saba/build/%s/ui/data.js", changed.build.id), allocator)
	testing.expect(t, strings.contains(string(current.body), "'changed'"))
	archive, stored = delivery_archived(fixture, first.build.id)
	testing.expect(t, stored && archive.retired_at > 0, "a superseded generation was not stamped")

	// Rolling back names the original generation again and reactivates it.
	delivery_write(fmt.tprintf("%s/data.js", fixture.work), "export const extra = () => 'ready'")
	restored, rolled_back := delivery_prepare(fixture, allocator)
	testing.expect(t, rolled_back)
	testing.expect_value(t, restored.build.id, first.build.id)
	archive, stored = delivery_archived(fixture, first.build.id)
	testing.expect(t, stored && archive.retired_at == 0)
	still := delivery_get(restored, old_module, allocator)
	testing.expect(t, strings.contains(string(still.body), "'ready'"))
}

// Finding 2: a file the build cannot use is reported and skipped.
@(test)
unusable_archives_are_skipped_with_a_warning :: proc(t: ^testing.T) {
	fixture := delivery_fixture()
	defer delivery_destroy(&fixture)
	fixture.mount.templates.archive_retention = {
		max_archive_bytes = 64 * 1024,
	}
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)
	assert(os.make_directory(fixture.archive) == nil)

	now := time.to_unix_seconds(time.now())
	delivery_archive(fixture, "good", now - 60, "export default 'good'")
	// Truncated by a crash, renamed by hand, oversized, and not a regular archive.
	delivery_write(fmt.tprintf("%s/torn.saba-build.json", fixture.archive), `{"id":"torn","files":{"/ui/old.js":"exp`)
	delivery_archive(fixture, "other", now - 60, "export default 'other'")
	assert(
		os.rename(
			fmt.tprintf("%s/other.saba-build.json", fixture.archive),
			fmt.tprintf("%s/renamed.saba-build.json", fixture.archive),
		) ==
		nil,
	)
	delivery_archive(fixture, "huge", now - 60, strings.repeat("x", 128 * 1024, context.temp_allocator))
	delivery_write(fmt.tprintf("%s/bad name.saba-build.json", fixture.archive), "{}")
	delivery_archive(fixture, "escape", now - 60, "export default 1")
	delivery_write(
		fmt.tprintf("%s/escape.saba-build.json", fixture.archive),
		`{"id":"escape","files":{"ui/no-slash.js":"x"},"retired_at":1}`,
	)
	// One writer died long ago; another is in the middle of its rename.
	stale := fmt.tprintf("%s/dead.0011.saba-build.json.staging", fixture.archive)
	fresh := fmt.tprintf("%s/live.0022.saba-build.json.staging", fixture.archive)
	delivery_write(stale, "{")
	delivery_write(fresh, "{")
	long_ago := time.time_add(time.now(), -2 * time.Hour)
	assert(os.change_times(stale, long_ago, long_ago) == nil)

	captured: Captured_Log
	defer strings.builder_destroy(&captured.text)
	cache: pages.Page_Cache
	ok: bool
	{
		context.logger = capture_logger(&captured)
		cache, ok = delivery_prepare(fixture, allocator)
	}
	if !testing.expect(t, ok, "damaged archives stopped the build") {
		return
	}
	testing.expect_value(t, captured.errors, 0)
	testing.expect_value(t, captured.warnings, 5)
	for name in ([]string{"torn", "renamed", "huge", "bad name", "escape"}) {
		testing.expectf(
			t,
			strings.contains(strings.to_string(captured.text), fmt.tprintf("%s.saba-build.json", name)),
			"no warning named %s",
			name,
		)
		// Left for the operator; only expiry removes an archive.
		testing.expect(t, os.exists(fmt.tprintf("%s/%s.saba-build.json", fixture.archive, name)))
	}
	good := delivery_get(cache, "/__saba/build/good/ui/old.js", allocator)
	testing.expect_value(t, good.status, core.HTTP_Status.OK)
	testing.expect_value(t, string(good.body), "export default 'good'")
	for id in ([]string{"torn", "other", "renamed", "huge", "escape"}) {
		miss := delivery_get(cache, fmt.tprintf("/__saba/build/%s/ui/old.js", id), allocator)
		testing.expect_value(t, miss.status, core.HTTP_Status.Not_Found)
	}
	testing.expect(t, !os.exists(stale), "an abandoned staging file was kept")
	testing.expect(t, os.exists(fresh), "a live staging file was removed")
	testing.expect(t, os.exists(fmt.tprintf("%s/%s.saba-build.json", fixture.archive, cache.build.id)))
	// Nothing of this build's own is left half-written.
	listing, list_err := os.read_all_directory_by_path(fixture.archive, context.temp_allocator)
	assert(list_err == nil)
	staging := 0
	for file in listing {
		if strings.has_suffix(file.name, ".staging") {
			staging += 1
		}
	}
	testing.expect_value(t, staging, 1)

	// An archive that vanishes or is a directory is not an error either.
	assert(os.make_directory(fmt.tprintf("%s/folder.saba-build.json", fixture.archive)) == nil)
	{
		context.logger = capture_logger(&captured)
		_, ok = delivery_prepare(fixture, allocator)
	}
	testing.expect(t, ok)
	testing.expect_value(t, captured.errors, 0)
}

// Finding 2: retention is a setting, applied by every build.
@(test)
archives_expire_by_age_and_count :: proc(t: ^testing.T) {
	fixture := delivery_fixture()
	defer delivery_destroy(&fixture)
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)
	assert(os.make_directory(fixture.archive) == nil)
	context.logger = log.nil_logger() // Each removal is reported.

	now := time.to_unix_seconds(time.now())
	hour :: 3600
	delivery_archive(fixture, "fresh", 0, "export default 'fresh'") // never yet superseded
	delivery_archive(fixture, "recent", now - 1 * hour, "export default 'recent'")
	delivery_archive(fixture, "older", now - 3 * hour, "export default 'older'")
	delivery_archive(fixture, "ancient", now - 30 * hour, "export default 'ancient'")

	fixture.mount.templates.archive_retention = {
		max_age   = 24 * time.Hour,
		max_count = -1,
	}
	by_age, ok := delivery_prepare(fixture, allocator)
	if !testing.expect(t, ok) {
		return
	}
	testing.expect(t, !os.exists(fmt.tprintf("%s/ancient.saba-build.json", fixture.archive)))
	testing.expect_value(
		t,
		delivery_get(by_age, "/__saba/build/ancient/ui/old.js", allocator).status,
		core.HTTP_Status.Not_Found,
	)
	for id in ([]string{"fresh", "recent", "older"}) {
		kept := delivery_get(by_age, fmt.tprintf("/__saba/build/%s/ui/old.js", id), allocator)
		testing.expectf(t, kept.status == .OK, "%s was dropped inside its retention period", id)
		testing.expect_value(t, field(kept, "Cache-Control"), "public, max-age=31536000, immutable")
	}
	// Its period starts at the build that first found it superseded.
	stamped, stored := delivery_archived(fixture, "fresh")
	testing.expect(t, stored && stamped.retired_at >= now && stamped.retired_at <= now + 60)
	testing.expect_value(t, stamped.files["/ui/old.js"], "export default 'fresh'")

	fixture.mount.templates.archive_retention = {
		max_age   = -1,
		max_count = 2,
	}
	by_count, counted := delivery_prepare(fixture, allocator)
	if !testing.expect(t, counted) {
		return
	}
	testing.expect(t, !os.exists(fmt.tprintf("%s/older.saba-build.json", fixture.archive)))
	testing.expect_value(
		t,
		delivery_get(by_count, "/__saba/build/older/ui/old.js", allocator).status,
		core.HTTP_Status.Not_Found,
	)
	for id in ([]string{"fresh", "recent"}) {
		kept := delivery_get(by_count, fmt.tprintf("/__saba/build/%s/ui/old.js", id), allocator)
		testing.expectf(t, kept.status == .OK, "%s was dropped although it is among the newest", id)
	}
	// The active generation is never counted against the limit or expired.
	testing.expect(t, os.exists(fmt.tprintf("%s/%s.saba-build.json", fixture.archive, by_count.build.id)))

	// With no setting at all the directory is still bounded.
	fixture.mount.templates.archive_retention = {}
	for index in 0 ..< 12 {
		delivery_archive(fixture, fmt.tprintf("bulk%d", index), now - i64(index + 2) * hour, "export default 0")
	}
	_, bounded := delivery_prepare(fixture, allocator)
	testing.expect(t, bounded)
	listing, list_err := os.read_all_directory_by_path(fixture.archive, context.temp_allocator)
	assert(list_err == nil)
	testing.expect_value(t, len(listing), pages.DEFAULT_ARCHIVE_MAX_COUNT + 1)
}

// Findings 4, 5 and 12: what a build asset response says about itself.
@(test)
build_responses_declare_type_and_cache_policy :: proc(t: ^testing.T) {
	fixture := delivery_fixture()
	defer delivery_destroy(&fixture)
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)
	cache, ok := delivery_prepare(fixture, allocator)
	if !testing.expect(t, ok) {
		return
	}
	hit := delivery_get(cache, fmt.tprintf("/__saba/build/%s/ui/data.js", cache.build.id), allocator)
	testing.expect_value(t, hit.status, core.HTTP_Status.OK)
	testing.expect_value(t, field(hit, "X-Content-Type-Options"), "nosniff")
	testing.expect_value(t, field(hit, "Content-Type"), "text/javascript; charset=utf-8")
	for path in ([]string {
			"/__saba/build/0123456789abcdef0123456789abcdef/ui/data.js",
			fmt.tprintf("/__saba/build/%s/ui/missing.js", cache.build.id),
			fmt.tprintf("/__saba/build/%s/ui/%%2e%%2e/data.js/", cache.build.id),
		}) {
		miss := delivery_get(cache, path, allocator)
		testing.expect_value(t, miss.status, core.HTTP_Status.Not_Found)
		testing.expect_value(t, field(miss, "Cache-Control"), "no-store")
		testing.expect_value(t, field(miss, "X-Content-Type-Options"), "nosniff")
	}
	request := core.Request {
		method    = "GET",
		path      = "/",
		allocator = allocator,
	}
	document, matched := pages.serve_prepared_pages(&request, cache, false)
	testing.expect(t, matched && document.status == .OK)
	testing.expect_value(t, field(document, "X-Content-Type-Options"), "nosniff")

	testing.expect_value(t, pages.build_content_type("/ui/data.js"), "text/javascript; charset=utf-8")
	testing.expect_value(t, pages.build_content_type("/ui/.saba-view-0-0.js"), "text/javascript; charset=utf-8")
	testing.expect_value(t, pages.build_content_type("/ui/copy.json"), "application/json")
	testing.expect_value(t, pages.build_content_type("/ui/theme.css"), "text/css; charset=utf-8")

	// A JSON module is linked as data, not parsed as a script.
	linker := pages.Module_Linker {
		prefix    = "/__saba/build/g1",
		input     = make(map[string]string, allocator),
		output    = make(map[string]string, allocator),
		startup   = make(map[string][]string, allocator),
		allocator = allocator,
	}
	linker.input["/ui/a.js"] = `import copy from './copy.json' with {type: 'json'}; export default copy`
	linker.input["/ui/copy.json"] = `{"title": "Welcome"}`
	if testing.expect(t, pages.link_module(&linker, "/ui/a.js"), "a JSON module import did not link") {
		testing.expect_value(t, linker.output["/ui/copy.json"], `{"title": "Welcome"}`)
		testing.expect(t, strings.contains(linker.output["/ui/a.js"], `"/__saba/build/g1/ui/copy.json" with {type: 'json'}`))
	}
}

// Finding 6: every refusal says why.
@(test)
refused_builds_name_their_reason :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)

	Case :: struct {
		name:   string,
		change: proc(fixture: ^Delivery_Fixture),
		expect: string,
	}
	for item in ([]Case {
			{"path", proc(f: ^Delivery_Fixture) {f.mount.templates.pages[0].path = "items/"}, "Invalid compiled page path"},
			{"parameter", proc(f: ^Delivery_Fixture) {f.mount.templates.pages[0].path = "/[1d]"}, "Invalid route parameters"},
			{
				"label",
				proc(f: ^Delivery_Fixture) {f.mount.templates.pages[0].variants[0].recovery_label = ""},
				"no recovery label",
			},
			{
				"language",
				proc(f: ^Delivery_Fixture) {f.mount.templates.pages[0].variants[0].language = ""},
				"has no language",
			},
			{
				"module",
				proc(f: ^Delivery_Fixture) {f.mount.templates.pages[0].variants[0].module_url = "ui/page.js"},
				"must be a root-absolute .js path",
			},
			{
				"vary",
				proc(f: ^Delivery_Fixture) {
					f.mount.templates.pages[0].revalidate = true
					f.mount.templates.pages[0].language = proc(_: ^core.Request) -> string {return "en"}
				},
				"requires Vary",
			},
			{
				"archive",
				proc(f: ^Delivery_Fixture) {
					// A file where the archive directory should be.
					delivery_write(f.archive, "not a directory")
				},
				"build archive directory",
			},
			{
				"limit",
				proc(f: ^Delivery_Fixture) {f.mount.limits = {max_file_bytes = 16}},
				"limit 16 bytes",
			},
			{
				"total",
				proc(f: ^Delivery_Fixture) {f.mount.limits = {max_total_bytes = 64}},
				"exceed the limit of 64 bytes",
			},
		}) {
		fixture := delivery_fixture()
		defer delivery_destroy(&fixture)
		item.change(&fixture)
		captured: Captured_Log
		defer strings.builder_destroy(&captured.text)
		ok: bool
		{
			context.logger = capture_logger(&captured)
			_, ok = delivery_prepare(fixture, allocator)
		}
		testing.expectf(t, !ok, "%s: an invalid build was published", item.name)
		testing.expectf(t, captured.errors > 0, "%s: the build was refused without an error", item.name)
		testing.expectf(
			t,
			strings.contains(strings.to_string(captured.text), item.expect),
			"%s: expected %q in %q",
			item.name,
			item.expect,
			strings.to_string(captured.text),
		)
	}
}

// Finding 7: module and page preparation is bounded like asset preparation.
@(test)
module_and_page_preparation_is_bounded :: proc(t: ^testing.T) {
	directory, err := os.make_directory_temp("", "saba-limits-test-*", context.allocator)
	assert(err == nil)
	defer delete(directory)
	defer os.remove_all(directory)
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)
	assert(os.make_directory(fmt.tprintf("%s/server", directory)) == nil)
	assert(os.make_directory(fmt.tprintf("%s/tools", directory)) == nil)
	delivery_write(fmt.tprintf("%s/a.js", directory), "export const a = 1")
	delivery_write(fmt.tprintf("%s/view.jsx", directory), "export default () => <b>ok</b>")
	delivery_write(fmt.tprintf("%s/server/secrets.js", directory), "export const key = 'server only'")
	delivery_write(fmt.tprintf("%s/tools/build.jsx", directory), "export default () => <i>tool</i>")
	delivery_write(fmt.tprintf("%s/tools/kept.js", directory), "export const kept = 1")

	all, ok := modules.prepare_module_mounts({{directory = directory, prefix = "/m/"}}, false, allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(all[0].files), 5)

	chosen, selected := modules.prepare_module_mounts(
		{{directory = directory, prefix = "/m/", exclude = {"server", "/tools/build.jsx"}}},
		false,
		allocator,
	)
	if testing.expect(t, selected) {
		testing.expect_value(t, len(chosen[0].files), 3)
		testing.expect(t, "server/secrets.js" not_in chosen[0].files)
		testing.expect(t, "tools/build.js" not_in chosen[0].files)
		testing.expect(t, "tools/kept.js" in chosen[0].files)
		request := core.Request {
			method    = "GET",
			allocator = allocator,
		}
		for development in ([]bool{false, true}) {
			for path in ([]string{"/m/server/secrets.js", "/m/tools/build.js"}) {
				request.path = path
				response, matched := modules.serve_prepared_modules(&request, chosen, development)
				testing.expect(t, matched)
				testing.expectf(t, response.status == .Not_Found, "%s was served (development %v)", path, development)
			}
			request.path = "/m/tools/kept.js"
			response, matched := modules.serve_prepared_modules(&request, chosen, development)
			testing.expect(t, matched && response.status == .OK)
			testing.expect_value(t, field(response, "X-Content-Type-Options"), "nosniff")
		}
	}

	captured: Captured_Log
	defer strings.builder_destroy(&captured.text)
	for item in ([]struct {
			limits: assets.Asset_Limits,
			expect: string,
		} {
			{{max_files = 4}, "limit of 4 files"},
			{{max_entries = 3}, "limit of 3 entries"},
			{{max_file_bytes = 20}, "limit of 20 bytes"},
			{{max_total_bytes = 40}, "limit of 40 retained bytes"},
			{{max_mounts = -1}, "limits are invalid"},
		}) {
		strings.builder_reset(&captured.text)
		captured.errors = 0
		refused: bool
		{
			context.logger = capture_logger(&captured)
			_, refused = modules.prepare_module_mounts(
				{{directory = directory, prefix = "/m/"}},
				false,
				allocator,
				item.limits,
			)
		}
		testing.expectf(t, !refused, "module mounts ignored %v", item.limits)
		testing.expectf(
			t,
			strings.contains(strings.to_string(captured.text), item.expect),
			"expected %q in %q",
			item.expect,
			strings.to_string(captured.text),
		)
	}

	// Legacy page mounts: the shell and the number of routes are bounded too.
	shell := fmt.tprintf("%s/shell.html", directory)
	delivery_write(shell, "<html><head></head><body><!--saba:page--></body></html>")
	mount := pages.Page_Mount {
		directory     = directory,
		shell         = shell,
		module_prefix = "/m/",
	}
	_, plain := pages.prepare_pages(mount, false, allocator)
	testing.expect(t, plain)
	for item in ([]struct {
			limits: assets.Asset_Limits,
			expect: string,
		} {
			{{max_files = 1}, "limit of 1 pages"},
			{{max_file_bytes = 8}, "limit 8 bytes"},
			{{max_total_bytes = 60}, "limit of 60 bytes"},
		}) {
		strings.builder_reset(&captured.text)
		mount.limits = item.limits
		bounded: bool
		{
			context.logger = capture_logger(&captured)
			_, bounded = pages.prepare_pages(mount, false, allocator)
		}
		testing.expectf(t, !bounded, "page preparation ignored %v", item.limits)
		testing.expectf(
			t,
			strings.contains(strings.to_string(captured.text), item.expect),
			"expected %q in %q",
			item.expect,
			strings.to_string(captured.text),
		)
	}
}
