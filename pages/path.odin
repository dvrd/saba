package saba_pages

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Resolve links before reading so a directory mount cannot expose files outside
// its root. The returned path and stat storage belong to the request allocator.
@(private)
module_file :: proc(
	root, relative: string,
	allocator: mem.Allocator,
) -> (
	path: string,
	found, allowed: bool,
) {
	resolved, error := filepath.abs(fmt.tprintf("%s/%s", root, relative), allocator)
	if error != nil {
		return "", false, true
	}

	if !strings.has_prefix(resolved, fmt.tprintf("%s/", strings.trim_right(root, "/"))) {
		return "", false, false
	}

	info, stat_error := os.stat(resolved, allocator)
	return resolved, stat_error == nil && info.type == .Regular, true
}

@(private)
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

@(private)
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
