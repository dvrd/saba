package server

import "core:log"
import "core:mem"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"

Asset_Mount :: struct {
	directory: string,
	prefix:    string,
}

Asset_File :: struct {
	body:         []u8,
	content_type: string,
}

Asset_Cache :: struct {
	mount: Asset_Mount,
	files: map[string]Asset_File,
}

// Preload bytes before listening; the server owns them until all workers finish.
prepare_assets :: proc(mounts: []Asset_Mount, allocator: mem.Allocator) -> ([]Asset_Cache, bool) {
	caches, allocation_error := make([]Asset_Cache, len(mounts), allocator)
	if allocation_error != nil {log.error("Could not allocate asset mounts");return nil, false}
	for mount, index in mounts {
		if mount.directory == "" {log.error("Asset directory is required");return nil, false}
		prefix := mount.prefix
		if prefix == "" do prefix = "/assets/"
		if len(prefix) < 3 ||
		   !strings.has_prefix(prefix, "/") ||
		   !strings.has_suffix(prefix, "/") ||
		   !module_relative_ok(prefix[1:len(prefix) - 1]) {
			log.errorf("Invalid asset prefix: %s", prefix)
			return nil, false
		}
		root, root_error := filepath.abs(mount.directory, allocator)
		if root_error != nil {log.error("Could not resolve asset directory");return nil, false}
		info, stat_error := os.stat(root, allocator)
		if stat_error != nil ||
		   info.type !=
			   .Directory {log.errorf("Asset directory is unavailable: %s", mount.directory);return nil, false}
		owned_prefix, clone_error := strings.clone(prefix, allocator)
		if clone_error != nil {log.error("Could not copy asset prefix");return nil, false}
		cache := &caches[index]
		cache.mount = {root, owned_prefix}
		cache.files = make(map[string]Asset_File, allocator)
		walker := os.walker_create(root)
		for file in os.walker_walk(&walker) {
			if file.type != .Regular do continue
			relative := file.fullpath[len(root) + 1:]
			if !module_relative_ok(relative) || strings.has_suffix(relative, ".jsx") do continue
			path, found, allowed := module_file(root, relative, allocator)
			if !found || !allowed {
				os.walker_destroy(&walker)
				log.errorf("Asset file is unavailable or escapes its directory: %s", relative)
				return nil, false
			}
			body, read_error := os.read_entire_file(path, allocator)
			if read_error != nil {
				os.walker_destroy(&walker)
				log.errorf("Could not preload asset: %s", path)
				return nil, false
			}
			key, key_error := strings.clone(relative, allocator)
			if key_error !=
			   nil {os.walker_destroy(&walker);log.error("Could not copy asset path");return nil, false}
			cache.files[key] = {body, asset_content_type(relative)}
		}
		_, walk_error := os.walker_error(&walker)
		os.walker_destroy(&walker)
		if walk_error !=
		   nil {log.errorf("Could not scan asset directory: %s", root);return nil, false}
	}
	return caches, true
}

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
	if request.method != "GET" do return {}, false
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
			body, read_error := os.read_entire_file(path, request.allocator)
			if read_error !=
			   nil {log.errorf("Could not read asset: %s", path);return Response{status = .Internal_Server_Error}, true}
			file = {body, asset_content_type(relative)}
		} else {
			cached, found := cache.files[relative]
			if !found do return not_found(request), true
			file = cached
		}
		return make_response(request, .OK, {{"Content-Type", file.content_type}}, file.body), true
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
