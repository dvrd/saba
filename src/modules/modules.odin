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
import rt "base:runtime"
import "core:sync"

// Mounts an entire module directory. Development transforms JSX on request;
// production file-only callers may serve already generated JavaScript. Server
// module mounts use the startup cache for production JSX automatically.
// matched is false for requests outside the mount or for non-module assets.
serve_modules :: proc(
	request: ^Request,
	directory: string,
	prefix := "/",
	development := false,
	exclude: []string = nil,
) -> (
	response: Response,
	matched: bool,
) {
	relative, response_error, module_matched := module_request(request, prefix)
	if !module_matched {
		return {}, false
	}
	if response_error || module_excluded(exclude, relative) {
		return not_found(request), true
	}
	root, root_error := root_directory(directory, request.allocator)
	if root_error != nil {
		log.errorf("Could not resolve module directory %s: %v", directory, root_error)
		return Response{status = .Internal_Server_Error}, true
	}
	return read_module(request, root, relative, development), true
}

read_module :: proc(request: ^Request, root, relative: string, development: bool) -> Response {
	javascript, has_javascript, javascript_allowed := module_file(root, relative, request.allocator)
	if !javascript_allowed {
		return not_found(request)
	}
	if development {
		source, has_source, source_allowed := module_file(
			root,
			fmt.tprintf("%s.jsx", relative[:len(relative) - len(".js")]),
			request.allocator,
		)
		if !source_allowed {
			return not_found(request)
		}

		if has_source && has_javascript {
			log.errorf("JSX output collides with an existing JavaScript file: %s", relative)
			return Response{status = .Internal_Server_Error}
		}

		if has_source {
			// The client sees the mount-relative name; the log keeps the full path.
			return serve_jsx(request, source, fmt.tprintf("%s.jsx", relative[:len(relative) - len(".js")]))
		}
	}
	if !has_javascript {
		return not_found(request)
	}
	body, read := assets.read_limited(javascript, assets.DEFAULT_ASSET_LIMITS.max_file_bytes, request.allocator)
	if read.kind != .None {
		log.errorf("Could not read module %s: %v %v", javascript, read.kind, read.io)
		return Response{status = .Internal_Server_Error}
	}
	return assets.representation_response(request, body, "text/javascript; charset=utf-8", development)
}

// `display` names the source in the diagnostic sent to the browser. It defaults
// to the file's base name so a filesystem layout never reaches a client.
serve_jsx :: proc(request: ^Request, source_path: string, display := "") -> Response {
	source, read := assets.read_limited(source_path, assets.DEFAULT_ASSET_LIMITS.max_file_bytes, request.allocator)

	if read.kind != .None {
		log.errorf("Could not read JSX module %s: %v %v", source_path, read.kind, read.io)
		return Response{status = .Internal_Server_Error}
	}

	output, error := transform_jsx(string(source), source_path, request.allocator)

	if error.message != "" {
		shown := display
		if shown == "" {
			shown = filepath.base(source_path)
		}
		log.errorf("%s:%d:%d: %s", error.file, error.line, error.column, error.message)
		message := fmt.aprintf("%s:%d:%d: %s", shown, error.line, error.column, error.message, allocator = request.allocator)
		return make_response(
			request,
			.Internal_Server_Error,
			{{"Content-Type", "text/plain; charset=utf-8"}, {"Cache-Control", "no-store"}, assets.NOSNIFF},
			transmute([]u8)message,
		)
	}

	return assets.representation_response(request, transmute([]u8)output, "text/javascript; charset=utf-8", true)
}

// One mount can expose a whole web root or a component subtree.
Module_Mount :: struct {
	directory: string,
	prefix:    string,
	// Mount-relative files or directories that are not browser modules, for
	// example "server" or "tools/build.js". They are neither compiled nor served.
	exclude:   []string,
}

module_excluded :: proc(exclude: []string, relative: string) -> bool {
	for entry in exclude {
		name := strings.trim(entry, "/")
		if name == "" {
			continue
		}
		// Case-insensitive volumes resolve `Server/x.js` to `server/x.js`, so names
		// are compared without regard to case, as jsx_source does for suffixes.
		if strings.equal_fold(relative, name) ||
		   (len(relative) > len(name) && strings.equal_fold(relative[:len(name)], name) && relative[len(name)] == '/') {
			return true
		}
		// A compiled component is addressed as .js and stored as .jsx.
		if len(name) >= 4 &&
		   len(relative) >= 3 &&
		   strings.equal_fold(name[len(name) - 4:], ".jsx") &&
		   strings.equal_fold(relative[len(relative) - 3:], ".js") &&
		   strings.equal_fold(relative[:len(relative) - 3], name[:len(name) - 4]) {
			return true
		}
	}
	return false
}

Module_Cache :: struct {
	mount: Module_Mount,
	files: map[string]assets.Prepared_Representation,
}

