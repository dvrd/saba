package saba_modules

import core "../core"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

// A component's JSX source never leaves the mount, whatever its address. It is
// compiled and addressed as .js; the .jsx URL itself is refused.
@(test)
module_routes_refuse_component_sources :: proc(t: ^testing.T) {
	directory, made := os.make_directory_temp("", "saba-module-routes-*", context.allocator)
	assert(made == nil)
	defer delete(directory)
	defer os.remove_all(directory)
	assert(os.write_entire_file(fmt.tprintf("%s/widget.jsx", directory), MAP_WIDGET) == nil)
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)

	for development in ([]bool{false, true}) {
		request := Request {
			method    = "GET",
			path      = "/js/widget.jsx",
			allocator = allocator,
		}
		response, matched := serve_modules(&request, directory, "/js/", development)
		testing.expectf(t, matched, "the module route left %s to others (development %v)", request.path, development)
		testing.expectf(
			t,
			response.status == .Not_Found,
			"%s answered %v (development %v)",
			request.path,
			response.status,
			development,
		)
		testing.expect(t, !strings.contains(string(response.body), "<b>{label}</b>"))
	}
	mounts, prepared := prepare_module_mounts({{directory = directory, prefix = "/js/"}}, false, allocator)
	if !testing.expect(t, prepared) {
		return
	}
	request := Request {
		method    = "GET",
		path      = "/js/widget.jsx",
		allocator = allocator,
	}
	response, matched := serve_prepared_modules(&request, mounts, false)
	testing.expect(t, matched && response.status == .Not_Found)
}

// A link inside a module directory cannot reach a file outside it.
@(test)
module_routes_stay_inside_their_directory :: proc(t: ^testing.T) {
	work, made := os.make_directory_temp("", "saba-module-escape-*", context.allocator)
	assert(made == nil)
	defer delete(work)
	defer os.remove_all(work)
	root := fmt.tprintf("%s/root", work)
	assert(os.make_directory(root) == nil)
	assert(os.write_entire_file(fmt.tprintf("%s/secret.js", work), "export const secret = 'outside'") == nil)
	assert(os.write_entire_file(fmt.tprintf("%s/inside.js", root), "export const inside = 1") == nil)
	assert(os.symlink(fmt.tprintf("%s/secret.js", work), fmt.tprintf("%s/escape.js", root)) == nil)
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)

	for development in ([]bool{false, true}) {
		request := Request {
			method    = "GET",
			path      = "/js/inside.js",
			allocator = allocator,
		}
		inside, _ := serve_modules(&request, root, "/js/", development)
		testing.expect_value(t, inside.status, core.HTTP_Status.OK)
		request.path = "/js/escape.js"
		escape, matched := serve_modules(&request, root, "/js/", development)
		testing.expect(t, matched)
		testing.expectf(t, escape.status == .Not_Found, "a link escaped the mount (development %v)", development)
		testing.expect(t, !strings.contains(string(escape.body), "outside"))
	}
}
