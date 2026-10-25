package server

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

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
	cache.files = make(map[string]string, allocator)
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
		cache.files[key] = output
	}
	if path, error := os.walker_error(&walker); error != nil {
		log.errorf("Could not scan module directory %s: %v", path, error)
		return false
	}
	return true
}
