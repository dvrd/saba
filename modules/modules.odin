package saba_modules

import assets "../assets"
import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"
import jsx "../jsx"
import "core:mem"
import core "../core"

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
	javascript, has_javascript, javascript_allowed := module_file(root, relative, request.allocator)
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
	body, read_error := os.read_entire_file(javascript, request.allocator)
	if read_error != nil do return Response{status = .Internal_Server_Error}, true
	return assets.representation_response(request, body, "text/javascript; charset=utf-8", development), true
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

	return assets.representation_response(request, transmute([]u8)output, "text/javascript; charset=utf-8", true)
}

// One mount can expose a whole web root or a component subtree.
Module_Mount :: struct {
	directory: string,
	prefix:    string,
}

Module_Cache :: struct {
	mount: Module_Mount,
	files: map[string]assets.Prepared_Representation,
}

serve_prepared_modules :: proc(request: ^Request, mounts: []Module_Cache, development: bool) -> (Response, bool) {
	for mount in mounts {
		if development {
			if response, matched := serve_modules(request, mount.mount.directory, mount.mount.prefix, true); matched do return response, true
			continue
		}

		relative, invalid, matched := module_request(request, mount.mount.prefix)
		if !matched do continue
		if invalid do return not_found(request), true
		prepared, found := mount.files[relative]
		if !found do return not_found(request), true
		return assets.prepared_representation_response(request, &prepared), true
	}

	return {}, false
}

@(private = "file")
module_request :: proc(request: ^Request, prefix: string) -> (path: string, invalid, matched: bool) {
	if (request.method != "GET" && request.method != "HEAD") ||
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

JSX_RUNTIME_URL :: jsx.JSX_RUNTIME_URL
JSX_RUNTIME :: #load("dom.js", string)

jsx_runtime_response :: proc(request: ^Request) -> Response {
	return assets.representation_response(request, transmute([]u8)JSX_RUNTIME, "text/javascript; charset=utf-8")
}

PAGE_ENTRY_URL :: "/__saba/page-entry.js"
PAGE_ENTRY :: #load("page-entry.js", string)

page_entry_response :: proc(request: ^Request) -> Response {
	return assets.representation_response(request, transmute([]u8)PAGE_ENTRY, "text/javascript; charset=utf-8")
}

// Server-owned memory keeps compiled modules alive through the final response.
// Nothing is written into the source tree or published until every mount succeeds.
prepare_module_mounts :: proc(
	mounts: []Module_Mount,
	development: bool,
	allocator: mem.Allocator,
) -> (
	[]Module_Cache,
	bool,
) {
	prepared, allocation_error := make([]Module_Cache, len(mounts), allocator)
	if allocation_error != nil {
		log.error("Could not allocate module mounts")
		return nil, false
	}
	for mount, index in mounts {
		prefix := mount.prefix
		if prefix == "" do prefix = "/"

		if !strings.has_prefix(prefix, "/") || !strings.has_suffix(prefix, "/") {
			log.errorf("Module prefix must start and end with /: %s", prefix)
			return nil, false
		}

		root, error := filepath.abs(mount.directory, allocator)

		if error != nil {
			log.errorf("Could not resolve module directory %s: %v", mount.directory, error)
			return nil, false
		}

		info, stat_error := os.stat(root, allocator)

		if stat_error != nil || info.type != .Directory {
			log.errorf("Module directory is unavailable: %s", mount.directory)
			return nil, false
		}

		owned_prefix, clone_error := strings.clone(prefix, allocator)

		if clone_error != nil {
			log.error("Could not copy module prefix")
			return nil, false
		}

		prepared[index].mount = {root, owned_prefix}
		if !development && !compile_module_directory(&prepared[index], allocator) do return nil, false
	}
	return prepared, true
}

@(private = "file")
compile_module_directory :: proc(cache: ^Module_Cache, allocator: mem.Allocator) -> bool {
	root := cache.mount.directory
	cache.files = make(map[string]assets.Prepared_Representation, allocator)
	walker := os.walker_create(root)
	defer os.walker_destroy(&walker)

	for file in os.walker_walk(&walker) {
		if file.type != .Regular do continue
		relative := file.fullpath[len(root) + 1:]
		is_jsx := strings.has_suffix(relative, ".jsx")
		if (!is_jsx && !strings.has_suffix(relative, ".js")) || !module_relative_ok(relative) do continue
		resolved, found, allowed := module_file(root, relative, allocator)

		if !found || !allowed {
			log.errorf("Module file is unavailable or escapes its directory: %s", relative)
			return false
		}

		url := relative
		if is_jsx do url = fmt.aprintf("%s.js", relative[:len(relative) - 4], allocator = allocator)

		if _, collision := cache.files[url]; collision {
			log.errorf("JSX output collides with an existing JavaScript file: %s", url)
			return false
		}

		source, read_error := os.read_entire_file(resolved, allocator)

		if read_error != nil {
			log.errorf("Could not read module %s: %v", resolved, read_error)
			return false
		}

		output := string(source)

		if is_jsx {
			javascript, transform_error := transform_jsx(output, resolved, allocator)

			if transform_error.message != "" {
				log.errorf(
					"%s:%d:%d: %s",
					transform_error.file,
					transform_error.line,
					transform_error.column,
					transform_error.message,
				)
				return false
			}

			output = javascript
		}

		key, key_error := strings.clone(url, allocator)

		if key_error != nil {
			log.error("Could not copy module URL")
			return false
		}

		cache.files[key] = assets.prepare_representation(transmute([]u8)output, "text/javascript; charset=utf-8")
	}

	if path, error := os.walker_error(&walker); error != nil {
		log.errorf("Could not scan module directory %s: %v", path, error)
		return false
	}

	return true
}

transform_jsx :: jsx.transform_jsx

Request :: core.Request
Response :: core.Response
make_response :: core.make_response
not_found :: core.not_found
