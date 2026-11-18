package saba_assets

import "core:log"
import "core:net"
import "core:path/filepath"
import "core:strings"
import http "shared:http"
import "core:crypto/sha2"
import core "../core"
import rt "base:runtime"
import "core:fmt"
import "core:mem"
import charged "core:mem/budget"
import budget "core:sync/budget"
import owned "core:mem/owned"
import "core:os"
import "core:time"

// Configured mounts own their URL prefix. Development reads current files so
// edits and additions work with hot reload; production serves only preloaded data.
serve_assets :: proc(request: ^Request, caches: []Asset_Cache, development := false) -> (Response, bool) {
	if request.method != "GET" && request.method != "HEAD" {
		return {}, false
	}

	for cache in caches {
		if !strings.has_prefix(request.path, cache.mount.prefix) {
			continue
		}
		relative, decoded := net.percent_decode(request.path[len(cache.mount.prefix):], request.allocator)
		if !decoded || !module_relative_ok(relative) || strings.has_suffix(relative, ".jsx") {
			return not_found(request), true
		}

		if development {
			path, found, allowed := module_file(cache.mount.directory, relative, request.allocator)
			if !found || !allowed {
				return not_found(request), true
			}
			limit := cache.max_file_bytes

			if limit == 0 {
				limit = DEFAULT_ASSET_LIMITS.max_file_bytes
			}

			body, read_error := read_limited(path, limit, request.allocator)

			if read_error.kind != .None {
				log.errorf("Could not read asset: %s", path)
				return Response{status = .Internal_Server_Error}, true
			}

			return representation_response(request, body, asset_content_type(relative), true), true
		}

		cached, found := cache.files[relative]

		if !found {
			return not_found(request), true
		}

		return prepared_representation_response(request, &cached), true
	}

	return {}, false
}

asset_content_type :: proc(path: string) -> string {
	extension := filepath.ext(path)

	for item in ([][2]string {
			{".html", "text/html; charset=utf-8"},
			{".htm", "text/html; charset=utf-8"},
			{".css", "text/css; charset=utf-8"},
			{".js", "text/javascript; charset=utf-8"},
			{".mjs", "text/javascript; charset=utf-8"},
			{".txt", "text/plain; charset=utf-8"},
			{".csv", "text/csv; charset=utf-8"},
			{".json", "application/json"},
			{".map", "application/json"},
			{".xml", "application/xml"},
			{".webmanifest", "application/manifest+json"},
			{".wasm", "application/wasm"},
			{".svg", "image/svg+xml"},
			{".png", "image/png"},
			{".jpg", "image/jpeg"},
			{".jpeg", "image/jpeg"},
			{".gif", "image/gif"},
			{".webp", "image/webp"},
			{".avif", "image/avif"},
			{".ico", "image/vnd.microsoft.icon"},
			{".woff", "font/woff"},
			{".woff2", "font/woff2"},
			{".ttf", "font/ttf"},
			{".otf", "font/otf"},
			{".pdf", "application/pdf"},
			{".zip", "application/zip"},
			{".gz", "application/gzip"},
			{".mp3", "audio/mpeg"},
			{".wav", "audio/wav"},
			{".ogg", "audio/ogg"},
			{".mp4", "video/mp4"},
			{".webm", "video/webm"},
		}) {
		if strings.equal_fold(extension, item[0]) {
			return item[1]
		}
	}

	return "application/octet-stream"
}

// Static representations use explicit revalidation. Development always returns
// fresh bytes with no-store. Bodies remain borrowed until sending completes;
// core suppresses HEAD bytes while retaining their GET representation length.
representation_response :: proc(
	request: ^Request,
	body: []u8,
	content_type: string,
	development := false,
) -> Response {
	if development {
		return make_response(request, .OK, {{"Content-Type", content_type}, {"Cache-Control", "no-store"}}, body)
	}
	prepared := prepare_representation(body, content_type)
	return prepared_representation_response(request, &prepared)
}

// One precompressed body and the validator of those exact bytes.
Encoded_Representation :: struct {
	body:    []u8,
	tag:     [72]u8,
	tag_len: int,
}

