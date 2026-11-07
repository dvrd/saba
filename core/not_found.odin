package saba_core

not_found :: proc(request: ^Request) -> Response {
	return make_response(
		request,
		.Not_Found,
		[]Header{{"Content-Type", "text/html; charset=utf-8"}},
		transmute([]u8)string("Not Found"),
	)
}
