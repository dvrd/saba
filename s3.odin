package server

import "base:runtime"
import "core:c"
import "core:crypto/hash"
import "core:crypto/hmac"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import curl "vendor:curl"

S3_Config :: struct {
	bucket, region:    string,
	endpoint, ca_file: string, // Optional HTTPS endpoint/private CA for isolated peers.
	path_style:        bool,
}
AWS_Credentials :: struct {
	access_key, secret_key, session_token: string,
}
S3_Result :: struct {
	status: int,
	ok:     bool,
}

load_s3_config :: proc() -> S3_Config {
	config := S3_Config {
		bucket = os.get_env("AWS_S3_BUCKET", context.allocator),
		region = os.get_env("AWS_REGION", context.allocator),
	}
	if config.region == "" do config.region = os.get_env("AWS_DEFAULT_REGION", context.allocator)
	return config
}
s3_config_error :: proc(config: S3_Config) -> string {
	if config.bucket == "" do return ""
	if len(config.bucket) < 3 || len(config.bucket) > 63 || config.region == "" do return "S3 requires AWS_S3_BUCKET and AWS_REGION"
	for ch in config.bucket {
		if !(ch >= 'a' && ch <= 'z') && !(ch >= '0' && ch <= '9') && ch != '-' && ch != '.' do return "Invalid S3 bucket name"
	}
	for ch in config.region {
		if !(ch >= 'a' && ch <= 'z') && !(ch >= '0' && ch <= '9') && ch != '-' do return "Invalid AWS region"
	}
	if config.endpoint != "" {
		if !strings.has_prefix(config.endpoint, "https://") || strings.contains_any(config.endpoint[8:], "/?#@\r\n") || len(config.endpoint) <= 8 do return "S3 endpoint must be an HTTPS origin"
	}
	return ""
}

// Resolve at operation time so rotated role credentials are never retained indefinitely.
// A configured but incomplete credential source fails closed instead of falling through.
aws_credentials :: proc() -> (credentials: AWS_Credentials, ok: bool) {
	credentials = {
		access_key    = os.get_env("AWS_ACCESS_KEY_ID", context.temp_allocator),
		secret_key    = os.get_env("AWS_SECRET_ACCESS_KEY", context.temp_allocator),
		session_token = os.get_env("AWS_SESSION_TOKEN", context.temp_allocator),
	}
	if credentials.access_key != "" || credentials.secret_key != "" || credentials.session_token != "" do return credentials, aws_credentials_valid(credentials)
	profile := os.get_env("AWS_PROFILE", context.temp_allocator)
	if profile == "" do profile = "default"
	path := os.get_env("AWS_SHARED_CREDENTIALS_FILE", context.temp_allocator)
	if path == "" do path = fmt.tprintf("%s/.aws/credentials", os.get_env("HOME", context.temp_allocator))
	if data, error := os.read_entire_file(path, context.temp_allocator); error == nil {
		if len(data) > 64 * 1024 do return
		section := ""
		source := string(data)
		for line in strings.split_iterator(&source, "\n") {
			line := strings.trim_space(line)
			if line == "" || line[0] == '#' || line[0] == ';' do continue
			if line[0] == '[' && line[len(line) - 1] == ']' {
				section = strings.trim_space(line[1:len(line) - 1]); continue
			}
			if section != profile do continue
			equal := strings.index_byte(line, '=')
			if equal < 1 do continue
			key, value := strings.trim_space(line[:equal]), strings.trim_space(line[equal + 1:])
			switch key {
			case "aws_access_key_id":
				credentials.access_key = value
			case "aws_secret_access_key":
				credentials.secret_key = value
			case "aws_session_token":
				credentials.session_token = value
			}
		}
		if credentials.access_key != "" || credentials.secret_key != "" do return credentials, aws_credentials_valid(credentials)
	}
	relative := os.get_env("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", context.temp_allocator)
	url, token := "", ""
	if relative != "" {
		if !strings.has_prefix(relative, "/") || strings.contains_any(relative, "\r\n#") do return
		url = fmt.tprintf("http://169.254.170.2%s", relative)
	} else {
		if os.get_env("AWS_EC2_METADATA_DISABLED", context.temp_allocator) == "true" do return
		reply, result := s3_http(
			"PUT",
			"http://169.254.169.254/latest/api/token",
			nil,
			{"X-aws-ec2-metadata-token-ttl-seconds: 60"},
			"",
			true,
		)
		if !result.ok do return
		token = string(reply)
		if token == "" || strings.contains_any(token, "\r\n") do return
		role, role_result := s3_http(
			"GET",
			"http://169.254.169.254/latest/meta-data/iam/security-credentials/",
			nil,
			{fmt.tprintf("X-aws-ec2-metadata-token: %s", token)},
			"",
			true,
		)
		role_name := strings.trim_space(string(role))
		if !role_result.ok || role_name == "" || strings.contains_any(role_name, "/\r\n?#") do return
		url = fmt.tprintf(
			"http://169.254.169.254/latest/meta-data/iam/security-credentials/%s",
			role_name,
		)
	}
	headers: []string
	if token != "" do headers = {fmt.tprintf("X-aws-ec2-metadata-token: %s", token)}
	data, result := s3_http("GET", url, nil, headers, "", true)
	if !result.ok do return
	document: struct {
		access: string `json:"AccessKeyId"`,
		secret: string `json:"SecretAccessKey"`,
		token:  string `json:"Token"`,
	}
	if json.unmarshal(data, &document, allocator = context.temp_allocator) != nil do return
	credentials = {document.access, document.secret, document.token}
	return credentials, aws_credentials_valid(credentials)
}
@(private)
aws_credentials_valid :: proc(value: AWS_Credentials) -> bool {
	if value.access_key == "" || value.secret_key == "" do return false
	for text in ([]string{value.access_key, value.secret_key, value.session_token}) {
		if strings.contains_any(text, "\r\n\x00") do return false
	}
	return true
}

