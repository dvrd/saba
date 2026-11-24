package saba_pages

import modules "../modules"
import assets "../assets"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import core "../core"

Page_Mount :: struct {
	directory:     string,
	shell:         string,
	module_prefix: string,
	templates:     Template_Build,
	// Bounds page preparation like an asset mount: max_files pages or template
	// variants, max_file_bytes per shell or source, max_total_bytes of prepared
	// HTML and linked modules. Zero fields select the asset defaults.
	limits:        assets.Asset_Limits,
}

// Production prepares each route's HTML once into `routes`. Development keeps
// only the route -> module URL table in `modules` and rebuilds pages per request.
Page_Cache :: struct {
	mount:   Page_Mount,
	shell:   string,
	routes:  map[string]assets.Prepared_Representation,
	modules: map[string]string,
	patterns: []string,
	build: Build_Cache,
}

// Page routes and HTML borrow the server's arena, just like compiled modules.
prepare_pages :: proc(config: Page_Mount, development: bool, allocator: mem.Allocator, module_mounts: []modules.Module_Cache = nil) -> (Page_Cache, bool) {
	cache, prepared := prepare_legacy_pages(config, development, allocator)
	if !prepared { return {}, false }
	if !prepare_templates(&cache, config.templates, module_mounts, allocator, config.limits) { return {}, false }
	return cache, true
}

prepare_legacy_pages :: proc(config: Page_Mount, development: bool, allocator: mem.Allocator) -> (Page_Cache, bool) {
	if config.directory == "" {
		return {}, true
	}
	l, limits_valid := assets.normalize_limits(config.limits)
	if !limits_valid {
		log.error("Page limits are invalid")
		return {}, false
	}
	if !strings.has_prefix(config.module_prefix, "/") ||
	   !strings.has_suffix(config.module_prefix, "/") ||
	   !module_url_ok(fmt.tprintf("%spage.js", config.module_prefix)) {
		log.error("Pages require an absolute module prefix ending in /")
		return {}, false
	}

	root, error := filepath.abs(config.directory, allocator)

	if error != nil {
		log.error("Could not resolve page directory")
		return {}, false
	}

	info, stat_error := os.stat(root, allocator)

	if stat_error != nil || info.type != .Directory {
		log.error("Page directory is unavailable"); return {}, false
	}

	mount := config
	mount.directory = root
	mount.shell, _ = strings.clone(config.shell, allocator)
	mount.module_prefix, _ = strings.clone(config.module_prefix, allocator)
	source, read := assets.read_limited(config.shell, l.max_file_bytes, allocator)

	if read.kind != .None {
		log.errorf("Could not read page shell (limit %d bytes): %v %v", l.max_file_bytes, read.kind, read.io)
		return {}, false
	}

	if strings.count(string(source), "<!--saba:page-->") != 1 {
		log.error("Page shell must contain exactly one <!--saba:page--> placeholder")
		return {}, false
	}

	cache := Page_Cache {
		mount  = mount,
		shell   = string(source),
		modules = make(map[string]string, allocator),
	}

	sources := make(map[string]string, allocator)
	shapes := make(map[string]string, allocator)
	patterns := make([dynamic]string, allocator)
	walker := os.walker_create(root)
	defer os.walker_destroy(&walker)
	page_count, entry_count := 0, 0

	for file in os.walker_walk(&walker) {
		entry_count += 1
		if entry_count > l.max_entries {
			log.errorf("Page directory exceeds the limit of %d entries", l.max_entries)
			return {}, false
		}
		if file.type != .Regular {
			continue
		}
		relative := file.fullpath[len(root) + 1:]
		if !strings.has_suffix(relative, ".jsx") || !module_relative_ok(relative) {
			continue
		}
		_, found, allowed := module_file(root, relative, allocator)

		if !found || !allowed {
			log.error("Page file escapes its directory")
			return {}, false
		}

		stem := relative[:len(relative) - 4]
		route := fmt.aprintf("/%s", stem, allocator = allocator)
		if stem == "index" {
			route = "/"
		}
		if strings.has_suffix(stem, "/index") {
			route = fmt.aprintf("/%s", stem[:len(stem) - 6], allocator = allocator)
		}
		pattern, shape, valid := page_pattern(route, allocator)
		if !valid {
			log.errorf("Invalid page route in %s", relative)
			return {}, false
		}
		page_count += 1
		if page_count > l.max_files {
			log.errorf("Page directory exceeds the limit of %d pages", l.max_files)
			return {}, false
		}
		if shape != "" {
			if previous, present := shapes[shape]; present {
				log.errorf("Ambiguous parameterized routes %s and %s", previous, relative)
				return {}, false
			}
			shapes[shape] = route
			append(&patterns, pattern)
			route = pattern
		}

		if previous, collision := sources[route]; collision {
			// A directory index wins regardless of filesystem enumeration order.
			winner := previous
			if strings.has_suffix(relative, "/index.jsx") {
				winner = relative
			}
			log.warnf(
				"Duplicate page route %s: %s and %s; using %s (directory index takes precedence)",
				route,
				previous,
				relative,
				winner,
			)
			if winner == previous {
				continue
			}
		}

		owned_source, clone_error := strings.clone(relative, allocator)

		if clone_error != nil {
			log.error("Could not copy page source path")
			return {}, false
		}

		sources[route] = owned_source
		encoded := net.percent_encode(stem, allocator)
		encoded, _ = strings.replace_all(encoded, "%2F", "/", allocator)
		cache.modules[route] = fmt.aprintf("%s%s.js", mount.module_prefix, encoded, allocator = allocator)
	}

	if _, walk_error := os.walker_error(&walker); walk_error != nil {
		log.error("Could not scan page directory"); return {}, false
	}
	cache.patterns = patterns[:]
	slice.sort_by(cache.patterns, literal_first)

	if development {
		return cache, true
	}

	cache.routes = make(map[string]assets.Prepared_Representation, allocator)

	if len(cache.modules) * len(cache.shell) > l.max_total_bytes {
		log.errorf(
			"Prepared pages exceed the limit of %d bytes: %d pages of a %d byte shell",
			l.max_total_bytes,
			len(cache.modules),
			len(cache.shell),
		)
		return {}, false
	}

	for route, module_url in cache.modules {
		html := page_html(cache.shell, module_url, allocator, route)
		cache.routes[route], _ = assets.prepare_encoded_representation(
			transmute([]u8)html,
			"text/html; charset=utf-8",
			allocator,
		)
	}

	// Production serves only the prepared bytes; the table lives in the caller's arena.
	cache.modules = nil

	return cache, true
}

