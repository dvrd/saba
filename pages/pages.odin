package saba_pages

import modules "../modules"
import assets "../assets"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"
import core "../core"

Page_Mount :: struct {
	directory:     string,
	shell:         string,
	module_prefix: string,
}

Page_Cache :: struct {
	mount:  Page_Mount,
	shell:  string,
	routes: map[string]string,
}

// Page routes and HTML borrow the server's arena, just like compiled modules.
prepare_pages :: proc(
	config: Page_Mount,
	development: bool,
	allocator: mem.Allocator,
) -> (
	Page_Cache,
	bool,
) {
	if config.directory == "" do return {}, true
	if !strings.has_prefix(config.module_prefix, "/") ||
	   !strings.has_suffix(config.module_prefix, "/") ||
	   !module_url_ok(fmt.tprintf("%spage.js", config.module_prefix)) {
		log.error("Pages require an absolute module prefix ending in /")
		return {}, false
	}
	root, error := filepath.abs(config.directory, allocator)
	if error != nil {log.error("Could not resolve page directory");return {}, false}
	info, stat_error := os.stat(root, allocator)
	if stat_error != nil ||
	   info.type != .Directory {log.error("Page directory is unavailable");return {}, false}
	mount := config
	mount.directory = root
	mount.shell, _ = strings.clone(config.shell, allocator)
	mount.module_prefix, _ = strings.clone(config.module_prefix, allocator)
	source, read_error := os.read_entire_file(config.shell, allocator)
	if read_error != nil {log.error("Could not read page shell");return {}, false}
	if strings.count(string(source), "<!--saba:page-->") != 1 {
		log.error("Page shell must contain exactly one <!--saba:page--> placeholder")
		return {}, false
	}
	cache := Page_Cache {
		mount  = mount,
		shell  = string(source),
		routes = make(map[string]string, allocator),
	}
	sources := make(map[string]string, allocator)
	walker := os.walker_create(root)
	defer os.walker_destroy(&walker)
	for file in os.walker_walk(&walker) {
		if file.type != .Regular do continue
		relative := file.fullpath[len(root) + 1:]
		if !strings.has_suffix(relative, ".jsx") || !module_relative_ok(relative) do continue
		_, found, allowed := module_file(root, relative, allocator)
		if !found || !allowed {log.error("Page file escapes its directory");return {}, false}
		stem := relative[:len(relative) - 4]
		route := fmt.aprintf("/%s", stem, allocator = allocator)
		if stem == "index" do route = "/"
		if strings.has_suffix(stem, "/index") do route = fmt.aprintf("/%s", stem[:len(stem) - 6], allocator = allocator)
		if previous, collision := sources[route]; collision {
			// A directory index wins regardless of filesystem enumeration order.
			winner := previous
			if strings.has_suffix(relative, "/index.jsx") do winner = relative
			log.warnf(
				"Duplicate page route %s: %s and %s; using %s (directory index takes precedence)",
				route,
				previous,
				relative,
				winner,
			)
			if winner == previous do continue
		}
		owned_source, clone_error := strings.clone(relative, allocator)
		if clone_error != nil {log.error("Could not copy page source path");return {}, false}
		sources[route] = owned_source
		encoded := net.percent_encode(stem, allocator)
		encoded, _ = strings.replace_all(encoded, "%2F", "/", allocator)
		cache.routes[route] = fmt.aprintf(
			"%s%s.js",
			mount.module_prefix,
			encoded,
			allocator = allocator,
		)
	}
	if _, walk_error := os.walker_error(&walker);
	   walk_error != nil {log.error("Could not scan page directory");return {}, false}
	return cache, true
}

serve_prepared_pages :: proc(
	request: ^Request,
	cache: Page_Cache,
	development: bool,
) -> (
	Response,
	bool,
) {
	if (request.method != "GET" && request.method != "HEAD") || cache.mount.directory == "" do return {}, false
	path, decoded := net.percent_decode(request.path, request.allocator)
	if !decoded || !strings.has_prefix(path, "/") || (path != "/" && !module_relative_ok(path[1:])) do return {}, false
	current := cache
	if development {
		fresh, ok := prepare_pages(cache.mount, true, request.allocator)
		if !ok do return Response{status = .Internal_Server_Error}, true
		current = fresh
	}
	module_url, found := current.routes[path]
	if !found do return {}, false
	entry := fmt.aprintf(
		`<script type="module" src="%s" data-page="%s"></script>`,
		modules.PAGE_ENTRY_URL,
		page_attribute(module_url, request.allocator),
		allocator = request.allocator,
	)
	html, _ := strings.replace_all(current.shell, "<!--saba:page-->", entry, request.allocator)
	return assets.representation_response(request, transmute([]u8)html, "text/html; charset=utf-8", development), true
}

@(private)
page_attribute :: proc(value: string, allocator: mem.Allocator) -> string {
	result := value
	for pair in ([][2]string{{"&", "&amp;"}, {`"`, "&quot;"}, {"<", "&lt;"}, {">", "&gt;"}}) {
		result, _ = strings.replace_all(result, pair[0], pair[1], allocator)
	}
	return result
}

Request :: core.Request
Response :: core.Response