serve_prepared_modules :: proc(request: ^Request, mounts: []Module_Cache, development: bool) -> (Response, bool) {
	for mount in mounts {
		if development {
			if response, matched := serve_modules(request, mount.mount.directory, mount.mount.prefix, true, mount.mount.exclude); matched {
				return response, true
			}
			continue
		}

		relative, invalid, matched := module_request(request, mount.mount.prefix)
		if !matched {
			continue
		}
		if invalid {
			return not_found(request), true
		}
		prepared, found := mount.files[relative]
		if !found {
			return not_found(request), true
		}
		return assets.prepared_representation_response(request, &prepared), true
	}

	return {}, false
}

module_request :: proc(request: ^Request, prefix: string) -> (path: string, invalid, matched: bool) {
	if (request.method != "GET" && request.method != "HEAD") ||
	   !strings.has_prefix(prefix, "/") ||
	   !strings.has_suffix(prefix, "/") ||
	   !strings.has_prefix(request.path, prefix) {
		return
	}

	relative, decoded := net.percent_decode(request.path[len(prefix):], request.allocator)
	if !decoded {
		return "", true, true
	}
	if !strings.has_suffix(relative, ".js") && !strings.has_suffix(relative, ".jsx") {
		return "", false, false
	}
	if strings.has_suffix(relative, ".jsx") || !module_relative_ok(relative) {
		return "", true, true
	}

	return relative, false, true
}

JSX_RUNTIME_URL :: jsx.JSX_RUNTIME_URL
JSX_RUNTIME :: #load("dom.js", string)
PAGE_ENTRY_URL :: "/__saba/page-entry.js"
PAGE_ENTRY :: #load("page-entry.js", string)
SLIDING_WINDOW_URL :: "/__saba/sliding-window.js"
SLIDING_WINDOW :: #load("sliding-window.js", string)
SLOT_WINDOW_URL :: "/__saba/slot-window.js"
SLOT_WINDOW :: #load("slot-window.js", string)
SCALAR_RECORDS_URL :: "/__saba/scalar-records.js"
SCALAR_RECORDS :: #load("scalar-records.js", string)

READS_URL :: "/__saba/reads.js"
READS :: #load("reads.js", string)
MUTATIONS_URL :: "/__saba/mutations.js"
MUTATIONS :: #load("mutations.js", string)
EDITOR_URL :: "/__saba/editor.js"
EDITOR :: #load("editor.js", string)
ATTACH_URL :: "/__saba/attach.js"
ATTACH :: #load("attach.js", string)

// The framework modules every legacy page may request by a fixed URL. Their
// validators and encoded variants are computed once per process, not per request.
Builtin_Module :: struct {
	url, source: string,
}

BUILTIN_MODULES :: [?]Builtin_Module {
	{JSX_RUNTIME_URL, JSX_RUNTIME},
	{PAGE_ENTRY_URL, PAGE_ENTRY},
	{SLIDING_WINDOW_URL, SLIDING_WINDOW},
	{SLOT_WINDOW_URL, SLOT_WINDOW},
	{SCALAR_RECORDS_URL, SCALAR_RECORDS},
	{READS_URL, READS},
	{MUTATIONS_URL, MUTATIONS},
	{EDITOR_URL, EDITOR},
	{ATTACH_URL, ATTACH},
}

@(private)
builtin_prepared: [len(BUILTIN_MODULES)]assets.Prepared_Representation
@(private)
builtin_once: sync.Once

// Idempotent and safe from any thread. The application prepares before
// listening; a direct caller prepares on its first request instead.
prepare_builtin_modules :: proc() {
	sync.once_do(&builtin_once, proc() {
		// Process-lifetime storage, deliberately outside any request or build arena.
		for module, index in BUILTIN_MODULES {
			builtin_prepared[index], _ = assets.prepare_encoded_representation(
				transmute([]u8)module.source,
				"text/javascript; charset=utf-8",
				rt.heap_allocator(),
			)
		}
	})
}

builtin_module :: proc(url: string) -> (^assets.Prepared_Representation, bool) {
	for module, index in BUILTIN_MODULES {
		if module.url == url {
			prepare_builtin_modules()
			return &builtin_prepared[index], true
		}
	}
	return nil, false
}

// Matches GET and HEAD of one framework module URL.
builtin_module_response :: proc(request: ^Request) -> (Response, bool) {
	if request.method != "GET" && request.method != "HEAD" {
		return {}, false
	}
	prepared, found := builtin_module(request.path)
	if !found {
		return {}, false
	}
	return assets.prepared_representation_response(request, prepared), true
}

@(private)
builtin_response :: proc(request: ^Request, url: string) -> Response {
	prepared, _ := builtin_module(url)
	return assets.prepared_representation_response(request, prepared)
}

jsx_runtime_response :: proc(request: ^Request) -> Response {
	return builtin_response(request, JSX_RUNTIME_URL)
}

page_entry_response :: proc(request: ^Request) -> Response {
	return builtin_response(request, PAGE_ENTRY_URL)
}

reads_response :: proc(request: ^Request) -> Response {
	return builtin_response(request, READS_URL)
}