// Metadata is inline. Body, content_type and any encoded bodies remain borrowed
// and must stay immutable through every response send. Prepare once after loading
// a production representation; development must use representation_response(..., true).
// prepare_representation is allocation-free and identity-only;
// prepare_encoded_representation also stores gzip and Brotli variants (each kept only
// when smaller than the original), chosen per request by Accept-Encoding with
// `Vary: Accept-Encoding`. Each variant has its own strong tag: "<sha>-gzip", "<sha>-br".
Prepared_Representation :: struct {
	body:         []u8,
	content_type: string,
	tag:          [66]u8,
	gzip, brotli: Encoded_Representation,
	// Set by prepare_encoded_representation: the variants are final, so the
	// post-handler content coding must not run again for this response.
	prepared:     bool,
}

prepare_representation :: proc(body: []u8, content_type: string) -> Prepared_Representation {
	prepared := Prepared_Representation {
		body         = body,
		content_type = content_type,
	}

	digest: [32]u8
	hasher: sha2.Context_256
	sha2.init_256(&hasher)
	sha2.update(&hasher, body)
	sha2.final(&hasher, digest[:])
	prepared.tag[0] = '"'
	prepared.tag[65] = '"'
	alphabet := "0123456789abcdef"

	for byte, index in digest {
		prepared.tag[1 + index * 2] = alphabet[byte >> 4]
		prepared.tag[2 + index * 2] = alphabet[byte & 15]
	}

	return prepared
}

// Compresses once, at prepare time: Brotli at its best level and gzip, each only when
// smaller than the original and while `budget` bytes remain. A variant that cannot
// be allocated or is not smaller is simply absent. Returns the bytes retained.
prepare_encoded_representation :: proc(
	body: []u8,
	content_type: string,
	allocator: mem.Allocator,
	budget := max(int),
) -> (
	prepared: Prepared_Representation,
	retained: int,
) {
	prepared = prepare_representation(body, content_type)
	prepared.prepared = true

	if len(body) < core.GZIP_MIN_BYTES || len(body) > core.GZIP_MAX_INPUT || !core.compressible_type(content_type) {
		return
	}

	remaining := budget

	if smaller := core.encode_smaller(.Brotli, body, core.BROTLI_PREPARED_LEVEL, allocator); smaller != nil {
		if len(smaller) <= remaining {
			prepared.brotli = encoded_representation(&prepared, smaller, "-br\"")
			remaining -= len(smaller)
			retained += len(smaller)
		} else {
			delete(smaller, allocator)
		}
	}

	if smaller := core.encode_smaller(.Gzip, body, core.BROTLI_PREPARED_LEVEL, allocator); smaller != nil {
		if len(smaller) <= remaining {
			prepared.gzip = encoded_representation(&prepared, smaller, "-gzip\"")
			retained += len(smaller)
		} else {
			delete(smaller, allocator)
		}
	}

	return
}

encoded_representation :: proc(base: ^Prepared_Representation, body: []u8, suffix: string) -> Encoded_Representation {
	encoded := Encoded_Representation {
		body = body,
	}

	// The identity tag without its closing quote, then the coding and the quote.
	encoded.tag_len = copy(encoded.tag[:], base.tag[:65])
	encoded.tag_len += copy(encoded.tag[encoded.tag_len:], suffix)

	return encoded
}

// Frees the encoded variants; the identity body belongs to the caller.
destroy_encoded_representation :: proc(prepared: Prepared_Representation, allocator: mem.Allocator) {
	delete(prepared.gzip.body, allocator)
	delete(prepared.brotli.body, allocator)
}

// The variant Accept-Encoding selects among those that exist; identity otherwise.
representation_coding :: proc(request: ^Request, representation: ^Prepared_Representation) -> core.Content_Coding {
	available: bit_set[core.Content_Coding]

	if representation.brotli.body != nil {
		available += {.Brotli}
	}

	if representation.gzip.body != nil {
		available += {.Gzip}
	}

	if available == {} {
		return .Identity
	}

	return core.negotiate_coding(core.parse_accept_encoding(request.headers), available)
}

