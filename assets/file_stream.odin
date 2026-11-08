package saba_assets

import core "../core"
import http "../../http"
import rt "base:runtime"
import "core:fmt"
import "core:mem"
import charged "core:mem/budget"
import budget "core:sync/budget"
import owned "core:mem/owned"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

File_Stream_Config :: struct {
	// Zero selects 1 GiB per file and 64 KiB retained payload per response.
	max_file_bytes: i64,
	chunk_bytes: int,
	timeout: time.Duration,
	content_type: string,
	// Optional strong tag for this immutable file generation, supplied by host.
	// The host must keep file contents stable through final stream disposal.
	etag: string,
	// Must support individual frees and outlive the stream. Zero selects heap.
	allocator: mem.Allocator,
}

// Opt-in rooted regular-file response, independent of startup-preloaded mounts.
// relative is decoded once here; private/dot paths and .jsx remain inaccessible.
// Returning a stream transfers its descriptor/buffer owner to core.serve.
serve_file_stream :: proc(request: ^Request, root, relative: string, config := File_Stream_Config{}) -> Response {
	if request.method != "GET" && request.method != "HEAD" {
		return make_response(request, .Method_Not_Allowed, {{"Allow", "GET, HEAD"}})
	}
	limit, chunk_bytes := config.max_file_bytes, config.chunk_bytes
	if limit == 0 do limit = 1024*1024*1024
	if chunk_bytes == 0 do chunk_bytes = 64*mem.Kilobyte
	if limit < 0 || chunk_bytes < 1 || chunk_bytes > mem.Megabyte || config.timeout < 0 ||
	   len(config.etag) > 1024 || len(config.content_type) > 1024 ||
	   config.timeout > core.MAX_SERVER_TIMEOUT || (config.etag != "" && !file_strong_tag(config.etag)) {
		return {status=.Internal_Server_Error}
	}
	// Resolve through the same containment policy used by asset mounts.
	decoded, valid := file_relative_decode(relative, request.allocator)
	if !valid do return not_found(request)
	canonical_root, root_error := filepath.abs(root, request.allocator)
	if root_error != nil do return not_found(request)
	path, found, allowed := module_file(canonical_root, decoded, request.allocator)
	if !found || !allowed do return not_found(request)
	file, open_error := os.open(path)
	if open_error != nil do return not_found(request)
	transferred := false
	defer if !transferred {os.close(file)}
	info, stat_error := os.fstat(file, request.allocator)
	if stat_error != nil || info.type != .Regular || info.size < 0 || info.size > limit {
		return {status=.Internal_Server_Error}
	}
	tag := config.etag
	if tag != "" {
		allocation_error: mem.Allocator_Error
		tag, allocation_error = strings.clone(tag, request.allocator)
		if allocation_error != nil do return {status=.Internal_Server_Error}
	}
	cache_policy := "no-store"
	if tag != "" do cache_policy = "no-cache"
	if file_not_modified(request, tag) {
		if tag == "" do return make_response(request, .Not_Modified, {{"Cache-Control", cache_policy}})
		return make_response(request, .Not_Modified, {{"ETag", tag}, {"Cache-Control", cache_policy}})
	}
	selection := file_request_range(request, info.size, tag)
	if selection.kind == .Unsatisfiable {
		value := fmt.aprintf("bytes */%d", info.size, allocator=request.allocator)
		if value == "" do return {status=.Internal_Server_Error}
		response := make_response(request, .Range_Not_Satisfiable,
			{{"Content-Range", value}, {"Accept-Ranges", "bytes"}, {"Cache-Control", cache_policy}})
		return response
	}
	start, length := i64(0), info.size
	status: core.HTTP_Status = .OK
	if selection.kind == .Partial {
		start, length = selection.start, selection.length
		status = .Partial_Content
	}
	content_type := config.content_type
	if content_type == "" do content_type = asset_content_type(decoded)
	type_error: mem.Allocator_Error
	content_type, type_error = strings.clone(content_type, request.allocator)
	if type_error != nil do return {status=.Internal_Server_Error}
	headers: [6]Header
	headers[0] = {"Content-Type", content_type}
	headers[1] = {"Accept-Ranges", "bytes"}
	headers[2] = {"Cache-Control", cache_policy}
	count := 3
	if tag != "" {headers[count] = {"ETag", tag}; count += 1}
	if status == .Partial_Content {
		value := fmt.aprintf("bytes %d-%d/%d", start, start+length-1, info.size, allocator=request.allocator)
		if value == "" do return {status=.Internal_Server_Error}
		headers[count] = {"Content-Range", value}; count += 1
	}
	response := make_response(request, status, headers[:count])
	if response.status == .Internal_Server_Error do return response
	allocator, binding, prepared := file_storage_allocator(request, config.allocator)
	if !prepared do return {status=.Internal_Server_Error}
	producer, error := new(File_Producer, allocator)
	if error != nil || producer == nil {
		charged.release(&binding); return {status=.Internal_Server_Error}
	}
	producer^ = {file=file, offset=start, remaining=length, chunk_bytes=chunk_bytes,
		allocator=allocator, binding=binding}
	response.stream = {
		data=producer, next=file_next, drop=file_drop, content_length=length,
		max_chunk_bytes=chunk_bytes, max_body_bytes=max(i64(1), length), timeout=config.timeout,
	}
	transferred = true
	return response
}

