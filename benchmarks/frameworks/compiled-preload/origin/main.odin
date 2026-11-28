package main

import assets "../../../../src/assets"
import server "../../../../src/core"
import modules "../../../../src/modules"
import pages "../../../../src/pages"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:thread"
import "core:time"

Origin :: struct {
	cache:   pages.Page_Cache,
	control: pages.Compiled_Document,
	calls:   map[string]int,
	server:  server.Server_Control,
}

// Remove only the link elements emitted by the production linker. Keep the
// same compiled entry, module graph, generation and static form in both arms.
without_hints :: proc(html: string, allocator: mem.Allocator) -> string {
	out := strings.builder_make(allocator)
	prefix :: `<link rel="modulepreload" href="`
	rest := html
	for {
		start := strings.index(rest, prefix)
		if start < 0 {
			break
		}
		strings.write_string(&out, rest[:start])
		end := strings.index(rest[start + len(prefix):], `">`)
		assert(end >= 0)
		rest = rest[start + len(prefix) + end + 2:]
	}
	strings.write_string(&out, rest)
	return strings.to_string(out)
}

json_response :: proc(req: ^server.Request, body: string) -> server.Response {
	return server.make_response(
		req,
		.OK,
		{{"Content-Type", "application/json"}, {"Cache-Control", "no-store"}},
		transmute([]u8)body,
	)
}

serve :: proc(data: rawptr, _: ^server.Connection, req: ^server.Request) -> server.Response {
	host := cast(^Origin)data
	if count := &host.calls[req.path]; count != nil {
		count^ += 1
	}
	switch req.path {
	case "/__bench/requests":
		encoded, err := json.marshal(host.calls, allocator = req.allocator)
		assert(err == nil)
		return json_response(req, string(encoded))
	case "/api/test-session":
		return json_response(req, `{"session":"operator","tenant":"demo"}`)
	case "/api/items/42":
		return json_response(req, `{"id":"42","title":"Lamp","revision":1}`)
	case "/items/42":
		if req.query == "hints=off" {
			return pages.serve_document(req, host.control)
		}
		return pages.serve_document(req, host.cache.build.documents["/items/:id"])
	}
	if asset, matched := pages.serve_build_asset(req, host.cache); matched {
		return asset
	}
	return server.not_found(req)
}

main :: proc() {
	assert(len(os.args) == 4, "Usage: origin UI_FIXTURES PORT_FILE negotiated|identity")
	assert(os.args[3] == "negotiated" || os.args[3] == "identity")
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)
	root := os.args[1]
	mounts, ok := modules.prepare_module_mounts(
		{{directory = root, prefix = "/ui/"}},
		false,
		allocator,
	)
	assert(ok)
	cache, ready := pages.prepare_pages(
		{
			templates = {
				pages = {
					{
						path = "/items/[id]",
						variants = {
							{
								language = "en",
								source_file = fmt.tprintf("%s/item.jsx", root),
								module_url = "/ui/item.js",
								recovery_label = "Reload",
							},
						},
					},
				},
			},
		},
		false,
		allocator,
		mounts,
	)
	assert(ready)
	host := Origin {
		cache   = cache,
		control = cache.build.documents["/items/:id"],
		calls   = make(map[string]int, allocator),
	}
	rep := host.control.variants["en"]
	plain := without_hints(string(rep.body), allocator)
	assert(len(plain) < len(rep.body))
	host.control.variants = make(map[string]assets.Prepared_Representation, allocator)
	host.control.variants["en"], _ = assets.prepare_encoded_representation(
		transmute([]u8)plain,
		rep.content_type,
		allocator,
	)
	// The same-coding experiment removes only the two precomputed HTML codings.
	// Both documents remain final prepared bytes, and JS still negotiates normally.
	if os.args[3] == "identity" {
		for variants in ([]map[string]assets.Prepared_Representation {
				host.control.variants,
				cache.build.documents["/items/:id"].variants,
			}) {
			v := &variants["en"]
			v.gzip, v.brotli = {}, {}
		}
	}
	for path in cache.build.files {host.calls[path] = 0}
	for path in ([]string {
			"/api/items/42",
			"/api/test-session",
			"/items/42",
		}) {host.calls[path] = 0}
	worker := thread.create_and_start_with_poly_data(&host, proc(s: ^Origin) {
			assert(
				server.serve(
					{
						address = "127.0.0.1",
						port = 0,
						workers = 1,
						handler = serve,
						handler_data = s,
						control = &s.server,
					},
				),
			)
		})
	assert(worker != nil)
	for !server.server_ready(&host.server) {time.sleep(time.Millisecond)}
	address, bound := server.server_endpoint(&host.server)
	assert(bound)
	pending := fmt.tprintf("%s.tmp", os.args[2])
	assert(
		os.write_entire_file(pending, fmt.tprintf("%d", address.port)) == nil &&
		os.rename(pending, os.args[2]) == nil,
	)
	thread.join(worker)
	thread.destroy(worker)
}
