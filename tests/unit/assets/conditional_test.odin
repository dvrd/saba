package saba_assets

import core "../core"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:testing"

@(test)
representation_validators_and_conditional_fields :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	request := Request {
		allocator = mem.dynamic_arena_allocator(&arena),
		method    = "GET",
	}

	body := transmute([]u8)string("abc")
	prepared := prepare_representation(body, "text/plain")
	initial := representation_response(&request, body, "text/plain")
	tag := initial.headers[2].value
	testing.expect_value(t, tag, `"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"`)
	testing.expect_value(t, initial.headers[1].value, "no-cache")

	for method in ([]string{"GET", "HEAD"}) {
		request.method = method

		for item in ([]struct {
				headers: []Header,
				status:  core.HTTP_Status,
			} {
				{nil, .OK},
				{{{"If-None-Match", tag}}, .Not_Modified},
				{{{"if-none-match", fmt.aprintf("W/%s", tag, allocator = request.allocator)}}, .Not_Modified},
				{{{"If-None-Match", `"other"`}, {"IF-NONE-MATCH", tag}}, .Not_Modified},
				{{{"If-None-Match", "*"}}, .Not_Modified},
				{{{"If-None-Match", "*"}, {"If-None-Match", tag}}, .OK},
				{{{"If-None-Match", tag}, {"If-None-Match", "invalid"}}, .OK},
			}) {
			request.headers = item.headers
			response := representation_response(&request, body, "text/plain")
			cached := prepared_representation_response(&request, &prepared)
			testing.expect_value(t, cached.status, response.status)
			testing.expect_value(t, string(cached.body), string(response.body))
			for field, index in response.headers {
				testing.expect_value(t, cached.headers[index].name, field.name)
				testing.expect_value(t, cached.headers[index].value, field.value)
			}
			testing.expect_value(t, response.status, item.status)
			// Looked up by name: a 200 now ends with X-Content-Type-Options.
			validator, _ := encoding_field(response, "ETag")
			testing.expect_value(t, validator, tag)
			if item.status == .Not_Modified {
				testing.expect_value(t, len(response.body), 0)
			} else {
				testing.expect_value(t, string(response.body), "abc")
			}
		}
	}

	request.headers = {{"If-None-Match", tag}}
	changed := representation_response(&request, transmute([]u8)string("abd"), "text/plain")
	testing.expect_value(t, changed.status, .OK)
	testing.expect(t, changed.headers[2].value != tag)
	dev := representation_response(&request, body, "text/plain", true)
	testing.expect_value(t, dev.status, .OK)
	testing.expect_value(t, dev.headers[1].value, "no-store")
	testing.expect_value(t, len(dev.headers), 3)
	testing.expect_value(t, dev.headers[2].value, "nosniff")
	empty := representation_response(&request, nil, "text/plain")
	testing.expect_value(
		t,
		empty.headers[2].value,
		`"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"`,
	)
}

@(test)
asset_get_head_and_conditional_snapshot_preserve_path_checks :: proc(t: ^testing.T) {
	directory := asset_test_directory()
	defer delete(directory)
	defer os.remove_all(directory)
	asset_test_write(directory, "ok.txt", "old")
	caches, error := prepare_assets_bounded({{directory, ""}}, {}, context.allocator)
	assert(error.kind == .None)
	defer destroy_assets(&caches, context.allocator)
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	request := Request {
		allocator = mem.dynamic_arena_allocator(&arena),
		method    = "GET",
		path      = "/assets/ok.txt",
	}

	get, matched := serve_assets(&request, caches)
	assert(matched)
	request.method = "HEAD"
	head, ok := serve_assets(&request, caches)
	testing.expect(t, ok)
	testing.expect_value(t, head.headers[2].value, get.headers[2].value)
	testing.expect_value(t, len(head.body), len(get.body))
	request.headers = {{"If-None-Match", get.headers[2].value}}
	unchanged, _ := serve_assets(&request, caches)
	testing.expect_value(t, unchanged.status, .Not_Modified)
	asset_test_write(directory, "ok.txt", "new bytes")
	production, _ := serve_assets(&request, caches)
	testing.expect_value(t, production.status, .Not_Modified)
	fresh, _ := serve_assets(&request, caches, true)
	testing.expect_value(t, fresh.status, .OK)
	testing.expect_value(t, string(fresh.body), "new bytes")
	testing.expect_value(t, fresh.headers[1].value, "no-store")

	for path in ([]string{"/assets/%2e%2e/ok.txt", "/assets/%2fetc/passwd", "/assets/private.jsx"}) {
		request.path = path
		response, found := serve_assets(&request, caches)
		testing.expect(t, found)
		testing.expect_value(t, response.status, .Not_Found)
	}
}

@(test)
prepared_metadata_is_inline_and_response_validator_is_owned :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	request := Request {
		allocator = mem.dynamic_arena_allocator(&arena),
		method    = "POST",
	}

	prepared := prepare_representation(transmute([]u8)string("abc"), "text/plain")
	request.headers = {{"If-None-Match", "*"}}
	response := prepared_representation_response(&request, &prepared)
	testing.expect_value(t, response.status, .OK)
	prepared.tag[1] = '0'
	testing.expect_value(
		t,
		response.headers[2].value,
		`"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"`,
	)
	prepared = prepare_representation(nil, "text/plain")
	request.method = "HEAD"
	request.headers = nil
	empty := prepared_representation_response(&request, &prepared)
	testing.expect_value(
		t,
		empty.headers[2].value,
		`"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"`,
	)
}
// A 304 carries the validator, policy and selectors of the 200 it stands for,
// but none of the content metadata of a body it does not send.
@(test)
not_modified_omits_content_metadata :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	request := Request {
		allocator = mem.dynamic_arena_allocator(&arena),
		method    = "GET",
	}
	prepared := prepare_representation(transmute([]u8)string("abc"), "text/plain")
	tag := string(prepared.tag[:])

	for method in ([]string{"GET", "HEAD"}) {
		request.method = method
		request.headers = {{"If-None-Match", tag}}
		unchanged := prepared_representation_response(&request, &prepared)
		testing.expect_value(t, unchanged.status, core.HTTP_Status.Not_Modified)
		validator, _ := encoding_field(unchanged, "ETag")
		testing.expect_value(t, validator, tag)
		policy, _ := encoding_field(unchanged, "Cache-Control")
		testing.expect_value(t, policy, "no-cache")
		for name in ([]string{"Content-Type", "Content-Encoding", "X-Content-Type-Options"}) {
			_, present := encoding_field(unchanged, name)
			testing.expectf(t, !present, "%s 304 carries %s", method, name)
		}
	}
}
