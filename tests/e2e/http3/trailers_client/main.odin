// The client of the e2e/http3 suite, over async's HTTP/3 exchange
// (client.odin): two POSTs to the http3_trailers fixture on one connection,
// with and without a body, each with a request trailer; each response must
// carry its trailer apart from the head. It exits 0 and prints an OK line when
// every check held.
//
//	trailers_client <port> <certificate.pem>
package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import http "shared:async/http"
import "shared:async/tls"

main :: proc() {
	context.logger = log.nil_logger()
	assert(len(os.args) == 3)
	port_text, cert_path := os.args[1], os.args[2]
	roots: tls.Root_Pool
	assert(tls.root_pool_load_file(&roots, cert_path) == nil)
	defer tls.root_pool_destroy(&roots)
	port, valid := strconv.parse_int(port_text)
	assert(valid)
	c: Client
	client_open(&c, port, &roots)
	defer client_close(&c)

	url := fmt.aprintf("https://localhost:%s/trailers", port_text)
	defer delete(url)

	trailer_headers := [1]http.Header{{"X-Request-Checksum", "abc"}}

	for body in ([]string{"payload", ""}) {
		response := post(&c, url, transmute([]u8)body, trailer_headers[:])
		assert(response.error.kind == .None && response.status == 200 && string(response.response[:]) == "echo")
		value, found := post_trailer(response, "X-Response-Checksum")
		assert(found && value == "ack")
		assert(!response.merged)
		post_destroy(response)
	}

	fmt.println("OK native HTTP3 trailers")
}