s3_put :: proc(
	config: S3_Config,
	credentials: AWS_Credentials,
	key: string,
	body: []byte,
	content_type: string,
) -> S3_Result {
	return s3_object_request(config, credentials, "PUT", key, body, content_type)
}
// Stream a file with a fixed buffer, avoiding an archive-sized allocation.
s3_put_file :: proc(
	config: S3_Config,
	credentials: AWS_Credentials,
	key, path, content_type: string,
) -> S3_Result {
	file, error := os.open(path)
	if error != nil do return {}
	defer os.close(file)
	size, size_error := os.file_size(file)
	if size_error != nil do return {}
	hasher: hash.Context
	hash.init(&hasher, .SHA256)
	buffer: [64 * 1024]byte
	for {
		n, read_error := os.read(file, buffer[:])
		if read_error != nil && read_error != io.Error.EOF do return {}
		if n == 0 do break
		hash.update(&hasher, buffer[:n])
	}
	digest: [32]byte
	hash.final(&hasher, digest[:])
	if _, seek_error := os.seek(file, 0, .Start); seek_error != nil do return {}
	return s3_object_request(
		config,
		credentials,
		"PUT",
		key,
		nil,
		content_type,
		file,
		size,
		string(hex.encode(digest[:], allocator = context.temp_allocator)),
	)
}
s3_delete :: proc(config: S3_Config, credentials: AWS_Credentials, key: string) -> S3_Result {
	return s3_object_request(config, credentials, "DELETE", key, nil, "")
}
@(private)
s3_object_request :: proc(
	config: S3_Config,
	credentials: AWS_Credentials,
	method, key: string,
	body: []byte,
	content_type: string,
	file: ^os.File = nil,
	file_size: i64 = 0,
	file_digest: string = "",
) -> S3_Result {
	if !aws_credentials_valid(credentials) || s3_config_error(config) != "" || config.bucket == "" || key == "" || strings.contains_any(content_type, "\r\n\x00") do return {}
	origin, host, path := s3_location(config, key)
	stamp := s3_timestamp(time.now())
	digest := file_digest if file != nil else s3_sha256(body)
	canonical_headers := fmt.tprintf(
		"host:%s\nx-amz-content-sha256:%s\nx-amz-date:%s\n",
		host,
		digest,
		stamp,
	)
	signed := "host;x-amz-content-sha256;x-amz-date"
	headers := make([dynamic]string, 0, 8, context.temp_allocator)
	append(
		&headers,
		fmt.tprintf("x-amz-content-sha256: %s", digest),
		fmt.tprintf("x-amz-date: %s", stamp),
		"Expect:",
	)
	if content_type != "" do append(&headers, fmt.tprintf("Content-Type: %s", content_type))
	if credentials.session_token != "" {
		canonical_headers = fmt.tprintf(
			"%sx-amz-security-token:%s\n",
			canonical_headers,
			credentials.session_token,
		)
		signed = fmt.tprintf("%s;x-amz-security-token", signed)
		append(&headers, fmt.tprintf("x-amz-security-token: %s", credentials.session_token))
	}
	canonical := fmt.tprintf(
		"%s\n%s\n\n%s\n%s\n%s",
		method,
		path,
		canonical_headers,
		signed,
		digest,
	)
	scope := fmt.tprintf("%s/%s/s3/aws4_request", stamp[:8], config.region)
	signature := s3_signature(credentials.secret_key, config.region, stamp, scope, canonical)
	append(
		&headers,
		fmt.tprintf(
			"Authorization: AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s",
			credentials.access_key,
			scope,
			signed,
			signature,
		),
	)
	_, result := s3_http(
		method,
		fmt.tprintf("%s%s", origin, path),
		body,
		headers[:],
		config.ca_file,
		upload_file = file,
		upload_size = file_size,
	)
	return result
}

