package saba_pages

import jsx "../jsx"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:path/slashpath"
import "core:reflect"
import "core:slice"
import "core:strings"
import k "shared:kessel"

Module_Linker :: struct {
	prefix:        string,
	input, output: map[string]string,
	allocator:     mem.Allocator,
	aliases:       map[string]string,
	externals:     []string,
	startup:       map[string][]string,
}

Import_Site :: struct {
	loc:        k.Loc,
	path:       string,
	recovery:   bool,
	is_dynamic: bool,
}

// Imported values are rewritten by their parser spans. Text containing a URL,
// including strings passed to fetch, never enters this list.
import_sites :: proc(value: any, sites: ^[dynamic]Import_Site, invalid: ^u32) -> bool {
	if value.data == nil {
		return true
	}
	switch node in value {
	case ^k.ImportDeclaration:
		append(sites, Import_Site{loc = node.source.loc, path = node.source.value})
		return true
	case ^k.ExportNamedDeclaration:
		if src, ok := node.source.(k.StringLiteral); ok {
			append(sites, Import_Site{loc = src.loc, path = src.value})
		}
	case ^k.ExportAllDeclaration:
		append(sites, Import_Site{loc = node.source.loc, path = node.source.value})
		return true
	case ^k.ImportExpression:
		if src, ok := node.source^.(^k.StringLiteral); ok {
			append(sites, Import_Site{loc = src.loc, path = src.value, is_dynamic = true})
			append(sites, Import_Site{loc = {node.loc.end, node.loc.end}, recovery = true})
			return import_sites(node.options, sites, invalid)
		}
		invalid^ = node.loc.start
		return false
	case k.Loc:
		return true
	}
	#partial switch reflect.underlying_type_kind(value.id) {
	case .Pointer:
		return import_sites(reflect.deref(value), sites, invalid)
	case .Union:
		return import_sites(reflect.get_union_variant(value), sites, invalid)
	case .Slice, .Dynamic_Array:
		for i in 0 ..< reflect.length(value) {
			if !import_sites(reflect.index(value, i), sites, invalid) {
				return false
			}
		}
	case .Struct:
		for i in 0 ..< reflect.struct_field_count(value.id) {
			field := reflect.struct_field_at(value.id, i)
			if !import_sites(reflect.struct_field_value(value, field), sites, invalid) {
				return false
			}
		}
	}
	return true
}

link_error :: proc(file, source: string, offset: u32, message: string) -> bool {
	line, column := 1, 1
	for r in source[:offset] {
		if r == '\n' {
			line += 1; column = 1
		} else {
			column += 1
		}
	}
	log.errorf("%s:%d:%d: %s", file, line, column, message)
	return false
}

js_literal :: proc(value: string, allocator: mem.Allocator) -> string {
	data, err := json.marshal(value, allocator = allocator)
	assert(err == nil)
	return string(data)
}

build_asset_url :: proc(prefix, path: string, allocator: mem.Allocator) -> string {
	encoded := net.percent_encode(path, allocator)
	fixed, _ := strings.replace_all(encoded, "%2F", "/", allocator)
	return fmt.aprintf("%s%s", prefix, fixed, allocator = allocator)
}

module_script :: proc(key: string) -> bool {
	return strings.has_suffix(key, ".js") || strings.has_suffix(key, ".mjs")
}