@(private)
File_Producer :: struct {
	binding: charged.Binding,
	file: ^os.File,
	offset, remaining: i64,
	chunk_bytes: int,
	storage: []u8,
	borrowed: bool,
	allocator: mem.Allocator,
}

@(private)
file_release :: proc(_: []u8, data: rawptr) {
	producer := cast(^File_Producer)data
	assert(producer.borrowed)
	producer.borrowed = false
}

@(private)
file_next :: proc(data: rawptr, io: ^core.Stream_IO) -> core.Stream_Step {
	producer := cast(^File_Producer)data
	assert(!producer.borrowed)
	if core.request_cancelled(io.cancellation) do return .Failed
	if producer.remaining == 0 do return .Done
	if len(producer.storage) == 0 {
		error: mem.Allocator_Error
		producer.storage, error = make([]u8, int(min(i64(producer.chunk_bytes), producer.remaining)), producer.allocator)
		if error != nil || len(producer.storage) == 0 do return .Failed
	}
	count := int(min(i64(len(producer.storage)), producer.remaining))
	n, error := os.read_at(producer.file, producer.storage[:count], producer.offset)
	// A shortened file aborts the fixed-length response; it cannot authorize reuse.
	if error != nil || n != count do return .Failed
	chunk := owned.Chunk{data=producer.storage[:n], storage=producer.storage, release=file_release, user_data=producer}
	producer.borrowed = true
	if core.stream_submit_backing(io, &chunk, {allocator=producer.allocator}) != .Accepted {
		owned.destroy(&chunk)
		return .Failed
	}
	producer.offset += i64(n); producer.remaining -= i64(n)
	return .Chunk
}

@(private)
file_drop :: proc(data: rawptr) {
	producer := cast(^File_Producer)data
	assert(!producer.borrowed)
	os.close(producer.file)
	delete(producer.storage, producer.allocator)
	allocator, binding := producer.allocator, producer.binding
	mem.free_with_size(producer, size_of(File_Producer), allocator)
	charged.release(&binding)
}

@(private)
file_strong_tag :: proc(tag: string) -> bool {
	if len(tag) < 2 || tag[0] != '"' || tag[len(tag)-1] != '"' do return false
	for c in tag[1:len(tag)-1] {
		if !(c == 0x21 || (c >= 0x23 && c <= 0x7e) || c >= 0x80) do return false
	}
	return true
}

@(private)
file_relative_decode :: proc(relative: string, allocator: mem.Allocator) -> (string, bool) {
	decoded, valid := net.percent_decode(relative, allocator)
	if !valid || !module_relative_ok(decoded) || strings.has_suffix(decoded, ".jsx") do return "", false
	return decoded, true
}

@(private)
file_not_modified :: proc(request: ^Request, tag: string) -> bool {
	fields, stars := 0, 0
	matched, valid := false, true
	for field in request.headers {
		if !strings.equal_fold(field.name, "If-None-Match") do continue
		fields += 1
		if strings.trim(field.value, " \t") == "*" do stars += 1
		found, ok := http.if_none_match(field.value, tag)
		matched = matched || found; valid = valid && ok
	}
	return matched && valid && (stars == 0 || fields == 1)
}

@(private)
file_request_range :: proc(request: ^Request, size: i64, tag: string) -> http.Byte_Range {
	if request.method != "GET" do return {}
	ranges, conditions := 0, 0
	value, condition: string
	for field in request.headers {
		if strings.equal_fold(field.name, "Range") {ranges += 1; value = field.value}
		if strings.equal_fold(field.name, "If-Range") {conditions += 1; condition = strings.trim(field.value, " \t")}
	}
	if ranges != 1 || conditions > 1 do return {}
	// Dates/weak/malformed/unknown validators always fall back to a full 200.
	if conditions == 1 && (tag == "" || condition != tag) do return {}
	return http.byte_range(value, size)
}

// The ordinary request arena cannot free individual producer allocations. Use
// its retained backing Binding, or wrap an explicit host backing allocator.
@(private)
file_storage_allocator :: proc(
	request: ^Request, configured: mem.Allocator,
) -> (mem.Allocator, charged.Binding, bool) {
	managed := budget.same_scope(request.resources, request.resources)
	if configured.procedure == nil {
		allocator := request.backing_allocator
		if allocator.procedure == nil do allocator = rt.heap_allocator()
		return allocator, {}, true
	}
	if !managed do return configured, {}, true
	if charged.is_managed_allocator(configured) {
		scope, valid := charged.allocator_scope(configured)
		return configured, {}, valid && budget.covers(scope, request.resources)
	}
	binding, error := charged.create(request.resources, {backing=configured})
	if error.kind != .None do return {}, {}, false
	return charged.allocator(binding), binding, true
}
