package saba_assets

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Resolve links before reading so a directory mount cannot expose files outside
// its root. The returned path and stat storage belong to the request allocator.
module_file :: proc(root, relative: string, allocator: mem.Allocator) -> (path: string, found, allowed: bool) {
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

// Component sources never leave a mount. Case-insensitive volumes resolve
// `page.JSX` to `page.jsx`, so the suffix is compared without regard to case.
jsx_source :: proc(path: string) -> bool {
	return len(path) >= 4 && strings.equal_fold(path[len(path) - 4:], ".jsx")
}
