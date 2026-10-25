package server

import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Mounts an entire module directory. Development transforms JSX on request;
// production file-only callers may serve already generated JavaScript. Server
// module mounts use the startup cache for production JSX automatically.
// matched is false for requests outside the mount or for non-module assets.
serve_modules :: proc(
	request: ^Request,
	directory: string,
	prefix := "/",
	development := false,
) -> (
	response: Response,
	matched: bool,
) {
	relative, response_error, module_matched := module_request(request, prefix)
	if !module_matched do return {}, false
	if response_error do return not_found(request), true
	root, root_error := filepath.abs(directory, request.allocator)
	if root_error != nil {
		log.errorf("Could not resolve module directory %s: %v", directory, root_error)
		return Response{status = .Internal_Server_Error}, true
	}
	javascript, has_javascript, javascript_allowed := module_file(
		root,
		relative,
		request.allocator,
	)
	if !javascript_allowed do return not_found(request), true
	if development {
		source, has_source, source_allowed := module_file(
			root,
			fmt.tprintf("%s.jsx", relative[:len(relative) - len(".js")]),
			request.allocator,
		)
		if !source_allowed do return not_found(request), true
		if has_source && has_javascript {
			log.errorf("JSX output collides with an existing JavaScript file: %s", relative)
			return Response{status = .Internal_Server_Error}, true
		}
		if has_source do return serve_jsx(request, source), true
	}
	if !has_javascript do return not_found(request), true
	return serve_file(request, javascript, "text/javascript; charset=utf-8"), true
}

// Resolve links before reading so a directory mount cannot expose files outside
// its root. The returned path and stat storage belong to the request allocator.
module_file :: proc(
	root, relative: string,
	allocator: mem.Allocator,
) -> (
	path: string,
	found, allowed: bool,
) {
	resolved, error := filepath.abs(fmt.tprintf("%s/%s", root, relative), allocator)
	if error != nil do return "", false, true
	if !strings.has_prefix(resolved, fmt.tprintf("%s/", strings.trim_right(root, "/"))) do return "", false, false
	info, stat_error := os.stat(resolved, allocator)
	return resolved, stat_error == nil && info.type == .Regular, true
}

@(private = "file")
serve_jsx :: proc(request: ^Request, source_path: string) -> Response {
	source, read_error := os.read_entire_file(source_path, request.allocator)
	if read_error != nil {
		log.errorf("Could not read JSX module %s: %v", source_path, read_error)
		return Response{status = .Internal_Server_Error}
	}
	output, error := transform_jsx(string(source), source_path, request.allocator)
	if error.message != "" {
		message := fmt.tprintf("%s:%d:%d: %s", error.file, error.line, error.column, error.message)
		log.error(message)
		return make_response(
			request,
			.Internal_Server_Error,
			{{"Content-Type", "text/plain; charset=utf-8"}, {"Cache-Control", "no-store"}},
			transmute([]u8)message,
		)
	}
	return make_response(
		request,
		.OK,
		{{"Content-Type", "text/javascript; charset=utf-8"}, {"Cache-Control", "no-store"}},
		transmute([]u8)output,
	)
}

// One mount can expose a whole web root or a component subtree.
Module_Mount :: struct {
	directory: string,
	prefix:    string,
}

Module_Cache :: struct {
	mount: Module_Mount,
	files: map[string]string,
}

serve_prepared_modules :: proc(
	request: ^Request,
	mounts: []Module_Cache,
	development: bool,
) -> (
	Response,
	bool,
) {
	for mount in mounts {
		if development {
			if response, matched := serve_modules(request, mount.mount.directory, mount.mount.prefix, true); matched do return response, true
			continue
		}
		relative, invalid, matched := module_request(request, mount.mount.prefix)
		if !matched do continue
		if invalid do return not_found(request), true
		output, found := mount.files[relative]
		if !found do return not_found(request), true
		return make_response(
				request,
				.OK,
				{
					{"Content-Type", "text/javascript; charset=utf-8"},
					{"Cache-Control", "no-cache"},
				},
				transmute([]u8)output,
			),
			true
	}
	return {}, false
}

@(private = "file")
module_request :: proc(
	request: ^Request,
	prefix: string,
) -> (
	path: string,
	invalid, matched: bool,
) {
	if request.method != "GET" ||
	   !strings.has_prefix(prefix, "/") ||
	   !strings.has_suffix(prefix, "/") ||
	   !strings.has_prefix(request.path, prefix) {
		return
	}
	relative, decoded := net.percent_decode(request.path[len(prefix):], request.allocator)
	if !decoded do return "", true, true
	if !strings.has_suffix(relative, ".js") && !strings.has_suffix(relative, ".jsx") do return "", false, false
	if strings.has_suffix(relative, ".jsx") || !module_relative_ok(relative) do return "", true, true
	return relative, false, true
}

module_relative_ok :: proc(relative: string) -> bool {
	for c in relative {
		if c < 32 || c == 127 || c == '\\' || c == ':' do return false
	}
	remaining := relative
	for segment in strings.split_iterator(&remaining, "/") {
		if segment == "" || strings.has_prefix(segment, ".") do return false
	}
	return true
}
