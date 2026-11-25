package saba_pages

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"

// Resolve links before reading so a directory mount cannot expose files outside
// its root. The returned path and stat storage belong to the request allocator.
module_file :: proc(root, relative: string, allocator: mem.Allocator) -> (path: string, found, allowed: bool) {
	joined := fmt.tprintf("%s/%s", root, relative)
	kind := entry_type(joined)

	if kind != .Regular && kind != .Directory {
		return "", false, true
	}

	resolved, error := filepath.abs(joined, allocator)

	if error != nil {
		return "", false, true
	}

	if !strings.has_prefix(resolved, fmt.tprintf("%s/", strings.trim_right(root, "/"))) {
		return "", false, false
	}

	return resolved, kind == .Regular, true
}

// Resolving a path can open it: realpath does on Darwin, and so does os.stat
// there. A FIFO then waits for a writer and a device answers the open. lstat(2)
// and stat(2) name the entry without opening it, so only a regular file or a
// directory, reached directly or through symbolic links, goes on to be resolved.
// A link is followed here only to learn its target's type; the resolved path is
// still held to its caller's containment check. Anything else is .Undetermined.
entry_type :: proc(path: string) -> os.File_Type {
	name := strings.clone_to_cstring(path, context.temp_allocator)
	info: posix.stat_t

	if posix.lstat(name, &info) != .OK {
		return .Undetermined
	}

	if posix.S_ISLNK(info.st_mode) && posix.stat(name, &info) != .OK {
		return .Undetermined
	}

	switch {
	case posix.S_ISREG(info.st_mode):
		return .Regular
	case posix.S_ISDIR(info.st_mode):
		return .Directory
	}

	return .Undetermined
}

// The absolute path of a configured root, refused like module_file refuses an
// entry when it is not a directory, so resolving it never opens a FIFO.
root_directory :: proc(directory: string, allocator: mem.Allocator) -> (string, os.Error) {
	if entry_type(directory) != .Directory {
		return "", .Invalid_Dir
	}

	return filepath.abs(directory, allocator)
}

module_relative_ok :: proc(relative: string) -> bool {
	for c in relative {
		if c < 32 || c == 127 || c == '\\' || c == ':' {
			return false
		}
	}

	remaining := relative

	for segment in strings.split_iterator(&remaining, "/") {
		if segment == "" || strings.has_prefix(segment, ".") {
			return false
		}
	}

	return true
}

module_url_ok :: proc(url: string) -> bool {
	if !strings.has_prefix(url, "/") || !strings.has_suffix(url, ".js") {
		return false
	}

	for c in url {
		if c <= 32 || c == '?' || c == '#' || c == '%' {
			return false
		}
	}

	return module_relative_ok(url[1:])
}
