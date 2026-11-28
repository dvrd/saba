package saba_pages

import core "../core"
import "core:mem"
import "core:net"
import "core:strings"
import "core:unicode/utf8"

// The shape ignores capture names so sibling [id] and [slug] routes collide.
page_pattern :: proc(
	route: string,
	allocator: mem.Allocator,
) -> (
	pattern, shape: string,
	ok: bool,
) {
	if !strings.contains_any(route, "[]") {
		return route, "", true
	}
	names: [core.MAX_PATH_PARAMETERS]string
	count := 0
	output := strings.builder_make(allocator)
	signature := strings.builder_make(allocator)
	rest := route[1:]
	for segment in strings.split_iterator(&rest, "/") {
		strings.write_byte(&output, '/')
		strings.write_byte(&signature, '/')
		if !strings.contains_any(segment, "[]") {
			strings.write_string(&output, segment)
			strings.write_string(&signature, segment)
			continue
		}
		if len(segment) < 3 || segment[0] != '[' || segment[len(segment) - 1] != ']' {
			return
		}
		name := segment[1:len(segment) - 1]
		if count == len(names) || !core.route_parameter_name(name) {
			return
		}
		for used in names[:count] {
			if used == name {
				return
			}
		}
		names[count] = name
		count += 1
		strings.write_byte(&output, ':')
		strings.write_string(&output, name)
		strings.write_byte(&signature, ':')
	}
	return strings.to_string(output), strings.to_string(signature), true
}

// Compare literal positions first. Only one of two different literals can
// match a request at that position.
literal_first :: proc(a, b: string) -> bool {
	left, right := a[1:], b[1:]
	for l in strings.split_iterator(&left, "/") {
		r, exists := strings.split_iterator(&right, "/")
		if !exists {
			return false
		}
		lp, rp := strings.has_prefix(l, ":"), strings.has_prefix(r, ":")
		if lp != rp {
			return !lp
		}
		if !lp && l != r {
			return l < r
		}
	}
	return len(right) > 0
}

document_path :: proc(
	raw: string,
	allocator: mem.Allocator,
	borrow_plain := true,
) -> (
	string,
	bool,
) {
	if raw == "/" {
		return raw, true
	}
	if len(raw) == 0 || raw[0] != '/' || raw[len(raw) - 1] == '/' {
		return "", false
	}
	// A generation-qualified module URL or an ordinary page usually needs no
	// decoding. Keep captures as slices of the request path in that case.
	if borrow_plain && !strings.contains(raw, "%") {
		return raw,
			!strings.contains(raw, "//") && !strings.contains(raw, "\\") && utf8.valid_string(raw)
	}
	output := strings.builder_make(allocator)
	rest := raw[1:]
	for segment in strings.split_iterator(&rest, "/") {
		value, valid := net.percent_decode(segment, allocator)
		if !valid ||
		   value == "" ||
		   !utf8.valid_string(value) ||
		   strings.contains_any(value, "/\\") {
			return "", false
		}
		strings.write_byte(&output, '/')
		strings.write_string(&output, value)
	}
	return strings.to_string(output), true
}

// The page HTML is shared across parameter values. Publish captures on the
// original request only after a complete match.
matched_page :: proc(cache: Page_Cache, request: ^Request, path: string) -> (string, bool) {
	if !strings.contains(path, ":") &&
	   (path in cache.routes || path in cache.modules || path in cache.build.documents) {
		request.path_parameters = {}
		request.path_parameter_count = 0
		return path, true
	}
	view := request^
	view.path = path
	for pattern in cache.patterns {
		if core.match_route(&view, request.method, pattern) {
			request.path_parameters = view.path_parameters
			request.path_parameter_count = view.path_parameter_count
			request.route = view.route
			return pattern, true
		}
	}
	return "", false
}
