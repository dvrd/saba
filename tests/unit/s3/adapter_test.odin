package saba_s3_test

import "core:reflect"
import "core:testing"
import "core:time"
import s3 "shared:saba/s3"

// The adapter keeps the shape callers were written against: these assignments
// stop compiling when a signature changes, and the result has two fields.
@(test)
legacy_signatures_and_result_shape :: proc(t: ^testing.T) {
	resolve: proc() -> (s3.AWS_Credentials, bool) = s3.aws_credentials
	load: proc() -> s3.S3_Config = s3.load_s3_config
	validate: proc(_: s3.S3_Config) -> string = s3.s3_config_error
	presign: proc(_: s3.S3_Config, _: s3.AWS_Credentials, _: string, _: int, _: time.Time) -> (string, bool) = s3.s3_download_url
	testing.expect(t, resolve != nil && load != nil && validate != nil && presign != nil)
	testing.expect_value(t, len(reflect.struct_field_names(s3.S3_Result)), 2)
	two_fields := s3.S3_Result{418, false}
	testing.expect_value(t, two_fields.status, 418)
}

// What AWS rejects before sending reaches the caller as the zero result, with
// no network: missing credentials here.
@(test)
unsigned_requests_are_not_sent :: proc(t: ^testing.T) {
	config := s3.S3_Config {
		bucket = "examplebucket",
		region = "us-east-1",
	}
	testing.expect_value(t, s3.s3_config_error(config), "")
	testing.expect_value(t, s3.s3_delete(config, {}, "object"), s3.S3_Result{})
	testing.expect_value(t, s3.s3_put(config, {}, "object", transmute([]u8)string("payload"), "text/plain"), s3.S3_Result{})
}

// Without an endpoint a request goes to the bucket's virtual-hosted AWS origin.
@(test)
default_origin_and_presigning :: proc(t: ^testing.T) {
	config := s3.S3_Config {
		bucket = "examplebucket",
		region = "us-east-1",
	}
	keys := s3.AWS_Credentials{"fixture-key", "fixture-secret", ""}
	now := time.unix(1369353600, 0)
	request, signed := s3.s3_delete_request(config, keys, "object", now)
	testing.expect(t, signed)
	testing.expect_value(t, request.url, "https://examplebucket.s3.us-east-1.amazonaws.com/object")
	_, presigned := s3.s3_download_url(config, keys, "object", 300, now)
	testing.expect(t, presigned)
}