prepared_representation_response :: proc(request: ^Request, representation: ^Prepared_Representation) -> Response {
	assert(representation != nil)
	coding := representation_coding(request, representation)
	body := representation.body
	tag_bytes := representation.tag[:]

	switch coding {
	case .Brotli:
		body = representation.brotli.body
		tag_bytes = representation.brotli.tag[:representation.brotli.tag_len]
	case .Gzip:
		body = representation.gzip.body
		tag_bytes = representation.gzip.tag[:representation.gzip.tag_len]
	case .Identity:
	}

	tag, allocation_error := strings.clone(string(tag_bytes), request.allocator)
	if allocation_error != nil {
		return Response{status = .Internal_Server_Error}
	}

	// Another Accept-Encoding selects another representation of the same URL.
	varies := representation.gzip.body != nil || representation.brotli.body != nil
	fields: [5]Header
	count := 0
	response: Response

	if (request.method == "GET" || request.method == "HEAD") && not_modified(request, tag) {
		fields[0] = {"Cache-Control", "no-cache"}
		fields[1] = {"ETag", tag}
		count = 2

		if varies {
			fields[count] = {"Vary", "Accept-Encoding"}
			count += 1
		}

		response = make_response(request, .Not_Modified, fields[:count])
	} else {
		fields[0] = {"Content-Type", representation.content_type}
		fields[1] = {"Cache-Control", "no-cache"}
		fields[2] = {"ETag", tag}
		count = 3

		if coding != .Identity {
			fields[count] = {"Content-Encoding", core.content_coding_token(coding)}
			count += 1
		}

		if varies {
			fields[count] = {"Vary", "Accept-Encoding"}
			count += 1
		}

		response = make_response(request, .OK, fields[:count], body)
	}

	response.uncoded = representation.prepared

	return response
}

File_Stream_Config :: struct {
	// Zero selects 1 GiB per file and 64 KiB retained payload per response.
	max_file_bytes: i64,
	chunk_bytes:    int,
	timeout:        time.Duration,
	content_type:   string,
	// Optional strong tag for this immutable file generation, supplied by host.
	// The host must keep file contents stable through final stream disposal.
	etag:           string,
	// Must support individual frees and outlive the stream. Zero selects heap.
	allocator:      mem.Allocator,
}