page_html :: proc(shell, module_url: string, allocator: mem.Allocator, route := "") -> string {
	pattern := ""
	if strings.contains(route, ":") {
		pattern = fmt.aprintf(` data-route="%s"`, page_attribute(route, allocator), allocator = allocator)
	}
	entry := fmt.aprintf(
		`<script type="module" src="%s" data-page="%s"%s></script>`,
		modules.PAGE_ENTRY_URL,
		page_attribute(module_url, allocator),
		pattern,
		allocator = allocator,
	)
	html, _ := strings.replace_all(shell, "<!--saba:page-->", entry, allocator)

	return html
}

serve_prepared_pages :: proc(request: ^Request, cache: Page_Cache, development: bool) -> (Response, bool) {
	if (request.method != "GET" && request.method != "HEAD") || (cache.mount.directory == "" && len(cache.build.documents) == 0) {
		return {}, false
	}
	path, decoded := document_path(request.path, request.allocator)
	if !decoded {
		return {}, false
	}
	if !development || len(cache.build.documents) != 0 {
		if pattern, found := matched_page(cache, request, path); found {
			if doc, compiled := cache.build.documents[pattern]; compiled {
				return serve_document(request, doc, development), true
			}
			if !development {
				prepared := cache.routes[pattern]
				return assets.prepared_representation_response(request, &prepared), true
			}
		}
		if !development || cache.mount.directory == "" {
			return {}, false
		}
	}

	current, ok := prepare_legacy_pages(cache.mount, true, request.allocator)

	if !ok {
		return Response{status = .Internal_Server_Error}, true
	}

	pattern, found := matched_page(current, request, path)

	if !found {
		return {}, false
	}

	html := page_html(current.shell, current.modules[pattern], request.allocator, pattern)

	return assets.representation_response(request, transmute([]u8)html, "text/html; charset=utf-8", true), true
}

page_attribute :: proc(value: string, allocator: mem.Allocator) -> string {
	result := value

	for pair in ([][2]string{{"&", "&amp;"}, {`"`, "&quot;"}, {"<", "&lt;"}, {">", "&gt;"}}) {
		result, _ = strings.replace_all(result, pair[0], pair[1], allocator)
	}

	return result
}

Request :: core.Request
Response :: core.Response
