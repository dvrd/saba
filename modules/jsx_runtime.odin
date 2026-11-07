package saba_modules

import jsx "../jsx"
import assets "../assets"

JSX_RUNTIME_URL :: jsx.JSX_RUNTIME_URL
JSX_RUNTIME :: #load("dom.js", string)

jsx_runtime_response :: proc(request: ^Request) -> Response {
	return assets.representation_response(request, transmute([]u8)JSX_RUNTIME, "text/javascript; charset=utf-8")
}

PAGE_ENTRY_URL :: "/__saba/page-entry.js"
PAGE_ENTRY :: #load("page-entry.js", string)

page_entry_response :: proc(request: ^Request) -> Response {
	return assets.representation_response(request, transmute([]u8)PAGE_ENTRY, "text/javascript; charset=utf-8")
}
