package saba_application

import core "../core"
import pages "../pages"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
development_keeps_active_and_prior_compiled_generations :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "saba-edit-template-*", context.allocator)
	assert(err == nil)
	defer delete(dir)
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/index.jsx", dir)
	write :: proc(path, label: string) {
		source := fmt.tprintf(
			"export const title = '%s'; export default function Page() {{return <h1>%s</h1>}}",
			label,
			label,
		)
		assert(os.write_entire_file(path, source) == nil)
	}
	write(path, "Alpha")
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)
	state := State {
		config = {
			development = true,
			handler_routes = {"/api/"},
			modules = {{directory = dir, prefix = "/"}},
			pages = {
				templates = {
					pages = {
						{
							path = "/[id]",
							variants = {
								{
									language = "en",
									source_file = path,
									module_url = "/index.js",
									recovery_label = "Reload",
								},
							},
						},
					},
				},
			},
		},
	}
	defer {release_page_arena(state.page_arena)}
	if !testing.expect(t, prepare(&state, allocator)) {
		return
	}
	req := core.Request {
		method    = "GET",
		path      = "/api/users.js",
		allocator = allocator,
	}
	_, claimed := builtin_response(&state, &req)
	testing.expect(t, !claimed, "the root module mount captured an application endpoint")
	req.path = "/__saba/unknown"
	missing, reserved := builtin_response(&state, &req)
	testing.expect(t, reserved && missing.status == .Not_Found)
	req.path = "/first"
	a, _ := builtin_response(&state, &req)
	id_a := state.pages.build.id
	testing.expect(t, strings.contains(string(a.body), "Alpha"))
	write(path, "Beta")
	if !testing.expect(t, rebuild_pages(&state)) {
		return
	}
	b, _ := builtin_response(&state, &req)
	id_b := strings.clone(state.pages.build.id, allocator)
	testing.expect(t, strings.contains(string(b.body), "Beta") && id_b != id_a)
	req.path = fmt.tprintf("%s%s/__saba/entry-0-0.js", pages.BUILD_PATH, id_a)
	delayed, served := builtin_response(&state, &req)
	testing.expect(
		t,
		served && delayed.status == .OK && strings.contains(string(delayed.body), id_a),
	)
	assert(os.write_entire_file(path, "export default <") == nil)
	{
		context.logger = log.nil_logger()
		testing.expect(t, !rebuild_pages(&state), "published an incomplete generation")
	}
	testing.expect_value(t, state.pages.build.id, id_b)
	write(path, "Gamma")
	if !testing.expect(t, rebuild_pages(&state)) {
		return
	}
	// Beta's HTTP body has outlived the retired build arena.
	testing.expect(t, strings.contains(string(b.body), "Beta"))
	expired, _ := builtin_response(&state, &req)
	testing.expect_value(t, expired.status, core.HTTP_Status.Not_Found)
}
