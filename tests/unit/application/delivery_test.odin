package saba_application

import core "../core"
import modules_api "../modules"
import pages "../pages"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

delivery_test_field :: proc(response: core.Response, name: string) -> string {
	for header in response.headers {
		if strings.equal_fold(header.name, name) {
			return header.value
		}
	}
	return ""
}

// A reservation owns its path however the client spells it.
@(test)
handler_reservations_cover_encoded_paths :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "saba-reserved-*", context.allocator)
	assert(err == nil)
	defer delete(dir)
	defer os.remove_all(dir)
	write :: proc(path, text: string) {
		assert(os.write_entire_file(path, text) == nil)
	}
	for sub in ([]string{"pages", "files", "files/private", "js", "js/internal"}) {
		assert(os.make_directory(fmt.tprintf("%s/%s", dir, sub)) == nil)
	}
	write(fmt.tprintf("%s/pages/admin.jsx", dir), "export default () => null;")
	write(fmt.tprintf("%s/pages/open.jsx", dir), "export default () => null;")
	write(fmt.tprintf("%s/shell.html", dir), "<html><head></head><body><!--saba:page--></body></html>")
	write(fmt.tprintf("%s/files/private/report.txt", dir), "members only")
	write(fmt.tprintf("%s/files/public.txt", dir), "everyone")
	write(fmt.tprintf("%s/js/internal/keys.js", dir), "export const key = 1")
	write(fmt.tprintf("%s/js/app.js", dir), "export const app = 1")
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)
	state := State {
		config = {
			handler_routes = {"/admin", "/files/private/", "/js/internal/"},
			assets = {{directory = fmt.tprintf("%s/files", dir), prefix = "/files/"}},
			modules = {{directory = fmt.tprintf("%s/js", dir), prefix = "/js/"}},
			pages = {
				directory = fmt.tprintf("%s/pages", dir),
				shell = fmt.tprintf("%s/shell.html", dir),
				module_prefix = "/p/",
			},
		},
	}
	defer {release_page_arena(state.page_arena)}
	if !testing.expect(t, prepare(&state, allocator)) {
		return
	}
	request := core.Request {
		method    = "GET",
		allocator = allocator,
	}
	for path in ([]string {
			"/admin",
			"/%61dmin",
			"/a%64min",
			"/files/private/report.txt",
			"/files/%70rivate/report.txt",
			"/files/private%2Freport.txt",
			"/js/internal/keys.js",
			"/js/%69nternal/keys.js",
			"/js/internal%2fkeys.js",
		}) {
		request.path = path
		response, claimed := builtin_response(&state, &request)
		testing.expectf(
			t,
			!claimed,
			"%s bypassed its reservation and was answered by a mount with %v",
			path,
			response.status,
		)
	}
	// Unreserved neighbours are still served, encoded or not.
	for item in ([]struct {
			path, body: string,
		} {
			{"/files/public.txt", "everyone"},
			{"/files/%70ublic.txt", "everyone"},
			{"/js/app.js", "export const app = 1"},
			{"/js/%61pp.js", "export const app = 1"},
			{"/open", "data-page"},
			{"/%6Fpen", "data-page"},
		}) {
		request.path = item.path
		response, claimed := builtin_response(&state, &request)
		testing.expectf(t, claimed && response.status == .OK, "%s was not served", item.path)
		testing.expect(t, strings.contains(string(response.body), item.body))
		testing.expect_value(t, delivery_test_field(response, "X-Content-Type-Options"), "nosniff")
	}
	// A path that only decodes twice was never the reserved one.
	request.path = "/%2561dmin"
	_, twice := builtin_response(&state, &request)
	testing.expect(t, !twice)
	testing.expect(t, handler_route_reserved({"/admin"}, &request) == false)
}

