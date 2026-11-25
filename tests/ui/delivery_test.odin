package saba_ui_test

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import server "shared:saba/core"
import modules "shared:saba/modules"
import pages "shared:saba/pages"

Delivery_Probe :: struct {
	caches:   [4]pages.Page_Cache,
	index:    int,
	requests: map[string]int,
	control:  server.Server_Control,
	ok:       bool,
}

delivery_handler :: proc(
	data: rawptr,
	connection: ^server.Connection,
	r: ^server.Request,
) -> server.Response {
	s := cast(^Delivery_Probe)data
	switch r.path {
	case "/":
		source :: `<!doctype html><html><head><title>Delivery test</title></head><body><pre id="result">pending</pre><script type="module" src="/delivery.js"></script></body></html>`
		return server.make_response(
			r,
			.OK,
			{{"Content-Type", "text/html"}},
			transmute([]u8)string(source),
		)
	case "/delivery.js":
		source :: #load("../../testdata/ui_template/delivery.js", string)
		return server.make_response(
			r,
			.OK,
			{{"Content-Type", "text/javascript"}},
			transmute([]u8)string(source),
		)
	case "/publish":
		if r.method != "POST" || s.index == len(s.caches) - 1 {
			return server.not_found(r)
		}
		s.index += 1
		return {status = .No_Content}
	case "/requests":
		encoded, err := json.marshal(s.requests, allocator = r.allocator)
		if err != nil {
			return {status = .Internal_Server_Error}
		}
		return server.make_response(
			r,
			.OK,
			{{"Content-Type", "application/json"}, {"Cache-Control", "no-store"}},
			encoded,
		)
	}
	cache := s.caches[s.index]
	if asset, ok := pages.serve_build_asset(r, cache); ok {
		if count := &s.requests[r.path]; count != nil {
			count^ += 1
		}
		return asset
	}
	document_request := r^
	if s.index < 2 {
		document_request.headers = {{"Accept-Encoding", "identity"}}
	}
	if doc, matched := pages.serve_prepared_pages(&document_request, cache, false); matched {
		if s.index < 2 {
			// Delay the entry in A and B while leaving real module preloads enabled.
			// Recovery navigation reaches the unmodified active C or D document.
			held, _ := strings.replace_all(
				string(doc.body),
				`<script type="module"`,
				`<script type="text/plain"`,
				r.allocator,
			)
			return server.make_response(
				r,
				.OK,
				{{"Content-Type", "text/html"}, {"Cache-Control", "no-store"}},
				transmute([]u8)held,
			)
		}
		return doc
	}
	return server.not_found(r)
}

prepare_delivery :: proc(
	work: string,
	index: int,
	allocator: mem.Allocator,
) -> (
	pages.Page_Cache,
	bool,
) {
	context.allocator = allocator
	labels := [4]string{"A", "B", "C", "D"}
	label := labels[index]
	source :: `import {signal} from "/__saba/dom.js";
import {version} from "./version.js";
export default function Product() {
  const details = signal("Ready");
  async function loadDetails() {
    try {
      const module = await import("./details.js");
      details.set(await module.read());
    } catch (error) {
      if (document.querySelector("[data-saba-recover]").hidden) throw error;
    } finally { document.dispatchEvent(new Event("details-settled")); }
  }
  return <main><h1>Product RELEASE</h1><p id="version">{version}</p><output>{details()}</output><button onClick={loadDetails}>More</button></main>;
}`
	root := fmt.aprintf("%s/modules", work)
	page := fmt.aprintf("%s/product.jsx", root)
	jsx, _ := strings.replace_all(source, "RELEASE", label)
	for file in ([]struct {
			name, content: string,
		} {
			{"product.jsx", jsx},
			{"version.js", fmt.aprintf(`export const version = "%s";`, label)},
			{
				"details.js",
				`export async function read() { return (await import("./nested.js")).default; }`,
			},
			{"nested.js", fmt.aprintf(`export default "details %s";`, label)},
		}) {
		if os.write_entire_file(fmt.aprintf("%s/%s", root, file.name), file.content) != nil {
			return {}, false
		}
	}
	mods, ok := modules.prepare_module_mounts(
		{{directory = root, prefix = "/ui/"}},
		false,
		allocator,
	)
	if !ok {
		return {}, false
	}
	archive := fmt.aprintf("%s/builds", work) if index < 2 else ""
	variants := make([]pages.Template_Variant, 1, allocator)
	variants[0] = {
		language       = "en",
		source_file    = page,
		module_url     = "/ui/product.js",
		recovery_label = "Reload",
	}
	routes := make([]pages.Compiled_Page, 1, allocator)
	routes[0] = {
		path     = "/product",
		variants = variants,
	}
	return pages.prepare_pages(
		{templates = {archive_directory = archive, pages = routes}},
		false,
		allocator,
		mods,
	)
}