// Opt-in rooted regular-file response, independent of startup-preloaded mounts.
// relative is decoded once here; private/dot paths and .jsx remain inaccessible.
// Returning a stream transfers its descriptor/buffer owner to core.serve.
serve_file_stream :: proc(request: ^Request, root, relative: string, config := File_Stream_Config{}) -> Response {
	if request.method != "GET" && request.method != "HEAD" {
		return make_response(request, .Method_Not_Allowed, {{"Allow", "GET, HEAD"}})
	}

	limit, chunk_bytes := config.max_file_bytes, config.chunk_bytes
	if limit == 0 {
		limit = 1024 * 1024 * 1024
	}
	if chunk_bytes == 0 {
		chunk_bytes = 64 * mem.Kilobyte
	}
	if limit < 0 ||
	   chunk_bytes < 1 ||
	   chunk_bytes > mem.Megabyte ||
	   config.timeout < 0 ||
	   len(config.etag) > 1024 ||
	   len(config.content_type) > 1024 ||
	   config.timeout > core.MAX_SERVER_TIMEOUT ||
	   (config.etag != "" && !file_strong_tag(config.etag)) {
		return {status = .Internal_Server_Error}
	}

	// Resolve through the same containment policy used by asset mounts.
	decoded, valid := file_relative_decode(relative, request.allocator)
	if !valid {
		return not_found(request)
	}
	canonical_root, root_error := filepath.abs(root, request.allocator)
	if root_error != nil {
		return not_found(request)
	}
	path, found, allowed := module_file(canonical_root, decoded, request.allocator)
	if !found || !allowed {
		return not_found(request)
	}
	file, open_error := os.open(path)
	if open_error != nil {
		return not_found(request)
	}
	transferred := false

	defer if !transferred {
		os.close(file)
	}

	info, stat_error := os.fstat(file, request.allocator)

	if stat_error != nil || info.type != .Regular || info.size < 0 || info.size > limit {
		return {status = .Internal_Server_Error}
	}

	tag := config.etag

	if tag != "" {
		allocation_error: mem.Allocator_Error
		tag, allocation_error = strings.clone(tag, request.allocator)
		if allocation_error != nil {
			return {status = .Internal_Server_Error}
		}
	}

	cache_policy := "no-store"
	if tag != "" {
		cache_policy = "no-cache"
	}

	if not_modified(request, tag) {
		if tag == "" {
			return make_response(request, .Not_Modified, {{"Cache-Control", cache_policy}})
		}
		return make_response(request, .Not_Modified, {{"ETag", tag}, {"Cache-Control", cache_policy}})
	}

	selection := file_request_range(request, info.size, tag)

	if selection.kind == .Unsatisfiable {
		value := fmt.aprintf("bytes */%d", info.size, allocator = request.allocator)
		if value == "" {
			return {status = .Internal_Server_Error}
		}
		return make_response(
			request,
			.Range_Not_Satisfiable,
			{{"Content-Range", value}, {"Accept-Ranges", "bytes"}, {"Cache-Control", cache_policy}},
		)
	}

	start, length := i64(0), info.size
	status: core.HTTP_Status = .OK

	if selection.kind == .Partial {
		start, length = selection.start, selection.length
		status = .Partial_Content
	}

	content_type := config.content_type
	if content_type == "" {
		content_type = asset_content_type(decoded)
	}
	type_error: mem.Allocator_Error
	content_type, type_error = strings.clone(content_type, request.allocator)
	if type_error != nil {
		return {status = .Internal_Server_Error}
	}
	headers: [6]Header
	headers[0] = {"Content-Type", content_type}
	headers[1] = {"Accept-Ranges", "bytes"}
	headers[2] = {"Cache-Control", cache_policy}
	count := 3

	if tag != "" {
		headers[count] = {"ETag", tag}
		count += 1
	}

	if status == .Partial_Content {
		value := fmt.aprintf("bytes %d-%d/%d", start, start + length - 1, info.size, allocator = request.allocator)
		if value == "" {
			return {status = .Internal_Server_Error}
		}
		headers[count] = {"Content-Range", value}
		count += 1
	}

	response := make_response(request, status, headers[:count])
	if response.status == .Internal_Server_Error {
		return response
	}
	allocator, binding, prepared := file_storage_allocator(request, config.allocator)
	if !prepared {
		return {status = .Internal_Server_Error}
	}
	producer, error := new(File_Producer, allocator)

	if error != nil || producer == nil {
		charged.release(&binding)
		return {status = .Internal_Server_Error}
	}

	producer^ = {
		file        = file,
		offset      = start,
		remaining   = length,
		chunk_bytes = chunk_bytes,
		allocator   = allocator,
		binding     = binding,
	}

	response.stream = {
		data            = producer,
		next            = file_next,
		drop            = file_drop,
		content_length  = length,
		max_chunk_bytes = chunk_bytes,
		max_body_bytes  = max(i64(1), length),
		timeout         = config.timeout,
	}

	transferred = true

	return response
}

File_Producer :: struct {
	binding:           charged.Binding,
	file:              ^os.File,
	offset, remaining: i64,
	chunk_bytes:       int,
	storage:           []u8,
	borrowed:          bool,
	allocator:         mem.Allocator,
}

file_release :: proc(_: []u8, data: rawptr) {
	producer := cast(^File_Producer)data
	assert(producer.borrowed)
	producer.borrowed = false
}

