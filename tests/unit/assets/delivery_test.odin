package saba_assets

import core "../core"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

delivery_test_field :: proc(response: Response, name: string) -> string {
	for header in response.headers {
		if strings.equal_fold(header.name, name) {
			return header.value
		}
	}
	return ""
}

// Every representation names its type and forbids sniffing.
@(test)
representations_forbid_content_sniffing :: proc(t: ^testing.T) {
	directory := asset_test_directory()
	defer delete(directory)
	defer os.remove_all(directory)
	asset_test_write(directory, "upload.bin", "<script>alert(1)</script>")
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)
	request := Request {
		method    = "GET",
		path      = "/assets/upload.bin",
		allocator = allocator,
	}
	caches, ok := prepare_assets({{directory, ""}}, allocator)
	if !testing.expect(t, ok) {
		return
	}
	for development in ([]bool{false, true}) {
		response, matched := serve_assets(&request, caches, development)
		testing.expect(t, matched && response.status == .OK)
		testing.expect_value(t, delivery_test_field(response, "Content-Type"), "application/octet-stream")
		testing.expect_value(t, delivery_test_field(response, "X-Content-Type-Options"), "nosniff")
	}
	stream := serve_file_stream(&request, directory, "upload.bin")
	testing.expect_value(t, stream.status, core.HTTP_Status.OK)
	testing.expect_value(t, delivery_test_field(stream, "X-Content-Type-Options"), "nosniff")
	if stream.stream.drop != nil {
		stream.stream.drop(stream.stream.data)
	}
	whole := serve_file(&request, fmt.tprintf("%s/upload.bin", directory), "application/octet-stream")
	testing.expect_value(t, whole.status, core.HTTP_Status.OK)
	testing.expect_value(t, delivery_test_field(whole, "X-Content-Type-Options"), "nosniff")
	testing.expect_value(t, string(whole.body), "<script>alert(1)</script>")
	// A conditional hit has no body to sniff and keeps its validator fields.
	request.headers = {{"If-None-Match", "*"}}
	unchanged, _ := serve_assets(&request, caches, false)
	testing.expect_value(t, unchanged.status, core.HTTP_Status.Not_Modified)
	testing.expect(t, delivery_test_field(unchanged, "ETag") != "")
}

// A component source stays private however its extension is spelled.
@(test)
component_sources_are_private_in_any_case :: proc(t: ^testing.T) {
	directory := asset_test_directory()
	defer delete(directory)
	defer os.remove_all(directory)
	asset_test_write(directory, "View.JSX", "export default () => <b>source</b>")
	asset_test_write(directory, "lower.jsx", "export default () => <i>source</i>")
	asset_test_write(directory, "plain.js", "export default 1")
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)
	caches, ok := prepare_assets({{directory, ""}}, allocator)
	if !testing.expect(t, ok) {
		return
	}
	testing.expect_value(t, len(caches[0].files), 1)
	request := Request {
		method    = "GET",
		allocator = allocator,
	}
	// On a case-insensitive volume the last two also name the files above.
	for name in ([]string{"View.JSX", "lower.jsx", "view.jsx", "LOWER.JSX", "lower.Jsx"}) {
		for development in ([]bool{false, true}) {
			request.path = fmt.tprintf("/assets/%s", name)
			response, matched := serve_assets(&request, caches, development)
			testing.expect(t, matched)
			testing.expectf(
				t,
				response.status == .Not_Found,
				"%s was served (development %v)",
				name,
				development,
			)
		}
		stream := serve_file_stream(&request, directory, name)
		testing.expectf(t, stream.status == .Not_Found, "%s was streamed", name)
		if stream.stream.drop != nil {
			stream.stream.drop(stream.stream.data)
		}
		_, valid := file_relative_decode(name, allocator)
		testing.expect(t, !valid)
	}
	testing.expect(t, jsx_source("a/b.JsX") && !jsx_source("a/b.js") && !jsx_source("jsx"))
}

// serve_file buffers one bounded regular file and nothing else.
@(test)
whole_file_responses_are_bounded :: proc(t: ^testing.T) {
	directory := asset_test_directory()
	defer delete(directory)
	defer os.remove_all(directory)
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	request := Request {
		method    = "GET",
		allocator = mem.dynamic_arena_allocator(&arena),
	}
	context.logger = log.nil_logger() // Each refusal is reported.
	// A directory used to be read as an empty 200 on some platforms.
	testing.expect_value(t, serve_file(&request, directory).status, core.HTTP_Status.Internal_Server_Error)
	large := fmt.tprintf("%s/large.bin", directory)
	file, open_error := os.open(large, {.Write, .Create})
	assert(open_error == nil)
	// Sparse: one byte past the limit without writing 64 MiB.
	_, seek_error := os.seek(file, FILE_BYTES_MAX, .Start)
	assert(seek_error == nil)
	_, write_error := os.write(file, []u8{1})
	assert(write_error == nil)
	os.close(file)
	testing.expect_value(t, serve_file(&request, large).status, core.HTTP_Status.Internal_Server_Error)
}

// Retained generations are compressed at a cheaper level than the active one.
@(test)
prepared_encoding_accepts_a_cheaper_level :: proc(t: ^testing.T) {
	body := transmute([]u8)strings.repeat("export const value = 'retained';\n", 400, context.allocator)
	defer delete(body)
	best, _ := prepare_encoded_representation(body, "text/javascript; charset=utf-8", context.allocator)
	defer destroy_encoded_representation(best, context.allocator)
	quick, retained := prepare_encoded_representation(
		body,
		"text/javascript; charset=utf-8",
		context.allocator,
		level = RETAINED_BROTLI_LEVEL,
	)
	defer destroy_encoded_representation(quick, context.allocator)
	testing.expect(t, RETAINED_BROTLI_LEVEL < core.BROTLI_PREPARED_LEVEL)
	testing.expect(t, len(quick.brotli.body) > 0 && len(quick.brotli.body) < len(body))
	testing.expect(t, len(quick.gzip.body) > 0 && retained > 0)
	// Same bytes, same validator: the level changes cost, never identity.
	testing.expect_value(t, string(quick.tag[:]), string(best.tag[:]))
}

// A mount names a file's type by its extension, however the extension is spelled.
@(test)
content_types_follow_the_extension_in_any_case :: proc(t: ^testing.T) {
	for item in ([][2]string {
			{"app.js", "text/javascript; charset=utf-8"},
			{"APP.JS", "text/javascript; charset=utf-8"},
			{"entry.Mjs", "text/javascript; charset=utf-8"},
			{"theme.CSS", "text/css; charset=utf-8"},
			{"Logo.PNG", "image/png"},
			{"photo.JPeG", "image/jpeg"},
			{"icon.SVG", "image/svg+xml"},
			{"module.WASM", "application/wasm"},
			{"site.webmanifest", "application/manifest+json"},
			{"README", "application/octet-stream"},
			{"archive.tar", "application/octet-stream"},
		}) {
		testing.expectf(t, asset_content_type(item[0]) == item[1], "%s is %s", item[0], asset_content_type(item[0]))
	}
}
