// The legacy blocking calls of saba/s3 sign with AWS's real SigV4 and send
// through AWS's default transport. A loopback HTTPS server stands in for S3 and
// records what reached it; its non-2xx answer must come back in the two-field
// result.
package saba_s3_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import credentials "shared:async/tls/credentials"
import store "shared:async/tls/credentials/store"
import core "shared:saba/core"
import s3 "shared:saba/s3"

CERTIFICATE :: "tests/fixtures/tls/localhost.pem"
KEY :: "tests/fixtures/tls/rsa2048.pem"

Seen :: struct {
	method, path, body: string,
	signed:             bool,
}

Fake_S3 :: struct {
	control: core.Server_Control,
	config:  core.Server,
	tls:     core.TLS_Config,
	mutex:   sync.Mutex,
	seen:    [dynamic]Seen,
	result:  bool,
}

// Records every request and answers 403, which no caller may report as ok.
record :: proc(data: rawptr, _: ^core.Connection, request: ^core.Request) -> core.Response {
	fake := cast(^Fake_S3)data
	authorization := core.header_value(request, "Authorization")
	sync.lock(&fake.mutex)
	append(
		&fake.seen,
		Seen {
			method = strings.clone(request.method, fake.seen.allocator),
			path = strings.clone(request.path, fake.seen.allocator),
			body = strings.clone(string(request.body), fake.seen.allocator),
			signed = strings.has_prefix(authorization, "AWS4-HMAC-SHA256 Credential=fixture-key/"),
		},
	)
	sync.unlock(&fake.mutex)
	return {status = .Forbidden}
}

@(test)
legacy_calls_delegate_to_aws :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, time.Minute)
	certificate, e1 := os.read_entire_file(CERTIFICATE, context.temp_allocator)
	key, e2 := os.read_entire_file(KEY, context.temp_allocator)
	if !testing.expectf(t, e1 == nil && e2 == nil, "TLS fixtures: %v %v", e1, e2) {
		return
	}
	identity, created := credentials.create(certificate, key, {}, context.allocator)
	if !testing.expect_value(t, created, credentials.Error.None) {
		return
	}
	owner, opened := store.create({}, context.allocator)
	if !testing.expect_value(t, opened.kind, store.Error_Kind.None) {
		return
	}
	defer store.destroy(&owner)
	testing.expect_value(t, store.replace(owner, &identity).kind, store.Error_Kind.None)

	fake: Fake_S3
	fake.seen.allocator = context.allocator
	defer {
		for seen in fake.seen {
			delete(seen.method)
			delete(seen.path)
			delete(seen.body)
		}
		delete(fake.seen)
	}
	fake.tls = {
		store = owner,
	}
	fake.config = {
		port         = 0,
		workers      = 1,
		handler      = record,
		handler_data = &fake,
		control      = &fake.control,
		tls          = &fake.tls,
	}
	worker := thread.create_and_start_with_poly_data(&fake, proc(fake: ^Fake_S3) {fake.result = core.serve(fake.config)})
	defer {
		core.stop_server(&fake.control)
		thread.join(worker)
		thread.destroy(worker)
		testing.expect(t, fake.result, "fake S3 did not serve")
	}
	deadline := time.tick_add(time.tick_now(), 10 * time.Second)
	for !core.server_ready(&fake.control) && time.tick_since(deadline) < 0 {
		time.sleep(time.Millisecond)
	}
	endpoint, ready := core.server_endpoint(&fake.control)
	if !testing.expect(t, ready, "fake S3 not ready") {
		return
	}

	// The historical function-value types: a change to any signature breaks
	// these assignments at compile time.
	put: proc(_: s3.S3_Config, _: s3.AWS_Credentials, _: string, _: []u8, _: string) -> s3.S3_Result = s3.s3_put
	put_file: proc(_: s3.S3_Config, _: s3.AWS_Credentials, _: string, _: string, _: string) -> s3.S3_Result = s3.s3_put_file
	remove: proc(_: s3.S3_Config, _: s3.AWS_Credentials, _: string) -> s3.S3_Result = s3.s3_delete

	config := s3.S3_Config {
		bucket   = "examplebucket",
		region   = "us-east-1",
		endpoint = fmt.tprintf("https://localhost:%d", endpoint.port),
		ca_file  = CERTIFICATE,
	}
	keys := s3.AWS_Credentials{"fixture-key", "fixture-secret", ""}
	refused := s3.S3_Result{403, false}

	testing.expect_value(t, put(config, keys, "object", transmute([]u8)string("payload"), "text/plain"), refused)

	work, made := os.make_directory_temp("", "saba-s3-*", context.temp_allocator)
	if !testing.expectf(t, made == nil, "work directory: %v", made) {
		return
	}
	defer os.remove_all(work)
	body := fmt.tprintf("%s/body", work)
	testing.expect_value(t, os.write_entire_file(body, "payload"), nil)
	// The file is hashed for the signature, then streamed as the body.
	testing.expect_value(t, put_file(config, keys, "object", body, "text/plain"), refused)

	testing.expect_value(t, remove(config, keys, "object"), refused)

	sync.lock(&fake.mutex)
	defer sync.unlock(&fake.mutex)
	expected := []Seen{{"PUT", "/object", "payload", true}, {"PUT", "/object", "payload", true}, {"DELETE", "/object", "", true}}
	if !testing.expectf(t, len(fake.seen) == len(expected), "S3 saw %v", fake.seen[:]) {
		return
	}
	for seen, index in fake.seen {
		testing.expect_value(t, seen, expected[index])
	}
}