file_next :: proc(data: rawptr, io: ^core.Stream_IO) -> core.Stream_Step {
	producer := cast(^File_Producer)data
	assert(!producer.borrowed)
	if core.request_cancelled(io.cancellation) {
		return .Failed
	}
	if producer.remaining == 0 {
		return .Done
	}

	if len(producer.storage) == 0 {
		error: mem.Allocator_Error
		producer.storage, error = make(
			[]u8,
			int(min(i64(producer.chunk_bytes), producer.remaining)),
			producer.allocator,
		)
		if error != nil || len(producer.storage) == 0 {
			return .Failed
		}
	}

	count := int(min(i64(len(producer.storage)), producer.remaining))
	n, error := os.read_at(producer.file, producer.storage[:count], producer.offset)
	// A shortened file aborts the fixed-length response; it cannot authorize reuse.
	if error != nil || n != count {
		return .Failed
	}
	chunk := owned.Chunk {
		data      = producer.storage[:n],
		storage   = producer.storage,
		release   = file_release,
		user_data = producer,
	}

	producer.borrowed = true

	if core.stream_submit(io, &chunk, {allocator = producer.allocator}) != .Accepted {
		owned.destroy(&chunk)
		return .Failed
	}

	producer.offset += i64(n)
	producer.remaining -= i64(n)

	return .Chunk
}

file_drop :: proc(data: rawptr) {
	producer := cast(^File_Producer)data
	assert(!producer.borrowed)
	os.close(producer.file)
	delete(producer.storage, producer.allocator)
	allocator, binding := producer.allocator, producer.binding
	mem.free_with_size(producer, size_of(File_Producer), allocator)
	charged.release(&binding)
}

file_strong_tag :: proc(tag: string) -> bool {
	if len(tag) < 2 || tag[0] != '"' || tag[len(tag) - 1] != '"' {
		return false
	}

	for c in tag[1:len(tag) - 1] {
		if !(c == 0x21 || (c >= 0x23 && c <= 0x7e) || c >= 0x80) {
			return false
		}
	}

	return true
}

file_relative_decode :: proc(relative: string, allocator: mem.Allocator) -> (string, bool) {
	decoded, valid := net.percent_decode(relative, allocator)
	if !valid || !module_relative_ok(decoded) || strings.has_suffix(decoded, ".jsx") {
		return "", false
	}

	return decoded, true
}

// A lone `*` or a matching validator; any malformed If-None-Match field disables the match.
not_modified :: proc(request: ^Request, tag: string) -> bool {
	fields, stars := 0, 0
	matched, valid := false, true

	for field in request.headers {
		if !strings.equal_fold(field.name, "If-None-Match") {
			continue
		}
		fields += 1
		if strings.trim(field.value, " \t") == "*" {
			stars += 1
		}
		found, ok := http.if_none_match(field.value, tag)
		matched = matched || found
		valid = valid && ok
	}

	return matched && valid && (stars == 0 || fields == 1)
}

file_request_range :: proc(request: ^Request, size: i64, tag: string) -> http.Byte_Range {
	if request.method != "GET" {
		return {}
	}
	ranges, conditions := 0, 0
	value, condition: string

	for field in request.headers {
		if strings.equal_fold(field.name, "Range") {
			ranges += 1
			value = field.value
		}

		if strings.equal_fold(field.name, "If-Range") {
			conditions += 1
			condition = strings.trim(field.value, " \t")
		}
	}

	if ranges != 1 || conditions > 1 {
		return {}
	}
	// Dates/weak/malformed/unknown validators always fall back to a full 200.
	if conditions == 1 && (tag == "" || condition != tag) {
		return {}
	}

	return http.byte_range(value, size)
}

// The ordinary request arena cannot free individual producer allocations. Use
// its retained backing Binding, or wrap an explicit host backing allocator.
file_storage_allocator :: proc(
	request: ^Request,
	configured: mem.Allocator,
) -> (
	mem.Allocator,
	charged.Binding,
	bool,
) {
	managed := scope_managed(request.resources)
	if configured.procedure == nil {
		allocator := request.backing_allocator
		if allocator.procedure == nil {
			allocator = rt.heap_allocator()
		}
		return allocator, {}, true
	}
	if !managed {
		return configured, {}, true
	}
	if charged.is_managed_allocator(configured) {
		scope, valid := charged.allocator_scope(configured)
		return configured, {}, valid && budget.covers(scope, request.resources)
	}
	binding, error := charged.create(request.resources, {backing = configured})
	if error.kind != .None {
		return {}, {}, false
	}
	return charged.allocator(binding), binding, true
}

