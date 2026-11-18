package saba_assets

import "core:bytes"
import "core:compress/brotli"
import "core:compress/gzip"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

encoding_text :: proc(count: int, allocator: mem.Allocator) -> []u8 {
	phrase := "Saba serves each prepared asset from the representation that fits the client. "
	data, error := make([]u8, count, allocator)
	assert(error == nil)

	for index in 0 ..< count {
		data[index] = phrase[index % len(phrase)]
	}

	return data
}

encoding_field :: proc(response: Response, name: string) -> (string, bool) {
	for header in response.headers {
		if strings.equal_fold(header.name, name) {
			return header.value, true
		}
	}

	return "", false
}

encoding_decode_brotli :: proc(t: ^testing.T, packed, expected: []u8) {
	output: [dynamic]u8
	defer delete(output)
	testing.expect_value(t, brotli.decompress(&output, packed, expected_output_size = len(expected)), nil)
	testing.expect(t, string(output[:]) == string(expected))
}

encoding_decode_gzip :: proc(t: ^testing.T, packed, expected: []u8) {
	buffer: bytes.Buffer
	defer bytes.buffer_destroy(&buffer)
	testing.expect_value(t, gzip.load_from_bytes(packed, &buffer, len(packed), len(expected)), nil)
	testing.expect(t, bytes.buffer_to_string(&buffer) == string(expected))
}

@(test)
prepared_representation_stores_smaller_variants_with_their_own_tags :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)
	plain := encoding_text(16384, allocator)
	prepared, retained := prepare_encoded_representation(plain, "text/html; charset=utf-8", allocator)
	identity := string(prepared.tag[:])

	testing.expect(t, prepared.prepared)
	testing.expect(t, len(prepared.brotli.body) > 0 && len(prepared.brotli.body) < len(plain))
	testing.expect(t, len(prepared.gzip.body) > 0 && len(prepared.gzip.body) < len(plain))
	testing.expect_value(t, retained, len(prepared.brotli.body) + len(prepared.gzip.body))
	// Brotli level 11 beats the fast gzip stream on text.
	testing.expect(t, len(prepared.brotli.body) <= len(prepared.gzip.body))
	encoding_decode_brotli(t, prepared.brotli.body, plain)
	encoding_decode_gzip(t, prepared.gzip.body, plain)
	testing.expect_value(t, string(prepared.brotli.tag[:prepared.brotli.tag_len]), fmt.tprintf("%s-br\"", identity[:65]))
	testing.expect_value(t, string(prepared.gzip.tag[:prepared.gzip.tag_len]), fmt.tprintf("%s-gzip\"", identity[:65]))
	testing.expect_value(t, prepared.tag, prepare_representation(plain, "text/html").tag)

	// Too small, not compressible, or incompressible bytes keep identity only.
	tiny, _ := prepare_encoded_representation(plain[:512], "text/html", allocator)
	testing.expect(t, tiny.prepared && tiny.brotli.body == nil && tiny.gzip.body == nil)
	image, _ := prepare_encoded_representation(plain, "image/png", allocator)
	testing.expect(t, image.brotli.body == nil && image.gzip.body == nil)
	noise := make([]u8, 4096, allocator)
	state := u32(88172645)

	for &value in noise {
		state ~= state << 13
		state ~= state >> 17
		state ~= state << 5
		value = u8(state)
	}

	random, random_retained := prepare_encoded_representation(noise, "text/plain", allocator)
	testing.expect(t, random.brotli.body == nil && random.gzip.body == nil)
	testing.expect_value(t, random_retained, 0)

	// The byte budget bounds what is retained: too small for either variant.
	limited, limited_retained := prepare_encoded_representation(plain, "text/html", allocator, 8)
	testing.expect(t, limited.brotli.body == nil && limited.gzip.body == nil)
	testing.expect_value(t, limited_retained, 0)
}