// Framework modules are hashed and compressed once, not on every request.
@(test)
framework_modules_are_prepared_once :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	state: State
	request := core.Request {
		method    = "GET",
		allocator = mem.dynamic_arena_allocator(&arena),
	}
	for module in modules_api.BUILTIN_MODULES {
		request.path = module.url
		request.headers = {{"Accept-Encoding", "br"}}
		first, matched := builtin_response(&state, &request)
		if !testing.expectf(t, matched && first.status == .OK, "%s was not served", module.url) {
			return
		}
		second, _ := builtin_response(&state, &request)
		// The very same stored bytes, already final for the transport.
		testing.expect_value(t, raw_data(second.body), raw_data(first.body))
		testing.expect(t, first.uncoded, "the transport would encode this response again")
		testing.expect_value(t, delivery_test_field(first, "X-Content-Type-Options"), "nosniff")
		testing.expect_value(t, delivery_test_field(first, "Cache-Control"), "no-cache")
		if len(module.source) >= core.GZIP_MIN_BYTES {
			testing.expect_value(t, delivery_test_field(first, "Content-Encoding"), "br")
			testing.expect(t, len(first.body) < len(module.source))
			testing.expect_value(t, delivery_test_field(first, "Vary"), "Accept-Encoding")
		}
		request.headers = nil
		identity, _ := builtin_response(&state, &request)
		testing.expect_value(t, raw_data(identity.body), raw_data(module.source))
		prepared, found := modules_api.builtin_module(module.url)
		testing.expect(t, found && delivery_test_field(identity, "ETag") == string(prepared.tag[:]))
	}
	_, unknown := modules_api.builtin_module("/__saba/template-entry.js")
	testing.expect(t, !unknown)
}

// Saba answers GET and HEAD under /__saba/; every other method is the application's.
@(test)
reserved_namespace_treats_methods_alike :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	state: State
	request := core.Request {
		allocator = mem.dynamic_arena_allocator(&arena),
	}
	paths := []string {
		modules_api.JSX_RUNTIME_URL,
		"/__saba/unknown",
		"/__saba",
		fmt.tprintf("%s0123456789abcdef/ui/page.js", pages.BUILD_PATH),
	}
	for path in paths {
		request.path = path
		for method in ([]string{"GET", "HEAD"}) {
			request.method = method
			_, owned := builtin_response(&state, &request)
			testing.expectf(t, owned, "%s %s reached the application", method, path)
		}
		for method in ([]string{"POST", "PUT", "DELETE", "OPTIONS"}) {
			request.method = method
			response, owned := builtin_response(&state, &request)
			testing.expectf(t, !owned, "%s %s was answered with %v", method, path, response.status)
		}
	}
}

// A reservation of "/" is the root alone, not every path below it.
@(test)
a_root_reservation_leaves_other_paths_to_saba :: proc(t: ^testing.T) {
	request := core.Request {
		method    = "GET",
		path      = "/",
		allocator = context.temp_allocator,
	}
	testing.expect(t, handler_route_reserved([]string{"/"}, &request))
	request.path = "/js/app.js"
	testing.expect(t, !handler_route_reserved([]string{"/"}, &request))
	testing.expect(t, handler_route_reserved([]string{"/js/"}, &request))
}

// A compile diagnostic names the module, not where the project lives on disk.
@(test)
development_diagnostics_keep_filesystem_paths_private :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "saba-diagnostic-*", context.allocator)
	assert(err == nil)
	defer delete(dir)
	defer os.remove_all(dir)
	assert(os.make_directory(fmt.tprintf("%s/parts", dir)) == nil)
	source := fmt.tprintf("%s/parts/view.jsx", dir)
	assert(os.write_entire_file(source, "const x = <b></p>;") == nil)
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	request := core.Request {
		method    = "GET",
		path      = "/js/parts/view.js",
		allocator = mem.dynamic_arena_allocator(&arena),
	}
	context.logger = log.nil_logger() // The full path belongs in the log.
	response, matched := modules_api.serve_modules(&request, dir, "/js/", true)
	testing.expect(t, matched)
	testing.expect_value(t, response.status, core.HTTP_Status.Internal_Server_Error)
	body := string(response.body)
	testing.expect(t, strings.has_prefix(body, "parts/view.jsx:1:"), body)
	testing.expectf(t, !strings.contains(body, dir), "the diagnostic exposes %s", dir)
	direct := modules_api.serve_jsx(&request, source)
	testing.expect(t, strings.has_prefix(string(direct.body), "view.jsx:1:"), string(direct.body))
	testing.expect(t, !strings.contains(string(direct.body), dir))
}