// Returned URL is a bearer credential. Never persist it or include it in logs.
s3_download_url :: proc(
	config: S3_Config,
	credentials: AWS_Credentials,
	key: string,
	expires_seconds := 300,
	now: time.Time = {},
) -> (
	url: string,
	ok: bool,
) {
	if !aws_credentials_valid(credentials) || s3_config_error(config) != "" || config.bucket == "" || key == "" || expires_seconds < 1 || expires_seconds > 604800 do return
	origin, host, path := s3_location(config, key)
	instant := now
	if instant == (time.Time{}) do instant = time.now()
	stamp := s3_timestamp(instant)
	scope := fmt.tprintf("%s/%s/s3/aws4_request", stamp[:8], config.region)
	query := fmt.tprintf(
		"X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=%s&X-Amz-Date=%s&X-Amz-Expires=%d",
		s3_encode(fmt.tprintf("%s/%s", credentials.access_key, scope)),
		stamp,
		expires_seconds,
	)
	if credentials.session_token != "" do query = fmt.tprintf("%s&X-Amz-Security-Token=%s", query, s3_encode(credentials.session_token))
	query = fmt.tprintf("%s&X-Amz-SignedHeaders=host", query)
	canonical := fmt.tprintf("GET\n%s\n%s\nhost:%s\n\nhost\nUNSIGNED-PAYLOAD", path, query, host)
	signature := s3_signature(credentials.secret_key, config.region, stamp, scope, canonical)
	return fmt.tprintf("%s%s?%s&X-Amz-Signature=%s", origin, path, query, signature), true
}
@(private)
s3_location :: proc(config: S3_Config, key: string) -> (origin, host, path: string) {
	origin = config.endpoint
	suffix := "amazonaws.com.cn" if strings.has_prefix(config.region, "cn-") else "amazonaws.com"
	path_style := config.path_style || strings.contains(config.bucket, ".")
	if origin == "" {
		if path_style do origin = fmt.tprintf("https://s3.%s.%s", config.region, suffix)
		else do origin = fmt.tprintf("https://%s.s3.%s.%s", config.bucket, config.region, suffix)
	}
	host = origin[8:]
	path = fmt.tprintf("/%s", s3_encode(key, true))
	if path_style do path = fmt.tprintf("/%s%s", config.bucket, path)
	return
}
@(private)
s3_encode :: proc(text: string, keep_slashes := false) -> string {
	builder := strings.builder_make(allocator = context.temp_allocator)
	for ch in transmute([]byte)text {
		if ch >= 'a' && ch <= 'z' ||
		   ch >= 'A' && ch <= 'Z' ||
		   ch >= '0' && ch <= '9' ||
		   ch == '-' ||
		   ch == '_' ||
		   ch == '.' ||
		   ch == '~' ||
		   keep_slashes && ch == '/' {
			strings.write_byte(&builder, ch)
		} else {
			digits := "0123456789ABCDEF"
			strings.write_byte(
				&builder,
				'%',
			); strings.write_byte(&builder, digits[ch >> 4]); strings.write_byte(&builder, digits[ch & 15])
		}
	}
	return strings.to_string(builder)
}
@(private)
s3_sha256 :: proc(data: []byte) -> string {
	digest: [32]byte
	hash.hash(.SHA256, data, digest[:])
	return string(hex.encode(digest[:], allocator = context.temp_allocator))
}
@(private)
s3_signature :: proc(secret, region, stamp, scope, canonical: string) -> string {
	key: [32]byte
	hmac.sum(
		.SHA256,
		key[:],
		transmute([]byte)stamp[:8],
		transmute([]byte)fmt.tprintf("AWS4%s", secret),
	)
	for text in ([]string{region, "s3", "aws4_request"}) {
		next: [32]byte
		hmac.sum(.SHA256, next[:], transmute([]byte)text, key[:])
		key = next
	}
	to_sign := fmt.tprintf(
		"AWS4-HMAC-SHA256\n%s\n%s\n%s",
		stamp,
		scope,
		s3_sha256(transmute([]byte)canonical),
	)
	signature: [32]byte
	hmac.sum(.SHA256, signature[:], transmute([]byte)to_sign, key[:])
	return string(hex.encode(signature[:], allocator = context.temp_allocator))
}
@(private)
s3_timestamp :: proc(now: time.Time) -> string {
	year, month, day := time.date(now)
	hour, minute, second := time.clock(now)
	return fmt.tprintf("%04d%02d%02dT%02d%02d%02dZ", year, int(month), day, hour, minute, second)
}

