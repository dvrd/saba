package saba_pages_test

import core "shared:saba/core"
import pages "shared:saba/pages"
import "core:fmt"
import "core:log"
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

@(test)
parameterized_page_routes :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "saba-routes-*", context.allocator)
	assert(err == nil)
	defer delete(dir)
	defer os.remove_all(dir)
	mount := page_fixture(dir)
	assert(os.make_directory(fmt.tprintf("%s/items", dir)) == nil)
	for name in ([]string{"[id]", "new"}) {
		assert(os.write_entire_file(fmt.tprintf("%s/items/%s.jsx", dir, name), "export default () => null;") == nil)
	}
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)
	for development in ([]bool{false, true}) {
		cache, ok := pages.prepare_pages(mount, development, allocator)
		if !testing.expect(t, ok) { return }
		request := core.Request{method = "GET", path = "/items/%E5%B1%B1", allocator = allocator}
		result, matched := pages.serve_prepared_pages(&request, cache, development)
		testing.expect(t, matched && strings.contains(string(result.body), `data-route="/items/:id"`))
		testing.expect_value(t, core.path_value(&request, "id"), "山")
		request.path = "/items/new"
		literal, exact := pages.serve_prepared_pages(&request, cache, development)
		testing.expect(t, exact && strings.contains(string(literal.body), `data-page="/m/items/new.js"`))
		testing.expect(t, !strings.contains(string(literal.body), "data-route="))
		for path in ([]string{"/items/", "/items/42/", "/items/a%2fb", "/items/a%5Cb", "/items/%ff", "/items/%GG"}) {
			request.path = path
			_, invalid := pages.serve_prepared_pages(&request, cache, development)
			testing.expectf(t, !invalid, "page accepted %s", path)
		}
	}
	assert(os.write_entire_file(fmt.tprintf("%s/items/[slug].jsx", dir), "export default () => null;") == nil)
	context.logger = log.nil_logger()
	_, ambiguous := pages.prepare_pages(mount, false, allocator)
	testing.expect(t, !ambiguous)
}

// Which page answers never depends on the order a directory lists its files.
@(test)
page_route_precedence_is_independent_of_listing_order :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "saba-precedence-*", context.allocator)
	assert(err == nil)
	defer delete(dir)
	defer os.remove_all(dir)
	mount := page_fixture(dir)
	page :: "export default () => null;"
	names := []string{"docs", "guide", "zeta", "alpha"}
	// A file and its directory index claim one route; the index wins.
	for name in names {
		assert(os.make_directory(fmt.tprintf("%s/%s", dir, name)) == nil)
		assert(os.write_entire_file(fmt.tprintf("%s/%s.jsx", dir, name), page) == nil)
		assert(os.write_entire_file(fmt.tprintf("%s/%s/index.jsx", dir, name), page) == nil)
	}
	// /shop/[item] and /[section]/cart both match /shop/cart: the earlier literal wins.
	assert(os.make_directory(fmt.tprintf("%s/shop", dir)) == nil)
	assert(os.make_directory(fmt.tprintf("%s/[section]", dir)) == nil)
	assert(os.write_entire_file(fmt.tprintf("%s/shop/[item].jsx", dir), page) == nil)
	assert(os.write_entire_file(fmt.tprintf("%s/[section]/cart.jsx", dir), page) == nil)
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)
	context.logger = log.nil_logger() // Each duplicate route is reported.

	for development in ([]bool{false, true}) {
		cache, ok := pages.prepare_pages(mount, development, allocator)
		if !testing.expect(t, ok) {
			return
		}
		request := core.Request {
			method    = "GET",
			allocator = allocator,
		}
		for name in names {
			request.path = fmt.tprintf("/%s", name)
			reply, found := pages.serve_prepared_pages(&request, cache, development)
			testing.expectf(
				t,
				found && strings.contains(string(reply.body), fmt.tprintf(`data-page="/m/%s/index.js"`, name)),
				"/%s is not its directory index (development %v)",
				name,
				development,
			)
		}
		request.path = "/shop/cart"
		reply, found := pages.serve_prepared_pages(&request, cache, development)
		testing.expect(t, found && strings.contains(string(reply.body), `data-route="/shop/:item"`))
		testing.expect_value(t, core.path_value(&request, "item"), "cart")
		request.path = "/home/cart"
		other, matched := pages.serve_prepared_pages(&request, cache, development)
		testing.expect(t, matched && strings.contains(string(other.body), `data-route="/:section/cart"`))
		testing.expect_value(t, core.path_value(&request, "section"), "home")
	}
}