@(test)
retained_and_expired_modules_in_chromium :: proc(t: ^testing.T) {delivery_fixture(t, .Chromium)}

@(test)
retained_and_expired_modules_in_firefox :: proc(t: ^testing.T) {delivery_fixture(t, .Firefox)}

@(test)
retained_and_expired_modules_in_webkit :: proc(t: ^testing.T) {delivery_fixture(t, .WebKit)}

delivery_fixture :: proc(t: ^testing.T, engine: Engine) {
	testing.set_fail_timeout(t, engine_timeout(engine, 60 * time.Second))
	if !engine_enter(t, engine, "the module delivery fixture") {
		return
	}
	defer engine_leave(engine)
	work, error := os.make_directory_temp("", "saba-delivery-*", context.temp_allocator)
	if !testing.expect(t, error == nil) {
		return
	}
	defer os.remove_all(work)
	if !testing.expect(t, os.make_directory(fmt.tprintf("%s/modules", work)) == nil) {
		return
	}
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)
	s := Delivery_Probe {
		requests = make(map[string]int, allocator),
	}
	for &cache, i in s.caches {
		ok: bool
		cache, ok = prepare_delivery(work, i, allocator)
		if !testing.expectf(t, ok, "Could not build release %d", i) {
			return
		}
		for path in cache.build.files {s.requests[path] = 0}
	}
	worker := thread.create_and_start_with_poly_data(&s, proc(state: ^Delivery_Probe) {
		state.ok = server.serve(
			{
				address = "127.0.0.1",
				workers = 1,
				control = &state.control,
				handler = delivery_handler,
				handler_data = state,
			},
		)
	})
	if !testing.expect(t, worker != nil) {
		return
	}
	defer {
		server.stop_server(&s.control)
		thread.join(worker)
		thread.destroy(worker)
		testing.expect(t, s.ok)
	}
	until := time.tick_add(time.tick_now(), 8 * time.Second)
	for !server.server_ready(&s.control) &&
	    time.tick_since(until) < 0 {time.sleep(time.Millisecond)}
	ep, ready := server.server_endpoint(&s.control)
	if !testing.expect(t, ready) {
		return
	}
	dump_name := fmt.tprintf("%s/result.html", work)
	dump, err := os.create(dump_name)
	if !testing.expect(t, err == nil) {
		return
	}
	defer os.close(dump)
	url := fmt.tprintf("http://127.0.0.1:%d/", ep.port)
	command := []string {
		chromium_path(),
		"--headless",
		"--no-first-run",
		"--no-default-browser-check",
		"--disable-background-networking",
		"--disable-extensions",
		"--dump-dom",
		"--virtual-time-budget=12000",
		fmt.tprintf("--user-data-dir=%s/profile", work),
		url,
	}
	if engine != .Chromium {
		command = driver_command(engine, "dump", url, 60)
	}
	p, started := os.process_start({command = command, stdout = dump, stderr = os.stderr})
	if !testing.expectf(t, started == nil, "Could not start %s: %v", engine_name(engine), started) {
		return
	}
	result, waited := os.process_wait(p, engine_timeout(engine, 30 * time.Second))
	if waited != nil {
		_ = os.process_kill(p); _, _ = os.process_wait(p)
	}
	if !testing.expectf(
		t,
		waited == nil && result.success,
		"Delivery browser failed: %v, %v",
		waited,
		result,
	) {
		return
	}
	html, read := os.read_entire_file(dump_name, context.temp_allocator)
	testing.expectf(
		t,
		read == nil && strings.contains(string(html), `<pre id="result">PASS</pre>`),
		"Browser delivery result: %s",
		string(html),
	)
}