@(private)
S3_Reply :: struct {
	data: [64 * 1024]byte,
	used: int,
}
@(private)
s3_ready: sync.Once
@(private)
s3_initialized: bool
@(private)
s3_initialize :: proc() {
	if curl.global_init(curl.GLOBAL_DEFAULT) != .E_OK do return
	version := curl.version_info(.FIRST)
	s3_initialized = version != nil && version.features & curl.VERSION_ASYNCHDNS != 0
}
@(private)
s3_http :: proc(
	method, url: string,
	body: []byte,
	headers: []string,
	ca_file: string,
	metadata := false,
	upload_file: ^os.File = nil,
	upload_size: i64 = 0,
) -> (
	data: []byte,
	result: S3_Result,
) {
	if !metadata && !strings.has_prefix(url, "https://") do return
	sync.once_do(&s3_ready, s3_initialize)
	if !s3_initialized do return
	handle := curl.easy_init()
	if handle == nil do return
	list: ^curl.slist
	defer {curl.easy_cleanup(handle); if list != nil do curl.slist_free_all(list)}
	for header in headers {
		if strings.contains_any(header, "\r\n\x00") do return
		next := curl.slist_append(list, s3_cstring(header))
		if next == nil do return
		list = next
	}
	if list != nil && curl.easy_setopt(handle, .HTTPHEADER, list) != .E_OK do return
	for setting in ([]struct {
			key:   curl.option,
			value: string,
		}{{.URL, url}, {.CUSTOMREQUEST, method}, {.PROXY, ""}}) {
		if curl.easy_setopt(handle, setting.key, s3_cstring(setting.value)) != .E_OK do return
	}
	if ca_file != "" && curl.easy_setopt(handle, .CAINFO, s3_cstring(ca_file)) != .E_OK do return
	timeout := 1500 if metadata else (120000 if upload_file != nil else 15000)
	for setting in ([]struct {
			key:   curl.option,
			value: c.long,
		} {
			{.NOSIGNAL, 1},
			{.PATH_AS_IS, 1},
			{.SSL_VERIFYPEER, 1},
			{.SSL_VERIFYHOST, 2},
			{.FOLLOWLOCATION, 0},
			{.CONNECTTIMEOUT_MS, c.long(min(timeout, 5000))},
			{.TIMEOUT_MS, c.long(timeout)},
		}) {
		if curl.easy_setopt(handle, setting.key, setting.value) != .E_OK do return
	}
	if upload_file != nil {
		if curl.easy_setopt(handle, .UPLOAD, c.long(1)) != .E_OK ||
		   curl.easy_setopt(handle, .READFUNCTION, s3_read_file) != .E_OK ||
		   curl.easy_setopt(handle, .READDATA, upload_file) != .E_OK ||
		   curl.easy_setopt(handle, .INFILESIZE_LARGE, c.longlong(upload_size)) != .E_OK {
			return
		}
	} else if method == "PUT" {
		empty: byte
		pointer := raw_data(body)
		if pointer == nil do pointer = &empty
		if curl.easy_setopt(handle, .POSTFIELDS, pointer) != .E_OK || curl.easy_setopt(handle, .POSTFIELDSIZE_LARGE, c.longlong(len(body))) != .E_OK do return
	}
	reply: S3_Reply
	if curl.easy_setopt(handle, .WRITEFUNCTION, s3_receive) != .E_OK || curl.easy_setopt(handle, .WRITEDATA, &reply) != .E_OK do return
	if curl.easy_perform(handle) != .E_OK do return
	status: c.long
	if curl.easy_getinfo(handle, .RESPONSE_CODE, &status) != .E_OK do return
	copied := make([]byte, reply.used, context.temp_allocator)
	copy(copied, reply.data[:reply.used])
	return copied, {status = int(status), ok = status >= 200 && status < 300}
}
@(private)
s3_receive :: proc "c" (data: rawptr, size, count: c.size_t, userdata: rawptr) -> c.size_t {
	reply := cast(^S3_Reply)userdata
	if size == 0 || count > c.size_t(len(reply.data) - reply.used) / size do return 0
	n := int(size * count)
	copy(reply.data[reply.used:], ([^]byte)(data)[:n]); reply.used += n
	return c.size_t(n)
}
@(private)
s3_cstring :: proc(value: string) -> cstring {
	result, _ := strings.clone_to_cstring(value, context.temp_allocator)
	return result
}

@(private)
s3_read_file :: proc "c" (buffer: [^]byte, size, count: c.size_t, userdata: rawptr) -> c.size_t {
	context = runtime.default_context()
	if size == 0 || count == 0 do return 0
	if count > c.size_t(max(int)) / size do return curl.READFUNC_ABORT
	n, error := os.read(cast(^os.File)userdata, buffer[:int(size * count)])
	if error != nil && error != io.Error.EOF do return curl.READFUNC_ABORT
	return c.size_t(n)
}
