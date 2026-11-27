package saba_modules

import core "../core"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

Map_Fixture :: struct {
	version:        int,
	file:           string,
	sources:        []string,
	sourcesContent: []string,
	mappings:       string,
}

MAP_WIDGET :: "const label = 'one';\nexport const view = <b>{label}</b>;\nexport const after = 2;\n"

map_request :: proc(path: string, allocator: mem.Allocator) -> Request {
	return Request{method = "GET", path = path, allocator = allocator}
}

@(test)
development_modules_carry_a_relative_source_map :: proc(t: ^testing.T) {
	directory, made := os.make_directory_temp("", "saba-maps-*", context.allocator)
	assert(made == nil)
	defer delete(directory)
	defer os.remove_all(directory)
	assert(os.make_directory(fmt.tprintf("%s/parts", directory)) == nil)
	assert(os.write_entire_file(fmt.tprintf("%s/parts/widget.jsx", directory), MAP_WIDGET) == nil)
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)

	request := map_request("/js/parts/widget.js", allocator)
	module, matched := serve_modules(&request, directory, "/js/", true)
	testing.expect(t, matched)
	testing.expect_value(t, module.status, core.HTTP_Status.OK)
	testing.expectf(
		t,
		strings.has_suffix(string(module.body), "\n//# sourceMappingURL=widget.js.map\n"),
		"the module does not name its map: %q",
		string(module.body),
	)

	request = map_request("/js/parts/widget.js.map", allocator)
	response, map_matched := serve_modules(&request, directory, "/js/", true)
	testing.expect(t, map_matched)
	if !testing.expect_value(t, response.status, core.HTTP_Status.OK) {
		return
	}
	body := string(response.body)
	testing.expectf(t, !strings.contains(body, directory), "the map exposes %s", directory)
	document: Map_Fixture
	if !testing.expect(t, json.unmarshal(response.body, &document, allocator = allocator) == nil) {
		return
	}
	testing.expect_value(t, document.version, 3)
	testing.expect_value(t, document.file, "widget.js")
	testing.expect_value(t, len(document.sources), 1)
	if len(document.sources) == 1 {
		testing.expect_value(t, document.sources[0], "widget.jsx")
	}
	testing.expect_value(t, len(document.sourcesContent), 1)
	if len(document.sourcesContent) == 1 {
		testing.expect_value(t, document.sourcesContent[0], MAP_WIDGET)
	}
	// The helper import added on the first line has no origin; each authored
	// line then maps to its own line, starting at line 0, column 0.
	testing.expect(t, strings.has_prefix(document.mappings, ";AAAA;AACA"), document.mappings)
	for header in response.headers {
		if strings.equal_fold(header.name, "content-type") {
			testing.expect(t, strings.has_prefix(header.value, "application/json"), header.value)
		}
	}

	// An excluded module keeps its map private too.
	exclude := []string{"parts/widget.jsx"}
	request = map_request("/js/parts/widget.js.map", allocator)
	excluded, excluded_matched := serve_modules(&request, directory, "/js/", true, exclude)
	testing.expect(t, excluded_matched)
	testing.expect_value(t, excluded.status, core.HTTP_Status.Not_Found)
}

@(test)
production_modules_carry_no_source_map :: proc(t: ^testing.T) {
	directory, made := os.make_directory_temp("", "saba-maps-*", context.allocator)
	assert(made == nil)
	defer delete(directory)
	defer os.remove_all(directory)
	assert(os.write_entire_file(fmt.tprintf("%s/widget.jsx", directory), MAP_WIDGET) == nil)
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)

	mounts, prepared := prepare_module_mounts({{directory = directory, prefix = "/js/"}}, false, allocator)
	if !testing.expect(t, prepared) {
		return
	}
	compiled, found := mounts[0].files["widget.js"]
	testing.expect(t, found)
	testing.expect(t, !strings.contains(string(compiled.body), "sourceMappingURL"), string(compiled.body))
	testing.expect(t, "widget.js.map" not_in mounts[0].files)

	request := map_request("/js/widget.js", allocator)
	module, matched := serve_prepared_modules(&request, mounts, false)
	testing.expect(t, matched)
	testing.expect(t, !strings.contains(string(module.body), "sourceMappingURL"))

	// The production module route does not claim map URLs.
	request = map_request("/js/widget.js.map", allocator)
	_, map_matched := serve_prepared_modules(&request, mounts, false)
	testing.expect(t, !map_matched)
	request = map_request("/js/widget.js.map", allocator)
	_, direct_matched := serve_modules(&request, directory, "/js/", false)
	testing.expect(t, !direct_matched)
}