serve_file :: proc(request: ^Request, path: string, content_type := "text/html; charset=utf-8") -> Response {
	body, file_err := os.read_entire_file(path, request.allocator)

	if file_err != nil {
		log.error("Could not read file:", path, "| error:", file_err)
		return Response{status = .Internal_Server_Error}
	}

	return make_response(request, .OK, []Header{{"Content-Type", content_type}}, body)
}

Asset_Mount :: struct {
	directory, prefix: string,
}
// Preloaded bytes plus the ETag computed once at preload.
Asset_File :: Prepared_Representation
Asset_Cache :: struct {
	mount:          Asset_Mount,
	files:          map[string]Asset_File,
	// Effective limit also applies to development reads of changed/new files.
	max_file_bytes: int,
}
Asset_Limits :: struct {
	max_mounts, max_files, max_entries, max_file_bytes, max_total_bytes: int,
}
DEFAULT_ASSET_LIMITS :: Asset_Limits{16, 4096, 16384, 8 << 20, 64 << 20}
Asset_Error_Kind :: enum {
	None,
	Invalid_Limits,
	Mount_Limit,
	File_Limit,
	Entry_Limit,
	File_Bytes,
	Total_Bytes,
	Invalid_Mount,
	Unavailable,
	Outside_Mount,
	Allocation_Failed,
	Read_Failed,
}
Asset_Error :: struct {
	kind:                         Asset_Error_Kind,
	mount_index, limit, observed: int,
	read:                         Read_Error,
	io:                           os.Error,
	allocation:                   mem.Allocator_Error,
}

// Preserve the existing callable type; bounded defaults apply to old callers.
prepare_assets :: proc(mounts: []Asset_Mount, allocator: mem.Allocator) -> ([]Asset_Cache, bool) {
	caches, error := prepare_assets_bounded(mounts, {}, allocator)

	if error.kind != .None {
		log.errorf(
			"Asset preload failed: %v mount=%d limit=%d observed=%d",
			error.kind,
			error.mount_index,
			error.limit,
			error.observed,
		)
	}

	return caches, error.kind == .None
}

normalize_limits :: proc(l: Asset_Limits) -> (Asset_Limits, bool) {
	out := l

	if out.max_mounts == 0 {
		out.max_mounts = DEFAULT_ASSET_LIMITS.max_mounts
	}

	if out.max_files == 0 {
		out.max_files = DEFAULT_ASSET_LIMITS.max_files
	}

	if out.max_entries == 0 {
		out.max_entries = DEFAULT_ASSET_LIMITS.max_entries
	}

	if out.max_file_bytes == 0 {
		out.max_file_bytes = DEFAULT_ASSET_LIMITS.max_file_bytes
	}

	if out.max_total_bytes == 0 {
		out.max_total_bytes = DEFAULT_ASSET_LIMITS.max_total_bytes
	}

	return out,
		out.max_mounts > 0 &&
		out.max_files > 0 &&
		out.max_entries > 0 &&
		out.max_file_bytes > 0 &&
		out.max_file_bytes <= FILE_BYTES_MAX &&
		out.max_total_bytes > 0
}

// Returns one owning cache slice. No partially prepared output escapes failure.
prepare_assets_bounded :: proc(
	mounts: []Asset_Mount,
	limits: Asset_Limits,
	allocator: mem.Allocator,
) -> (
	[]Asset_Cache,
	Asset_Error,
) {
	l, valid := normalize_limits(limits)
	if !valid || allocator.procedure == nil {
		return nil, {kind = .Invalid_Limits}
	}
	if len(mounts) > l.max_mounts {
		return nil, {kind = .Mount_Limit, limit = l.max_mounts, observed = len(mounts)}
	}
	if len(mounts) > max(int) / size_of(Asset_Cache) {
		return nil, {kind = .Invalid_Limits}
	}
	caches, ae := make([]Asset_Cache, len(mounts), allocator)
	if ae != nil || (len(mounts) > 0 && raw_data(caches) == nil) {
		return nil, {kind = .Allocation_Failed, allocation = ae}
	}
	success := false
	defer if !success {
		destroy_assets(&caches, allocator)
	}
	counts: Asset_Counts
	for mount, index in mounts {
		error := preload_mount(&caches[index], mount, l, &counts, allocator)

		if error.kind != .None {
			error.mount_index = index
			return nil, error
		}
	}
	success = true
	return caches, {}
}