sliding_window_response :: proc(request: ^Request) -> Response {
	return builtin_response(request, SLIDING_WINDOW_URL)
}

// Server-owned memory keeps compiled modules alive through the final response.
// Nothing is written into the source tree or published until every mount succeeds.
prepare_module_mounts :: proc(
	mounts: []Module_Mount,
	development: bool,
	allocator: mem.Allocator,
	// Zero fields select the asset defaults: 16 mounts, 4096 modules, 16384
	// directory entries, 8 MiB per file and 64 MiB retained across all mounts.
	limits := assets.Asset_Limits{},
) -> (
	[]Module_Cache,
	bool,
) {
	l, limits_valid := assets.normalize_limits(limits)
	if !limits_valid {
		log.error("Module limits are invalid")
		return nil, false
	}
	if len(mounts) > l.max_mounts {
		log.errorf("Module mounts exceed the limit of %d: %d", l.max_mounts, len(mounts))
		return nil, false
	}
	prepared, allocation_error := make([]Module_Cache, len(mounts), allocator)
	if allocation_error != nil {
		log.error("Could not allocate module mounts")
		return nil, false
	}
	counts: assets.Asset_Counts
	for mount, index in mounts {
		prefix := mount.prefix
		if prefix == "" {
			prefix = "/"
		}

		if !strings.has_prefix(prefix, "/") || !strings.has_suffix(prefix, "/") {
			log.errorf("Module prefix must start and end with /: %s", prefix)
			return nil, false
		}

		root, error := root_directory(mount.directory, allocator)

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

		exclude, exclude_error := make([]string, len(mount.exclude), allocator)
		if exclude_error != nil {
			log.error("Could not copy module exclusions")
			return nil, false
		}
		for entry, at in mount.exclude {
			exclude[at], _ = strings.clone(entry, allocator)
		}

		prepared[index].mount = {directory = root, prefix = owned_prefix, exclude = exclude}
		if !development && !compile_module_directory(&prepared[index], allocator, l, &counts) {
			return nil, false
		}
	}
	return prepared, true
}

compile_module_directory :: proc(
	cache: ^Module_Cache,
	allocator: mem.Allocator,
	limits := assets.Asset_Limits{},
	counts: ^assets.Asset_Counts = nil,
) -> bool {
	l, limits_valid := assets.normalize_limits(limits)
	if !limits_valid {
		log.error("Module limits are invalid")
		return false
	}
	local: assets.Asset_Counts
	counts := counts
	if counts == nil {
		counts = &local
	}
	root := cache.mount.directory
	cache.files = make(map[string]assets.Prepared_Representation, allocator)
	walker := os.walker_create(root)
	defer os.walker_destroy(&walker)

	for file in os.walker_walk(&walker) {
		counts.entries += 1
		if counts.entries > l.max_entries {
			log.errorf("Module directory %s exceeds the limit of %d entries", root, l.max_entries)
			return false
		}
		if file.type != .Regular {
			continue
		}
		relative := file.fullpath[len(root) + 1:]
		is_jsx := strings.has_suffix(relative, ".jsx")
		if (!is_jsx && !strings.has_suffix(relative, ".js")) ||
		   !module_relative_ok(relative) ||
		   module_excluded(cache.mount.exclude, relative) {
			continue
		}
		resolved, found, allowed := module_file(root, relative, allocator)

		if !found || !allowed {
			log.errorf("Module file is unavailable or escapes its directory: %s", relative)
			return false
		}

		url := relative
		if is_jsx {
			url = fmt.aprintf("%s.js", relative[:len(relative) - 4], allocator = allocator)
		}

		if _, collision := cache.files[url]; collision {
			log.errorf("JSX output collides with an existing JavaScript file: %s", url)
			return false
		}

		if counts.files == l.max_files {
			log.errorf("Module mounts exceed the limit of %d files at %s", l.max_files, resolved)
			return false
		}
		remaining := l.max_total_bytes - counts.bytes
		source, read := assets.read_limited(resolved, max(1, min(l.max_file_bytes, remaining)), allocator)

		if read.kind != .None {
			if read.kind == .Limit_Exceeded {
				if remaining < l.max_file_bytes {
					log.errorf("Module mounts exceed the limit of %d retained bytes at %s", l.max_total_bytes, resolved)
				} else {
					log.errorf("Module %s exceeds the limit of %d bytes", resolved, l.max_file_bytes)
				}
				return false
			}
			log.errorf("Could not read module %s: %v %v", resolved, read.kind, read.io)
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

		if len(output) > remaining {
			log.errorf("Module mounts exceed the limit of %d retained bytes at %s", l.max_total_bytes, resolved)
			return false
		}

		key, key_error := strings.clone(url, allocator)

		if key_error != nil {
			log.error("Could not copy module URL")
			return false
		}

		extra: int
		cache.files[key], extra = assets.prepare_encoded_representation(
			transmute([]u8)output,
			"text/javascript; charset=utf-8",
			allocator,
			remaining - len(output),
		)
		counts.files += 1
		counts.bytes += len(output) + extra
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
