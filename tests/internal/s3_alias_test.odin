package server

import "core:testing"
import "core:time"

@(test)
s3_facade_aliases_keep_legacy_callable_types_and_result_shape :: proc(t: ^testing.T) {
	put: proc(_: S3_Config, _: AWS_Credentials, _: string, _: []u8, _: string) -> S3_Result = s3_put
	file: proc(_: S3_Config, _: AWS_Credentials, _: string, _: string, _: string) -> S3_Result = s3_put_file
	del: proc(_: S3_Config, _: AWS_Credentials, _: string) -> S3_Result = s3_delete
	resolve: proc() -> (AWS_Credentials, bool) = aws_credentials
	load: proc() -> S3_Config = load_s3_config
	validate: proc(_: S3_Config) -> string = s3_config_error
	presign: proc(_: S3_Config, _: AWS_Credentials, _: string, _: int, _: time.Time) -> (string, bool) =
		s3_download_url
	testing.expect(
		t,
		put != nil && file != nil && del != nil && resolve != nil && load != nil && validate != nil && presign != nil,
	)
	two_fields := S3_Result{204, true}
	testing.expect(t, two_fields.status == 204 && two_fields.ok)
	config := S3_Config {
		bucket = "examplebucket",
		region = "us-east-1",
	}

	testing.expect_value(t, validate(config), "")
	credentials := AWS_Credentials{"fixture-key", "fixture-secret", "fixture-token"}
	url, ok := presign(config, credentials, "a b", 300, time.unix(1369353600, 0))
	testing.expect(t, ok && len(url) > 0)
}