// Clear ownership before releasing storage; repeated teardown of this variable
// is harmless. Copies of owning caches are aliases, not additional owners.
destroy_assets :: proc(caches: ^[]Asset_Cache, allocator: mem.Allocator) {
	if caches == nil {
		return
	}

	old := caches^
	caches^ = nil

	for cache in old {
		for key, value in cache.files {
			delete(key, allocator)
			delete(value.body, allocator)
			destroy_encoded_representation(value, allocator)
		}

		delete(cache.files)
		delete(cache.mount.directory, allocator)
		delete(cache.mount.prefix, allocator)
	}

	delete(old, allocator)
}

Asset_Counts :: struct {
	files, entries, bytes: int,
}

preload_mount :: proc(
	cache: ^Asset_Cache,
	mount: Asset_Mount,
	l: Asset_Limits,
	counts: ^Asset_Counts,
	allocator: mem.Allocator,
) -> Asset_Error {
	if mount.directory == "" {
		return {kind = .Invalid_Mount}
	}
	prefix := mount.prefix
	if prefix == "" {
		prefix = "/assets/"
	}
	if len(prefix) < 3 ||
	   !strings.has_prefix(prefix, "/") ||
	   !strings.has_suffix(prefix, "/") ||
	   !module_relative_ok(prefix[1:len(prefix) - 1]) {
		return {kind = .Invalid_Mount}
	}
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	temporary := mem.dynamic_arena_allocator(&scratch)
	root, re := filepath.abs(mount.directory, temporary)
	if re != nil {
		return {kind = .Unavailable, io = re}
	}
	info, se := os.stat(root, temporary)
	if se != nil || info.type != .Directory {
		return {kind = .Unavailable, io = se}
	}
	owned_root, ae := strings.clone(root, allocator)
	if ae != nil || raw_data(owned_root) == nil {
		return {kind = .Allocation_Failed, allocation = ae}
	}
	cache.mount.directory = owned_root
	cache.mount.prefix, ae = strings.clone(prefix, allocator)
	if ae != nil || raw_data(cache.mount.prefix) == nil {
		return {kind = .Allocation_Failed, allocation = ae}
	}
	cache.max_file_bytes = l.max_file_bytes
	cache.files = make(map[string]Asset_File, allocator)
	// Keep iteration and File lifetimes together instead of depending on the
	// generic Walker's early-exit cleanup. Queued directory paths are bounded by
	// visited entries and destroyed even when a later file fails admission.
	pending: [dynamic]string
	pending.allocator = context.allocator
	defer {
		for path in pending {
			delete(path, pending.allocator)
		}

		delete(pending)
	}
	first, qe := strings.clone(cache.mount.directory, pending.allocator)
	if qe != nil {
		return {kind = .Allocation_Failed, allocation = qe}
	}
	if _, pe := append(&pending, first); pe != nil {
		delete(first, pending.allocator)
		return {kind = .Allocation_Failed, allocation = pe}
	}
	for head := 0; head < len(pending); head += 1 {
		error := preload_directory(cache, pending[head], &pending, l, counts, allocator, &scratch)
		delete(pending[head], pending.allocator)
		pending[head] = ""

		if error.kind != .None {
			return error
		}
	}

	return {}
}