@(test)
prepared_representation_negotiates_per_request_and_keeps_tags_per_variant :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)
	plain := encoding_text(16384, allocator)
	prepared, _ := prepare_encoded_representation(plain, "text/html; charset=utf-8", allocator)
	identity_tag := string(prepared.tag[:])
	brotli_tag := string(prepared.brotli.tag[:prepared.brotli.tag_len])
	gzip_tag := string(prepared.gzip.tag[:prepared.gzip.tag_len])

	for item in ([]struct {
			accept:   string,
			coding:   string,
			tag:      string,
			body:     []u8,
		} {
			{"br", "br", brotli_tag, prepared.brotli.body},
			{"gzip, br", "br", brotli_tag, prepared.brotli.body},
			{"gzip", "gzip", gzip_tag, prepared.gzip.body},
			{"br;q=0.2, gzip;q=0.9", "gzip", gzip_tag, prepared.gzip.body},
			{"deflate", "", identity_tag, plain},
			{"br;q=0, gzip;q=0", "", identity_tag, plain},
			{"", "", identity_tag, plain},
		}) {
		request := Request {
			allocator = allocator,
			method    = "GET",
			headers   = {{"Accept-Encoding", item.accept}} if item.accept != "" else nil,
		}

		response := prepared_representation_response(&request, &prepared)
		testing.expect_value(t, response.status, .OK)
		testing.expect(t, response.uncoded)
		coding, encoded := encoding_field(response, "Content-Encoding")
		testing.expect_value(t, encoded, item.coding != "")
		testing.expect_value(t, coding, item.coding)
		tag, _ := encoding_field(response, "ETag")
		testing.expect_value(t, tag, item.tag)
		vary, varied := encoding_field(response, "Vary")
		testing.expect(t, varied && vary == "Accept-Encoding")
		testing.expect(t, raw_data(response.body) == raw_data(item.body) && len(response.body) == len(item.body))
		content_type, _ := encoding_field(response, "Content-Type")
		testing.expect_value(t, content_type, "text/html; charset=utf-8")
	}

	// Conditional requests compare against the selected representation only.
	request := Request {
		allocator = allocator,
		method    = "GET",
		headers   = {{"Accept-Encoding", "br"}, {"If-None-Match", brotli_tag}},
	}

	unchanged := prepared_representation_response(&request, &prepared)
	testing.expect_value(t, unchanged.status, .Not_Modified)
	testing.expect_value(t, len(unchanged.body), 0)
	tag, _ := encoding_field(unchanged, "ETag")
	vary, varied := encoding_field(unchanged, "Vary")
	testing.expect_value(t, tag, brotli_tag)
	testing.expect(t, varied && vary == "Accept-Encoding")
	_, encoded := encoding_field(unchanged, "Content-Encoding")
	testing.expect(t, !encoded)

	request.headers = {{"Accept-Encoding", "br"}, {"If-None-Match", identity_tag}}
	other := prepared_representation_response(&request, &prepared)
	testing.expect_value(t, other.status, .OK)
	request.headers = {{"Accept-Encoding", "gzip"}, {"If-None-Match", brotli_tag}}
	crossed := prepared_representation_response(&request, &prepared)
	testing.expect_value(t, crossed.status, .OK)
	request.method = "HEAD"
	request.headers = {{"Accept-Encoding", "br"}}
	head := prepared_representation_response(&request, &prepared)
	tag, _ = encoding_field(head, "ETag")
	testing.expect_value(t, tag, brotli_tag)

	// Without variants the response is unchanged: three headers, no Vary.
	plain_only := prepare_representation(plain[:64], "text/plain")
	request.method = "GET"
	request.headers = {{"Accept-Encoding", "br, gzip"}}
	identity := prepared_representation_response(&request, &plain_only)
	testing.expect_value(t, len(identity.headers), 3)
	testing.expect(t, !identity.uncoded)
	_, varied = encoding_field(identity, "Vary")
	testing.expect(t, !varied)
}

@(test)
asset_mounts_precompress_text_once_and_release_the_variants :: proc(t: ^testing.T) {
	directory := asset_test_directory()
	defer delete(directory)
	defer os.remove_all(directory)
	text := encoding_text(20000, context.allocator)
	defer delete(text)
	asset_test_write(directory, "app.js", string(text))
	asset_test_write(directory, "small.js", "x = 1;")
	asset_test_write(directory, "logo.png", string(text))
	caches, error := prepare_assets_bounded({{directory, ""}}, {}, context.allocator)
	testing.expect_value(t, error.kind, Asset_Error_Kind.None)
	defer destroy_assets(&caches, context.allocator)
	script := caches[0].files["app.js"]
	testing.expect(t, script.prepared && script.brotli.body != nil && script.gzip.body != nil)
	testing.expect(t, caches[0].files["small.js"].brotli.body == nil)
	testing.expect(t, caches[0].files["logo.png"].brotli.body == nil)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	request := Request {
		allocator = mem.dynamic_arena_allocator(&arena),
		method    = "GET",
		path      = "/assets/app.js",
		headers   = {{"Accept-Encoding", "br"}},
	}

	response, matched := serve_assets(&request, caches)
	testing.expect(t, matched)
	coding, _ := encoding_field(response, "Content-Encoding")
	testing.expect_value(t, coding, "br")
	encoding_decode_brotli(t, response.body, text)
	again, _ := serve_assets(&request, caches)
	testing.expect(t, raw_data(response.body) == raw_data(again.body))

	// The total byte limit also bounds the retained variants: they are skipped,
	// never an error, once the identity bytes use up the allowance.
	tight, limited := prepare_assets_bounded({{directory, ""}}, {max_total_bytes = 2 * len(text) + 16}, context.allocator)
	testing.expect_value(t, limited.kind, Asset_Error_Kind.None)
	defer destroy_assets(&tight, context.allocator)
	testing.expect(t, tight[0].files["app.js"].prepared)
	testing.expect(t, tight[0].files["app.js"].brotli.body == nil && tight[0].files["app.js"].gzip.body == nil)
}
