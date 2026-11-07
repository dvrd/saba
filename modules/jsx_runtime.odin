package saba_modules

import jsx "../jsx"

JSX_RUNTIME_URL :: jsx.JSX_RUNTIME_URL
JSX_RUNTIME :: #load("dom.js", string)

jsx_runtime_response :: proc(request: ^Request) -> Response {
	return make_response(
		request,
		.OK,
		{{"Content-Type", "text/javascript; charset=utf-8"}, {"Cache-Control", "no-cache"}},
		transmute([]u8)JSX_RUNTIME,
	)
}

PAGE_ENTRY_URL :: "/__saba/page-entry.js"
PAGE_ENTRY :: #load("page-entry.js", string)

page_entry_response :: proc(request: ^Request) -> Response {
	return make_response(
		request,
		.OK,
		{{"Content-Type", "text/javascript; charset=utf-8"}, {"Cache-Control", "no-cache"}},
		transmute([]u8)PAGE_ENTRY,
	)
}
