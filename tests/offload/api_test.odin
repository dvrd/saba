package saba_offload_test

import adapter "../../offload"
import server "../../core"
import "core:testing"
import "core:time"
import pool "shared:async/offload"

@(test)
legacy_response_preserves_the_original_procedure_value_type :: proc(t: ^testing.T) {
	legacy: proc(
		_: ^pool.Pool,
		_: ^pool.Work,
		_: adapter.Build,
		_: time.Duration,
	) -> (
		server.Response,
		bool,
	)
	legacy = adapter.response
	_, accepted := legacy(nil, nil, nil, 0)
	testing.expect(t, !accepted)
}
