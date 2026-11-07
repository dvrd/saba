package saba_assets

import "core:log"
import "core:net"
import "core:path/filepath"
import "core:strings"
import files "shared:files"

// Configured mounts own their URL prefix. Development reads current files so
// edits and additions work with hot reload; production serves only preloaded data.
serve_assets :: proc(
	request: ^Request,
	caches: []Asset_Cache,
	development := false,
) -> (
	Response,
	bool,
) {
	if request.method != "GET" && request.method != "HEAD" do return {}, false
	for cache in caches {
		if !strings.has_prefix(request.path, cache.mount.prefix) do continue
		relative, decoded := net.percent_decode(
			request.path[len(cache.mount.prefix):],
			request.allocator,
		)
		if !decoded || !module_relative_ok(relative) || strings.has_suffix(relative, ".jsx") do return not_found(request), true
		file: Asset_File
		if development {
			path, found, allowed := module_file(cache.mount.directory, relative, request.allocator)
			if !found || !allowed do return not_found(request), true
			limit := cache.max_file_bytes
			if limit == 0 {
				limit = DEFAULT_ASSET_LIMITS.max_file_bytes
			}
			body, read_error := files.read_limited(path, limit, request.allocator)
			if read_error.kind != .None {
				log.errorf("Could not read asset: %s", path)
				return Response{status = .Internal_Server_Error}, true
			}
			file = {body, asset_content_type(relative)}
		} else {
			cached, found := cache.files[relative]
			if !found do return not_found(request), true
			file = cached
		}
		return representation_response(request, file.body, file.content_type, development), true
	}
	return {}, false
}

@(private)
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
		if strings.equal_fold(extension, item[0]) do return item[1]
	}
	return "application/octet-stream"
}