link_module :: proc(build: ^Module_Linker, key: string) -> bool {
	if key in build.output {
		return true
	}
	source, exists := build.input[key]
	if !exists {
		log.errorf("Missing build module %s", key)
		return false
	}
	if !module_script(key) {
		// A JSON or other non-script module has no imports to rewrite.
		build.output[key] = source
		return true
	}
	// Mark the module before visiting its imports so cyclic ESM graphs terminate.
	build.output[key] = ""
	job: k.ParseJob
	if !k.parse_job_open_inline(
		&job,
		source,
		{lang_override = .JS, source_type_override = .Module},
		key,
	) {
		log.errorf("Could not start parsing build module %s", key)
		return false
	}
	defer k.parse_job_close(&job)
	context.allocator = job.arena_alloc
	k.parse_job_run(&job)
	if len(job.parser.errors) != 0 {
		log.errorf("Could not link %s: %s", key, job.parser.errors[0].message)
		return false
	}
	sites: [dynamic]Import_Site
	invalid: u32
	if !import_sites(job.program.body, &sites, &invalid) {
		return link_error(
			key,
			source,
			invalid,
			"Expected a literal dynamic import in a compiled page",
		)
	}
	slice.sort_by(sites[:], proc(a, b: Import_Site) -> bool {return a.loc.start < b.loc.start})
	out := strings.builder_make(build.allocator)
	start := 0
	recovery := ""
	dependencies := make([dynamic]string, build.allocator)
	for site in sites {
		if site.recovery {
			if recovery == "" {
				recovery = jsx.jsx_helper_name(source, "__sabaUnavailable")
			}
			strings.write_string(&out, source[start:site.loc.start])
			fmt.sbprintf(&out, ".catch(%s)", recovery)
			start = int(site.loc.end)
			continue
		}
		path := site.path
		if alias, ok := build.aliases[path]; ok {
			path = alias
		}
		allowed_external := false
		for allowed in build.externals {
			if allowed == path && strings.has_prefix(allowed, "https://") {
				allowed_external = true; break
			}
		}
		if allowed_external {
			strings.write_string(&out, source[start:site.loc.start])
			strings.write_string(&out, js_literal(path, context.allocator))
			start = int(site.loc.end)
			continue
		}
		if strings.contains_any(path, "?#\\") ||
		   strings.has_prefix(path, "//") ||
		   !(strings.has_prefix(path, "/") ||
				   strings.has_prefix(path, "./") ||
				   strings.has_prefix(path, "../")) {
			return link_error(
				key,
				source,
				site.loc.start,
				fmt.tprintf("Unsupported build import %s", path),
			)
		}
		if !strings.has_prefix(path, "/") {
			path = slashpath.join({slashpath.dir(key), path})
		}
		// Build graph keys outlive the parser arena that owns the specifier.
		target, valid := document_path(path, build.allocator, borrow_plain = false)
		if !valid || target not_in build.input {
			return link_error(
				key,
				source,
				site.loc.start,
				fmt.tprintf("Unresolved build import %s", path),
			)
		}
		if !link_module(build, target) {
			return false
		}
		if !site.is_dynamic {
			append(&dependencies, target)
		}
		strings.write_string(&out, source[start:site.loc.start])
		strings.write_string(
			&out,
			js_literal(build_asset_url(build.prefix, target, build.allocator), context.allocator),
		)
		start = int(site.loc.end)
	}
	strings.write_string(&out, source[start:])
	if recovery != "" {
		module :: "/__saba/template-entry.js"
		if !link_module(build, module) {
			return false
		}
		append(&dependencies, module)
		fmt.sbprintf(
			&out,
			"\nimport {{unavailable as %s}} from %s;\n",
			recovery,
			js_literal(build_asset_url(build.prefix, module, build.allocator), context.allocator),
		)
	}
	build.output[key] = strings.to_string(out)
	build.startup[key] = dependencies[:]
	return true
}

preload_tags :: proc(build: ^Module_Linker, entry: string) -> string {
	visited := make(map[string]bool, context.temp_allocator)
	pending := make([dynamic]string, context.temp_allocator)
	append(&pending, entry)
	visited[entry] = true
	tags := strings.builder_make(build.allocator)
	for i := 0; i < len(pending); i += 1 {
		for module in build.startup[pending[i]] {
			if visited[module] {
				continue
			}
			visited[module] = true
			append(&pending, module)
			url := build_asset_url(build.prefix, module, context.temp_allocator)
			fmt.sbprintf(
				&tags,
				`<link rel="modulepreload" href="%s">`,
				page_attribute(url, context.temp_allocator),
			)
		}
	}
	return strings.to_string(tags)
}
