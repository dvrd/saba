package saba_assets

import http "../../http"
import "core:crypto/sha2"
import "core:strings"

// Static representations use explicit revalidation. Development always returns
// fresh bytes with no-store. Bodies remain borrowed until sending completes;
// core suppresses HEAD bytes while retaining their GET representation length.
representation_response :: proc(
	request: ^Request,
	body: []u8,
	content_type: string,
	development := false,
) -> Response {
	if development {
		return make_response(request, .OK,
			{{"Content-Type", content_type}, {"Cache-Control", "no-store"}}, body)
	}
	digest: [32]u8
	hasher: sha2.Context_256
	sha2.init_256(&hasher)
	sha2.update(&hasher, body)
	sha2.final(&hasher, digest[:])
	tag_buffer: [66]u8
	tag_buffer[0] = '"'; tag_buffer[65] = '"'
	alphabet := "0123456789abcdef"
	for byte, index in digest {
		tag_buffer[1+index*2] = alphabet[byte>>4]
		tag_buffer[2+index*2] = alphabet[byte&15]
	}
	tag, allocation_error := strings.clone(string(tag_buffer[:]), request.allocator)
	if allocation_error != nil do return Response{status = .Internal_Server_Error}
	matched, valid := false, true
	fields, stars := 0, 0
	for field in request.headers {
		if !strings.equal_fold(field.name, "If-None-Match") do continue
		fields += 1
		if strings.trim(field.value, " \t") == "*" do stars += 1
		found, ok := http.if_none_match(field.value, tag)
		matched = matched || found
		valid = valid && ok
	}
	if (request.method == "GET" || request.method == "HEAD") &&
	   valid && matched && (stars == 0 || fields == 1) {
		return make_response(request, .Not_Modified,
			{{"Cache-Control", "no-cache"}, {"ETag", tag}})
	}
	return make_response(request, .OK,
		{{"Content-Type", content_type}, {"Cache-Control", "no-cache"}, {"ETag", tag}}, body)
}
