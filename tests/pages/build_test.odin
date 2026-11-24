package saba_pages_test

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import core "shared:saba/core"
import modules "shared:saba/modules"
import pages "shared:saba/pages"

field :: proc(reply: core.Response, name: string) -> string {
	for header in reply.headers {
		if strings.equal_fold(header.name, name) {
			return header.value
		}
	}
	return ""
}


@(test)
compiled_documents_keep_their_generation_and_language :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "saba-template-test-*", context.allocator)
	assert(err == nil)
	defer delete(dir)
	defer os.remove_all(dir)
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)
	work := fmt.tprintf("%s/modules", dir)
	assert(os.make_directory(work) == nil)
	write :: proc(root, name, source: string) {
		assert(os.write_entire_file(fmt.tprintf("%s/%s", root, name), source) == nil)
	}
	make_page :: proc(title: string) -> string {
		return fmt.tprintf(
			"import {{extra}} from './data.js'; export const title = '%s'; export default function App() {{return <section><h1>%s</h1><p>%s</p><output>{{extra()}}</output></section>}}",
			title,
			title,
			strings.repeat("Ready to review. ", 80, context.temp_allocator),
		)
	}
	write(work, "en.jsx", make_page("Welcome"))
	write(work, "es.jsx", make_page("Bienvenido"))
	write(
		work,
		"data.js",
		"export const extra = () => 'ready'; export const later = () => import('./later.js')",
	)
	write(work, "later.js", "export {mountSlotWindow} from '/__saba/slot-window.js'; export default 'release A'")
	mount := pages.Page_Mount {
		templates = {
			archive_directory = fmt.tprintf("%s/builds", dir),
			pages = {
				{
					path = "/items/[id]",
					variants = {
						{
							language = "es",
							module_url = "/ui/es.js",
							source_file = fmt.tprintf("%s/es.jsx", work),
							recovery_label = "Recargar",
						},
						{
							language = "en",
							module_url = "/ui/en.js",
							source_file = fmt.tprintf("%s/en.jsx", work),
							recovery_label = "Reload",
						},
					},
					vary = "Accept-Language",
					language = proc(request: ^core.Request) -> string {
						return core.header_value(request, "Accept-Language")
					},
					authorize = proc(request: ^core.Request) -> (core.Response, bool) {
						if core.header_value(request, "Cookie") == "" {
							return core.make_response(request, .Unauthorized), false
						}
						return {}, true
					},
				},
			},
		},
	}
	prepare :: proc(
		path: string,
		mount: pages.Page_Mount,
		allocator: mem.Allocator,
	) -> (
		pages.Page_Cache,
		bool,
	) {
		mods, ok := modules.prepare_module_mounts(
			{{directory = path, prefix = "/ui/"}},
			false,
			allocator,
		)
		if !ok {
			return {}, false
		}
		return pages.prepare_pages(mount, false, allocator, mods)
	}
	old, ok := prepare(work, mount, allocator)
	if !testing.expect(t, ok, "first build failed") {
		return
	}
	request := core.Request {
		path      = "/items/42",
		method    = "GET",
		allocator = allocator,
	}
	doc, matched := pages.serve_prepared_pages(&request, old, false)
	testing.expect(t, matched && doc.status == .Unauthorized)
	request.headers = {{"Cookie", "a"}, {"Accept-Language", "en"}}
	doc, _ = pages.serve_prepared_pages(&request, old, false)
	body := string(doc.body)
	testing.expect(
		t,
		strings.contains(body, "Welcome") && strings.contains(body, "data-saba-recover"),
	)
	testing.expect(t, strings.contains(body, `lang="en"`) && strings.contains(body, " data-saba-pending") && !strings.contains(body, " inert"))
	testing.expect(t, strings.contains(body, old.build.id))
	testing.expect(
		t,
		strings.count(body, "/__saba/dom.js") == 1 && strings.contains(body, "/ui/data.js"),
	)
	testing.expect(
		t,
		!strings.contains(body, "/ui/later.js"),
		"optional imports should be fetched only on use",
	)
	request.path = "/items/99"
	request.headers = {{"Cookie", "b"}, {"Accept-Language", "en"}}
	other, _ := pages.serve_prepared_pages(&request, old, false)
	testing.expect_value(t, string(other.body), body)
	request.headers = {{"Cookie", "a"}, {"Accept-Language", "es"}, {"If-None-Match", "*"}}
	spanish, _ := pages.serve_prepared_pages(&request, old, false)
	testing.expect_value(t, spanish.status, core.HTTP_Status.OK)
	testing.expect(t, strings.contains(string(spanish.body), "Bienvenido"))
	// A no-store document can still be served straight from its encoded build.
	// Even a wildcard validator cannot turn this into a 304.
	request.headers = {
		{"Cookie", "a"},
		{"Accept-Language", "es"},
		{"Accept-Encoding", "br"},
		{"If-None-Match", "*"},
	}
	uncached, _ := pages.serve_prepared_pages(&request, old, false)
	cached_br := old.build.documents["/items/:id"].variants["es"].brotli.body
	testing.expect(t, uncached.status == .OK && uncached.uncoded && len(cached_br) != 0)
	testing.expect_value(t, raw_data(uncached.body), raw_data(cached_br))
	testing.expect_value(t, field(uncached, "Cache-Control"), "private, no-store")
	testing.expect_value(t, field(uncached, "Content-Encoding"), "br")
	testing.expect_value(t, field(uncached, "Vary"), "Accept-Language, Accept-Encoding")
	testing.expect_value(t, field(uncached, "ETag"), "")
	core.content_coding_prepare(&request, &uncached)
	testing.expect_value(t, raw_data(uncached.body), raw_data(cached_br))
	testing.expect_value(t, field(uncached, "Content-Encoding"), "br")

	write(work, "later.js", "export {mountSlotWindow} from '/__saba/slot-window.js'; export default 'release B'")
	current, published := prepare(work, mount, allocator)
	if !testing.expect(t, published && current.build.id != old.build.id) {
		return
	}
	for version in ([]struct {
			id, expected: string,
		}{{old.build.id, "release A"}, {current.build.id, "release B"}}) {
		request.headers = nil
		request.path = fmt.tprintf("/__saba/build/%s/ui/later.js", version.id)
		asset, owned := pages.serve_build_asset(&request, current)
		testing.expect(t, owned && strings.contains(string(asset.body), version.expected))
		request.path = fmt.tprintf("/__saba/build/%s/ui/data.js", version.id)
		linked, _ := pages.serve_build_asset(&request, current)
		testing.expect(
			t,
			strings.contains(
				string(linked.body),
				fmt.tprintf("/__saba/build/%s/ui/later.js", version.id),
			),
		)
		request.path = fmt.tprintf("/__saba/build/%s/__saba/slot-window.js", version.id)
		slot_window, slot_hit := pages.serve_build_asset(&request, current)
		scalar_url := fmt.tprintf("/__saba/build/%s/__saba/scalar-records.js", version.id)
		testing.expect(t, slot_hit && strings.contains(string(slot_window.body), scalar_url))
		request.path = scalar_url
		scalar, scalar_hit := pages.serve_build_asset(&request, current)
		testing.expect(t, scalar_hit && scalar.status == .OK && string(scalar.body) == modules.SCALAR_RECORDS)
		// Test archived and active copies of a large immutable production dependency.
		request.path = fmt.tprintf("/__saba/build/%s/__saba/dom.js", version.id)
		request.headers = {{"Accept-Encoding", "gzip"}}
		encoded, hit := pages.serve_build_asset(&request, current)
		testing.expect(t, hit && encoded.uncoded && encoded.status == .OK)
		testing.expect_value(
			t,
			field(encoded, "Cache-Control"),
			"public, max-age=31536000, immutable",
		)
		testing.expect_value(t, field(encoded, "Vary"), "Accept-Encoding")
		testing.expect_value(t, field(encoded, "Content-Encoding"), "gzip")
		testing.expect_value(
			t,
			raw_data(encoded.body),
			raw_data(current.build.files[request.path].gzip.body),
		)
		gzip_tag := field(encoded, "ETag")
		testing.expect(t, strings.has_suffix(gzip_tag, "-gzip\""))
		request.headers = {{"Accept-Encoding", "gzip"}, {"If-None-Match", gzip_tag}}
		validated, _ := pages.serve_build_asset(&request, current)
		testing.expect(t, validated.status == .Not_Modified && len(validated.body) == 0)
		testing.expect_value(t, field(validated, "ETag"), gzip_tag)
		testing.expect_value(t, field(validated, "Vary"), "Accept-Encoding")
		testing.expect_value(t, field(validated, "Cache-Control"), field(encoded, "Cache-Control"))
		request.headers[0].value = "br"
		changed, _ := pages.serve_build_asset(&request, current)
		testing.expect(t, changed.status == .OK && field(changed, "ETag") != gzip_tag)
		testing.expect_value(t, field(changed, "Content-Encoding"), "br")
	}
	write(work, "data.js", "export {extra} from './missing.js'")
	context.logger = log.nil_logger() // The deliberately incomplete candidate reports a build diagnostic.
	_, failed := prepare(work, mount, allocator)
	testing.expect(t, !failed, "published a graph with a missing transitive dependency")
	request.path = "/items/42"
	request.headers = {{"Cookie", "a"}}
	still_ready, _ := pages.serve_prepared_pages(&request, current, false)
	testing.expect(t, strings.contains(string(still_ready.body), current.build.id))

	// A negotiated page selects its language and enforces access before
	// checking any validator. Use the actual bytes from this generation.
	doc_cache := current.build.documents["/items/:id"]
	doc_cache.config.revalidate = true
	doc_cache.config.vary = "Accept-Language"
	req := core.Request {
		method    = "GET",
		path      = "/items/42",
		allocator = allocator,
	}
	english_etag := doc_cache.variants["en"].tag
	req.headers = {
		{"Cookie", "a"},
		{"Accept-Language", "es"},
		{"If-None-Match", string(english_etag[:])},
	}
	new_lang := pages.serve_document(&req, doc_cache)
	testing.expect(
		t,
		new_lang.status == .OK && strings.contains(string(new_lang.body), "Bienvenido"),
	)
	spanish_etag := doc_cache.variants["es"].tag
	req.headers[2].value = string(spanish_etag[:])
	same_lang := pages.serve_document(&req, doc_cache)
	testing.expect(t, same_lang.status == .Not_Modified && len(same_lang.body) == 0)
	req.headers = {
		{"Cookie", "a"},
		{"Accept-Language", "es"},
		{"Accept-Encoding", "br"},
		{"If-None-Match", string(spanish_etag[:])},
	}
	coded := pages.serve_document(&req, doc_cache)
	testing.expect(t, coded.status == .OK && coded.uncoded)
	testing.expect_value(t, field(coded, "Content-Encoding"), "br")
	testing.expect_value(t, field(coded, "Cache-Control"), "private, no-cache")
	req.headers[3].value = field(coded, "ETag")
	req.method = "HEAD"
	matching := pages.serve_document(&req, doc_cache)
	testing.expect(t, matching.status == .Not_Modified && len(matching.body) == 0)
	testing.expect_value(t, field(matching, "ETag"), field(coded, "ETag"))
	testing.expect_value(t, field(matching, "Vary"), "Accept-Language, Accept-Encoding")
	testing.expect_value(t, field(matching, "Cache-Control"), "private, no-cache")
	req.headers[0].value = ""
	testing.expect_value(
		t,
		pages.serve_document(&req, doc_cache).status,
		core.HTTP_Status.Unauthorized,
	)
}
