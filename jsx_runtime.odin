package server

JSX_RUNTIME_URL :: "/__saba/dom.js"
JSX_RUNTIME :: #load("javascript/dom.js", string)

@(private)
jsx_runtime_response :: proc(request: ^Request) -> Response {
	return make_response(
		request,
		.OK,
		{{"Content-Type", "text/javascript; charset=utf-8"}, {"Cache-Control", "no-cache"}},
		transmute([]u8)JSX_RUNTIME,
	)
}

PAGE_ENTRY_URL :: "/__saba/page-entry.js"
PAGE_ENTRY :: #load("javascript/page-entry.js", string)

@(private)
page_entry_response :: proc(request: ^Request) -> Response {
	return make_response(
		request,
		.OK,
		{{"Content-Type", "text/javascript; charset=utf-8"}, {"Cache-Control", "no-cache"}},
		transmute([]u8)PAGE_ENTRY,
	)
}
