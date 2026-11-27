// The client of the e2e/http3 suite: three HEAD requests over surf's
// HTTP/3 to the http3_probe fixture on one pooled connection. 204 and 304
// carry no Content-Length, 200 carries the length of the body it leaves out,
// and 304 keeps its validator. It exits 0 and prints an OK line when every
// check held.
//
//	head_client <port> <certificate.pem>
package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:time"
import "shared:surf"

main :: proc() {
	context.logger = log.nil_logger()
	assert(len(os.args) == 3)
	roots: surf.Trust_Roots
	assert(surf.trust_roots_load_file(&roots, os.args[2]) == .None)
	defer surf.trust_roots_destroy(&roots)
	pool: surf.HTTP3_Pool
	assert(surf.http3_pool_init(&pool))
	defer surf.http3_pool_destroy(&pool)
	config := surf.Config {
		http3 = true,
		http3_pool = &pool,
		timeout = 10 * time.Second,
		tls = {roots = &roots},
	}

	cases := [3]struct {
		path:   string,
		status: int,
	}{{"/head204", 204}, {"/head304", 304}, {"/head200", 200}}
	for test in cases {
		url := fmt.aprintf("https://localhost:%s%s", os.args[1], test.path)
		defer delete(url)
		conditional := [1]surf.Header{{"if-none-match", "\"asset-v1\""}}
		response, error := surf.execute(
			{method = .HEAD, url = url, headers = conditional[:]},
			config,
		)
		defer surf.response_destroy(&response)
		fmt.printf(
			"HEAD %s error=%v status=%d body=%d\n",
			test.path,
			error.kind,
			response.status,
			len(response.body),
		)
		assert(error.kind == .None && response.status == test.status && len(response.body) == 0)
		value, found := surf.response_header(&response, "content-length")

		if test.status == 200 {
			assert(found && value == "5")
		} else {
			assert(!found)
		}

		if test.status == 304 {
			etag, have := surf.response_header(&response, "etag")
			assert(have && etag == "\"asset-v1\"")
		}
	}

	fmt.println("OK HEAD over HTTP/3")
}
