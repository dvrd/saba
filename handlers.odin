package server

import "core:log"
import "core:os"

serve_file :: proc(
	request: ^Request,
	path: string,
	content_type := "text/html; charset=utf-8",
) -> Response {
	body, file_err := os.read_entire_file(path, request.allocator)

	if file_err != nil {
		log.error("Could not read file:", path, "| error:", file_err)
		return Response{status = .Internal_Server_Error}
	}

	return make_response(request, .OK, []Header{{"Content-Type", content_type}}, body)
}

not_found :: proc(request: ^Request) -> Response {
	return make_response(
		request,
		.Not_Found,
		[]Header{{"Content-Type", "text/html; charset=utf-8"}},
		transmute([]u8)string("Not Found"),
	)
}
