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
	prepared := prepare_representation(body, content_type)
	return prepared_representation_response(request, &prepared)
}

// Metadata is inline and allocation-free. Body and content_type remain borrowed and
// must stay immutable through every response send. Prepare once after loading a
// production representation; development must use representation_response(..., true).
Prepared_Representation :: struct {
	body: []u8,
	content_type: string,
	tag: [66]u8,
}

prepare_representation :: proc(body: []u8, content_type: string) -> Prepared_Representation {
	prepared := Prepared_Representation{body = body, content_type = content_type}
	digest: [32]u8
	hasher: sha2.Context_256
	sha2.init_256(&hasher)
	sha2.update(&hasher, body)
	sha2.final(&hasher, digest[:])
	prepared.tag[0] = '"'; prepared.tag[65] = '"'
	alphabet := "0123456789abcdef"
	for byte, index in digest {
		prepared.tag[1+index*2] = alphabet[byte>>4]
		prepared.tag[2+index*2] = alphabet[byte&15]
	}
	return prepared
}

prepared_representation_response :: proc(
	request: ^Request,
	representation: ^Prepared_Representation,
) -> Response {
	assert(representation != nil)
	tag, allocation_error := strings.clone(string(representation.tag[:]), request.allocator)
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
		{{"Content-Type", representation.content_type}, {"Cache-Control", "no-cache"},
		 {"ETag", tag}}, representation.body)
}
