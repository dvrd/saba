package saba_s3

import aws "shared:aws"
import "core:time"

// Optional compatibility adapter. AWS alone owns credentials, SigV4, uploads,
// presigning and HTTP execution; importing Saba core never imports this package.
S3_Config :: aws.S3_Config
AWS_Credentials :: aws.AWS_Credentials

// Preserve the historical two-field shape and exact function-value signatures.
// Applications needing typed transport/write diagnostics can import AWS directly.
S3_Result :: struct {
	status: int,
	ok:     bool,
}

load_s3_config :: aws.load_s3_config
s3_config_error :: aws.s3_config_error
s3_download_url :: aws.s3_download_url

// Uncached resolution for scripts and one-shot tools. Every call resolves again
// and can block for up to three metadata calls of 1500 ms each; the secret stays
// unwiped in context.temp_allocator. A server uses a Credential_Cache instead.
aws_credentials :: aws.aws_credentials

// Credentials for a server. Initialize one Credential_Cache at startup, keep it
// filled with credential_refresh from a maintenance thread or timer, and take a
// credential_lease_cached around each signing in a request handler. The cache
// holds one copy of the secret and wipes it once it is replaced and no lease
// holds it.
//
//   credential_lease_cached   request handler: never blocks, never does I/O
//   credential_refresh        maintenance only: blocks for the provider's calls
//   credential_lease          startup or a worker: blocks when a refresh is needed
//
// Every lease is returned with credential_lease_release. Destroy the cache when
// no lease or refresh remains.
Credential_Cache :: aws.Credential_Cache
Credential_Lease :: aws.Credential_Lease
Credential_Error :: aws.Credential_Error
Credential_Error_Kind :: aws.Credential_Error_Kind
Credential_Cancel :: aws.Credential_Cancel
Credential_Clock :: aws.Credential_Clock
Credential_Mode :: aws.Credential_Mode
Credential_Modes :: aws.Credential_Modes
Credential_Source :: aws.Credential_Source
HTTP_Execute :: aws.HTTP_Execute
HTTP_Request :: aws.HTTP_Request
CREDENTIAL_MODES_SUPPORTED :: aws.CREDENTIAL_MODES_SUPPORTED
CREDENTIAL_REFRESH_MARGIN :: aws.CREDENTIAL_REFRESH_MARGIN

credential_cache_init :: aws.credential_cache_init
credential_cache_destroy :: aws.credential_cache_destroy
credential_lease_cached :: aws.credential_lease_cached
credential_lease :: aws.credential_lease
credential_lease_release :: aws.credential_lease_release
credential_refresh :: aws.credential_refresh
credential_cancel :: aws.credential_cancel
// The metadata transport credential_cache_init takes in production.
http_execute_default :: aws.http_execute_default

// The wall clock, for credential_cache_init.
credential_clock_system :: proc(_: rawptr) -> time.Time {
	return time.now()
}

// A view of the lease for the signers. Its strings borrow the lease's snapshot:
// sign before credential_lease_release and do not keep the view.
lease_credentials :: proc(lease: Credential_Lease) -> AWS_Credentials {
	return {
		access_key = lease.access_key,
		secret_key = lease.secret_key,
		session_token = lease.session_token,
	}
}

// Signing without sending. Building a request does no I/O, so a request handler
// can sign with a cached lease and hand the request to its own asynchronous
// transport, such as Saba's upstream adapter. See aws.s3_put_request for the
// borrowing rules of the returned url, headers and body.
S3_Request :: aws.S3_Request
S3_Header :: aws.S3_Header
s3_put_request :: aws.s3_put_request
s3_delete_request :: aws.s3_delete_request
s3_get_request :: aws.s3_get_request
s3_head_request :: aws.s3_head_request

// Blocking. s3_put and s3_delete hold the calling thread until S3 answers or 15
// seconds pass, and s3_put_file hashes the whole file and then holds the thread
// for up to 120 seconds of upload. None of them is safe on a request worker or
// an event-loop thread: a slow S3 stalls every connection that worker serves.
// Call them from a worker pool or a script, or sign with s3_put_request and
// s3_delete_request and send through an asynchronous transport. Credentials from
// aws_credentials block as well; a server leases them from a Credential_Cache.
s3_put :: proc(
	config: S3_Config,
	credentials: AWS_Credentials,
	key: string,
	body: []byte,
	content_type: string,
) -> S3_Result {
	result := aws.s3_put(config, credentials, key, body, content_type)
	return {status = result.status, ok = result.ok}
}

s3_put_file :: proc(config: S3_Config, credentials: AWS_Credentials, key, path, content_type: string) -> S3_Result {
	result := aws.s3_put_file(config, credentials, key, path, content_type)

	return {status = result.status, ok = result.ok}
}

s3_delete :: proc(config: S3_Config, credentials: AWS_Credentials, key: string) -> S3_Result {
	result := aws.s3_delete(config, credentials, key)

	return {status = result.status, ok = result.ok}
}
