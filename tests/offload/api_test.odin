package saba_offload_test

import adapter "shared:saba/offload"
import server "shared:saba/core"
import "core:testing"
import "core:time"
import pool "shared:async/offload"

@(test)
legacy_response_preserves_the_original_procedure_value_type :: proc(t: ^testing.T) {
	legacy: proc(_: ^pool.Pool, _: ^pool.Work, _: adapter.Build, _: time.Duration) -> (server.Response, bool)
	legacy = adapter.response
	_, accepted := legacy(nil, nil, nil, 0)
	testing.expect(t, !accepted)
}

// A job that runs out of time may already have taken effect, so it answers 504
// rather than a 408 that invites a replay; a full pool is still 503.
@(test)
expired_jobs_answer_gateway_timeout_not_request_timeout :: proc(t: ^testing.T) {
	testing.expect_value(t, adapter.expired_response().status, server.HTTP_Status.Gateway_Timeout)
	testing.expect(t, adapter.expired_response().close_connection)
	testing.expect_value(t, adapter.admission_response(.Expired).status, server.HTTP_Status.Gateway_Timeout)
	testing.expect_value(t, adapter.admission_response(.Full).status, server.HTTP_Status.Service_Unavailable)
}
