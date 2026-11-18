package saba_s3

import aws "shared:aws"

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
aws_credentials :: aws.aws_credentials
s3_download_url :: aws.s3_download_url

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