preload_directory :: proc(
	cache: ^Asset_Cache,
	directory: string,
	pending: ^[dynamic]string,
	l: Asset_Limits,
	counts: ^Asset_Counts,
	allocator: mem.Allocator,
	scratch: ^mem.Dynamic_Arena,
) -> Asset_Error {
	handle, oe := os.open(directory)
	if oe != nil {
		return {kind = .Unavailable, io = oe}
	}
	defer os.close(handle)
	iterator := os.read_directory_iterator_create(handle)
	defer os.read_directory_iterator_destroy(&iterator)
	temporary := mem.dynamic_arena_allocator(scratch)
	for file in os.read_directory_iterator(&iterator) {
		_, ie := os.read_directory_iterator_error(&iterator)

		if ie != nil {
			return {kind = .Unavailable, io = ie}
		}

		counts.entries += 1

		if counts.entries > l.max_entries {
			return {kind = .Entry_Limit, limit = l.max_entries, observed = counts.entries}
		}

		if file.type == .Directory {
			path, ce := strings.clone(file.fullpath, pending.allocator)

			if ce != nil {
				return {kind = .Allocation_Failed, allocation = ce}
			}

			if _, ae := append(pending, path); ae != nil {
				delete(path, pending.allocator)
				return {kind = .Allocation_Failed, allocation = ae}
			}

			continue
		}

		if file.type != .Regular {
			continue
		}

		relative := file.fullpath[len(cache.mount.directory) + 1:]

		if !module_relative_ok(relative) || strings.has_suffix(relative, ".jsx") {
			continue
		}

		if counts.files == l.max_files {
			return {kind = .File_Limit, limit = l.max_files, observed = counts.files + 1}
		}

		mem.dynamic_arena_free_all(scratch)
		path, found, allowed := module_file(cache.mount.directory, relative, temporary)

		if !allowed {
			return {kind = .Outside_Mount}
		}

		if !found {
			return {kind = .Unavailable}
		}

		// Directory mutation must not replace an existing owner and leak its body.
		if _, duplicate := cache.files[relative]; duplicate {
			return {kind = .Unavailable}
		}

		remaining := l.max_total_bytes - counts.bytes
		body, read := read_limited(path, max(1, min(l.max_file_bytes, remaining)), allocator)

		if read.kind != .None {
			if read.kind == .Limit_Exceeded {
				if remaining < l.max_file_bytes {
					return {
						kind = .Total_Bytes,
						limit = l.max_total_bytes,
						observed = l.max_total_bytes + int(l.max_total_bytes < max(int)),
						read = read,
					}
				}

				return {kind = .File_Bytes, limit = l.max_file_bytes, observed = l.max_file_bytes + 1, read = read}
			}

			if read.kind == .Allocation_Failed {
				return {kind = .Allocation_Failed, read = read}
			}

			return {kind = .Read_Failed, read = read}
		}

		if len(body) > remaining {
			delete(body, allocator)
			return {
				kind = .Total_Bytes,
				limit = l.max_total_bytes,
				observed = counts.bytes + min(len(body), max(int) - counts.bytes),
			}
		}

		key, ke := strings.clone(relative, allocator)

		if ke != nil || raw_data(key) == nil {
			delete(body, allocator)
			return {kind = .Allocation_Failed, allocation = ke}
		}

		if len(cache.files) > max(int) / 2 - 1 {
			delete(key, allocator)
			delete(body, allocator)
			return {kind = .File_Limit, limit = l.max_files, observed = len(cache.files)}
		}

		if me := reserve(&cache.files, 2 * (len(cache.files) + 1)); me != nil {
			delete(key, allocator)
			delete(body, allocator)
			return {kind = .Allocation_Failed, allocation = me}
		}

		prepared, extra := prepare_encoded_representation(
			body,
			asset_content_type(relative),
			allocator,
			remaining - len(body),
		)
		inserted, me := map_insert(&cache.files, key, prepared)

		if me != nil || inserted == nil {
			destroy_encoded_representation(prepared, allocator)
			delete(key, allocator)
			delete(body, allocator)
			return {kind = .Allocation_Failed, allocation = me}
		}

		counts.files += 1
		counts.bytes += len(body) + extra
	}
	_, ie := os.read_directory_iterator_error(&iterator)
	if ie != nil {
		return {kind = .Unavailable, io = ie}
	}
	return {}
}

Request :: core.Request
Response :: core.Response
Header :: core.Header
make_response :: core.make_response
not_found :: core.not_found

// A scope is managed when it names a live budget node. Replace with
// budget.managed once core:sync/budget exports it.
scope_managed :: proc(scope: budget.Scope) -> bool {
	return budget.same_scope(scope, scope)
}
