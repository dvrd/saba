package saba_ui_test

import "core:strings"
import server "shared:saba/core"
import jsx "shared:saba/jsx"

// Serve the generated HTML and its matching JS separately so the browser test
// can retain DOM references before attaching and inject a corrupt second target.
template_response :: proc(request: ^server.Request) -> server.Response {
	media := "text/javascript; charset=utf-8"
	bytes: string
	switch request.path {
	case "/template-test/attach.js":
		bytes = #load("../../src/modules/attach.js", string)
	case "/template-test/driver.js":
		bytes = #load("../fixtures/ui_template/driver.js", string)
	case "/template-test/page.js", "/template-test/fragment":
		source :: #load("../fixtures/ui_template/page.jsx", string)
		page, err := jsx.compile_page_template(source, "page.jsx", request.allocator)
		if !page.supported || err.message != "" {
			return {status = .Internal_Server_Error}
		}
		if request.path == "/template-test/fragment" {
			bytes, media = page.html, "text/html; charset=utf-8"
		} else {
			bytes, _ = strings.replace_all(
				page.javascript,
				"/__saba/attach.js",
				"/template-test/attach.js",
				request.allocator,
			)
		}
	case:
		return {status = .Not_Found}
	}
	return server.make_response(request, .OK, {{"Content-Type", media}}, transmute([]u8)bytes)
}
