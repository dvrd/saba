package saba_pages_test

import core "../../core"
import pages "../../pages"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

page_fixture :: proc(directory: string) -> pages.Page_Mount {
	assert(os.write_entire_file(fmt.tprintf("%s/index.jsx", directory), "export default () => null;") == nil)
	assert(os.write_entire_file(fmt.tprintf("%s/about.jsx", directory), "export default () => null;") == nil)
	shell := fmt.tprintf("%s/shell.html", directory)
	assert(os.write_entire_file(shell, "<html><body><main><!--saba:page--></main></body></html>") == nil)

	return {directory = directory, shell = shell, module_prefix = "/m/"}
}

@(test)
production_pages_are_rendered_once_at_prepare :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "saba-pages-*", context.allocator)
	assert(directory_error == nil)
	defer delete(directory)
	defer os.remove_all(directory)
	mount := page_fixture(directory)

	prepare_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&prepare_arena)
	defer mem.dynamic_arena_destroy(&prepare_arena)
	cache, ok := pages.prepare_pages(mount, false, mem.dynamic_arena_allocator(&prepare_arena))
	testing.expect(t, ok)
	testing.expect_value(t, len(cache.routes), 2)

	request_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&request_arena)
	defer mem.dynamic_arena_destroy(&request_arena)
	request := core.Request {
		allocator = mem.dynamic_arena_allocator(&request_arena),
		method    = "GET",
		path      = "/about",
	}

	first, matched := pages.serve_prepared_pages(&request, cache, false)
	testing.expect(t, matched)
	testing.expect_value(t, first.status, core.HTTP_Status.OK)
	html := string(first.body)
	testing.expect(t, strings.contains(html, `data-page="/m/about.js"`))
	testing.expect(t, strings.contains(html, "<main><script"))

	// The same prepared bytes are served again: nothing is rebuilt per request.
	second, again := pages.serve_prepared_pages(&request, cache, false)
	testing.expect(t, again)
	testing.expect(t, raw_data(first.body) == raw_data(second.body))
	third, _ := pages.serve_prepared_pages(&request, cache, false)
	testing.expect(t, raw_data(first.body) == raw_data(third.body))

	request.path = "/missing"
	_, missing := pages.serve_prepared_pages(&request, cache, false)
	testing.expect(t, !missing)
}

@(test)
development_pages_follow_file_changes :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "saba-pages-*", context.allocator)
	assert(directory_error == nil)
	defer delete(directory)
	defer os.remove_all(directory)
	mount := page_fixture(directory)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	cache, ok := pages.prepare_pages(mount, true, mem.dynamic_arena_allocator(&arena))
	testing.expect(t, ok)
	testing.expect_value(t, len(cache.routes), 0)

	request := core.Request {
		allocator = mem.dynamic_arena_allocator(&arena),
		method    = "GET",
		path      = "/extra",
	}

	_, missing := pages.serve_prepared_pages(&request, cache, true)
	testing.expect(t, !missing)
	assert(os.write_entire_file(fmt.tprintf("%s/extra.jsx", directory), "export default () => null;") == nil)
	response, found := pages.serve_prepared_pages(&request, cache, true)
	testing.expect(t, found)
	testing.expect(t, strings.contains(string(response.body), `data-page="/m/extra.js"`))
}
