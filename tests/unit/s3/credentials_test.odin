package saba_s3_test

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import aws "shared:aws"
import s3 "shared:saba/s3"

metadata_calls: int

// Counts every metadata call and answers none of them.
counting_execute :: proc(_: s3.HTTP_Request) -> ([]u8, aws.HTTP_Result) {
	sync.atomic_add(&metadata_calls, 1)
	return nil, {}
}

fixed_clock :: proc(_: rawptr) -> time.Time {
	return time.unix(1369353600, 0)
}

// The only test in this suite that touches the environment, so it can set the
// AWS variables without racing another test.
@(test)
request_handler_signs_with_a_cached_lease_without_resolving :: proc(t: ^testing.T) {
	keys := [?]string{"AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN"}
	saved: [len(keys)]string
	for key, index in keys {
		saved[index] = os.get_env(key, context.allocator)
	}
	defer for key, index in keys {
		if saved[index] == "" {
			_ = os.unset_env(key)
		} else {
			_ = os.set_env(key, saved[index])
		}
		delete(saved[index])
	}
	assert(os.set_env("AWS_ACCESS_KEY_ID", "fixture-key") == nil)
	assert(os.set_env("AWS_SECRET_ACCESS_KEY", "fixture-secret") == nil)
	_ = os.unset_env("AWS_SESSION_TOKEN")

	cache: s3.Credential_Cache
	initialized := s3.credential_cache_init(&cache, counting_execute, fixed_clock, modes = {.Environment})
	if !testing.expect_value(t, initialized.kind, s3.Credential_Error_Kind.None) {
		return
	}

	// A handler never resolves: an empty cache answers at once.
	_, empty := s3.credential_lease_cached(&cache)
	testing.expect_value(t, empty.kind, s3.Credential_Error_Kind.Unavailable)

	// Maintenance fills it.
	testing.expect_value(t, s3.credential_refresh(&cache).kind, s3.Credential_Error_Kind.None)

	// The environment changes; the handler keeps the cached copy.
	assert(os.set_env("AWS_ACCESS_KEY_ID", "rotated-key") == nil)
	lease, leased := s3.credential_lease_cached(&cache)
	if !testing.expect_value(t, leased.kind, s3.Credential_Error_Kind.None) {
		return
	}
	testing.expect_value(t, lease.source, s3.Credential_Source.Environment)
	credentials := s3.lease_credentials(lease)
	testing.expect_value(t, credentials.access_key, "fixture-key")
	testing.expect_value(t, credentials.secret_key, "fixture-secret")

	config := s3.S3_Config {
		bucket = "examplebucket",
		region = "us-east-1",
	}
	request, signed := s3.s3_put_request(
		config,
		credentials,
		"object",
		transmute([]u8)string("body"),
		"text/plain",
		fixed_clock(nil),
	)
	testing.expect(t, signed)
	testing.expect_value(t, request.method, "PUT")
	authorized := false
	for header in request.headers {
		if strings.equal_fold(header.name, "authorization") {
			authorized = strings.contains(header.value, "Credential=fixture-key/")
		}
	}
	testing.expect(t, authorized, "the request was not signed with the leased key")

	testing.expect_value(t, s3.credential_cache_destroy(&cache).kind, s3.Credential_Error_Kind.Busy)
	s3.credential_lease_release(&cache, &lease)
	testing.expect_value(t, lease.access_key, "")
	testing.expect_value(t, s3.credential_cache_destroy(&cache).kind, s3.Credential_Error_Kind.None)
	testing.expect_value(t, sync.atomic_load(&metadata_calls), 0)
}

@(test)
system_clock_reads_the_wall_clock :: proc(t: ^testing.T) {
	before := time.now()
	now := s3.credential_clock_system(nil)
	testing.expect(t, time.diff(before, now) >= 0 && time.diff(before, now) < time.Minute)
}
