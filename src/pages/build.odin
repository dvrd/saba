package saba_pages

import assets "../assets"
import core "../core"
import jsx "../jsx"
import modules "../modules"
import "core:crypto"
import "core:crypto/sha2"
import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/slashpath"
import "core:slice"
import "core:strings"
import "core:time"

BUILD_PATH :: "/__saba/build/"
BUILD_START :: #load("template-entry.js", string)

Template_Variant :: struct {
	language:                string,
	// Source uses the public copy for this locale. Resolve relative imports
	// against module_url as for any other application module.
	source_file, module_url: string,
	recovery_label:          string,
}

Compiled_Page :: struct {
	// Example: /items/[id]. A literal route such as /items/new takes precedence.
	path:       string,
	variants:   []Template_Variant, // first is the default
	language:   proc(request: ^Request) -> string,
	authorize:  proc(request: ^Request) -> (denial: Response, allowed: bool),
	revalidate: bool, // false means no-store, even with a matching validator
	vary:       string, // headers the application uses to select the representation
}

Template_Build :: struct {
	pages:               []Compiled_Page,
	// Add this directory to retained deployment storage to serve old builds
	// across process restarts. Removing a retired archive takes effect on reload.
	archive_directory:   string,
	archive_retention:   Archive_Retention,
	aliases:             map[string]string,
	immutable_externals: []string,
}

// How long superseded generations stay in archive_directory. Each build applies
// this when it prepares: it drops what has expired, then loads what is left.
Archive_Retention :: struct {
	// Counted from the first build that found the generation superseded, not
	// from when it was built. Zero selects 7 days; negative sets no age limit.
	max_age:           time.Duration,
	// Superseded generations kept besides the active one, newest first.
	// Zero selects 8; negative sets no count limit.
	max_count:         int,
	// Largest archive file a build will read. Zero selects the 64 MiB maximum.
	max_archive_bytes: int,
}

Compiled_Document :: struct {
	config:   Compiled_Page,
	variants: map[string]assets.Prepared_Representation,
}

Build_Cache :: struct {
	id:        string,
	documents: map[string]Compiled_Document,
	files:     map[string]assets.Prepared_Representation,
}

// Generations are named by content: the digest covers every linked module and
// document, so processes built from the same sources advertise the same URLs
// and a restart keeps browser caches. Different bytes never share an identity.
BUILD_ID_BYTES :: 16

@(private)
Pending_Document :: struct {
	pattern, language, html: string,
}

@(private)
hash_length :: proc(hasher: ^sha2.Context_256, value: int) {
	bytes: [8]u8
	endian.put_u64(bytes[:], .Little, u64(value))
	sha2.update(hasher, bytes[:])
}

@(private)
hash_text :: proc(hasher: ^sha2.Context_256, text: string) {
	hash_length(hasher, len(text))
	sha2.update(hasher, transmute([]u8)text)
}

// Text that refers to its own generation hashes as the pieces around each
// reference, so the identity does not depend on the placeholder that stood there.
@(private)
hash_generation_text :: proc(hasher: ^sha2.Context_256, text, placeholder: string) {
	hash_length(hasher, strings.count(text, placeholder) + 1)
	rest := text
	for {
		at := strings.index(rest, placeholder)
		if at < 0 {
			hash_text(hasher, rest)
			return
		}
		hash_text(hasher, rest[:at])
		rest = rest[at + len(placeholder):]
	}
}

@(private)
hex_string :: proc(bytes: []u8, allocator: mem.Allocator) -> string {
	alphabet := "0123456789abcdef"
	out := make([]u8, len(bytes) * 2, allocator)
	for value, index in bytes {
		out[index * 2] = alphabet[value >> 4]
		out[index * 2 + 1] = alphabet[value & 15]
	}
	return string(out)
}

prepare_templates :: proc(
	cache: ^Page_Cache,
	config: Template_Build,
	mounts: []modules.Module_Cache,
	allocator: mem.Allocator,
	limits := assets.Asset_Limits{},
) -> bool {
	if len(config.pages) == 0 {
		return true
	}
	l, limits_valid := assets.normalize_limits(limits)
	if !limits_valid {
		log.error("Page limits are invalid")
		return false
	}
	context.allocator = allocator
	// Unpredictable, so no source text can already contain it.
	nonce: [16]u8
	crypto.rand_bytes(nonce[:])
	placeholder := fmt.aprintf("pending-%s", hex_string(nonce[:], allocator))
	prefix := fmt.aprintf("%s%s", BUILD_PATH, placeholder)
	linker := Module_Linker {
		prefix    = prefix,
		input     = make(map[string]string),
		output    = make(map[string]string),
		allocator = allocator,
		aliases   = config.aliases,
		externals = config.immutable_externals,
		startup   = make(map[string][]string),
	}
	for mount in mounts {
		for key, rep in mount.files {
			url := fmt.aprintf("%s%s", mount.mount.prefix, key)
			if url not_in linker.input {
				linker.input[url] = string(rep.body)
			}
		}
	}
	linker.input[modules.JSX_RUNTIME_URL] = modules.JSX_RUNTIME
	linker.input[modules.SLIDING_WINDOW_URL] = modules.SLIDING_WINDOW
	linker.input[modules.SLOT_WINDOW_URL] = modules.SLOT_WINDOW
	linker.input[modules.SCALAR_RECORDS_URL] = modules.SCALAR_RECORDS
	linker.input[modules.READS_URL] = modules.READS
	linker.input[modules.MUTATIONS_URL] = modules.MUTATIONS
	linker.input[modules.EDITOR_URL] = modules.EDITOR
	linker.input[modules.ATTACH_URL] = modules.ATTACH
	linker.input["/__saba/template-entry.js"] = BUILD_START

	configs := make(map[string]Compiled_Page)
	pending := make([dynamic]Pending_Document)
	patterns := make([dynamic]string)
	append(&patterns, ..cache.patterns)
	seen := make(map[string]string)
	for pattern in cache.patterns {
		parts := strings.split(pattern, "/")
		for &part in parts {
			if strings.has_prefix(part, ":") {
				part = ":"
			}
		}
		seen[strings.join(parts, "/")] = pattern
	}
	variant_count := 0
	for page, n in config.pages {
		if len(page.path) == 0 ||
		   page.path[0] != '/' ||
		   (page.path != "/" &&
				   (!module_relative_ok(page.path[1:]) ||
						   strings.has_suffix(page.path, "/") ||
						   strings.contains_any(page.path, "?#%"))) {
			log.errorf("Invalid compiled page path %q: expected /segment or /[name] segments without a trailing slash", page.path)
			return false
		}
		if len(page.variants) == 0 {
			log.errorf("Compiled page %s declares no template variant", page.path)
			return false
		}
		pattern, shape, valid := page_pattern(page.path, allocator)
		if !valid {
			log.errorf("Invalid route parameters in compiled page %s", page.path)
			return false
		}
		if pattern in configs {
			log.errorf("Compiled page %s is declared more than once", page.path)
			return false
		}
		if shape != "" {
			old, exists := seen[shape]
			if exists && old != pattern {
				log.errorf("Ambiguous parameterized routes %s and %s", old, pattern)
				return false
			}
			if !exists {
				append(&patterns, pattern)
			}
			seen[shape] = pattern
		}
		if page.revalidate && page.language != nil && page.vary == "" {
			log.errorf("Compiled page %s: negotiated document revalidation requires Vary", page.path)
			return false
		}
		languages := make(map[string]bool)
		for variant, v in page.variants {
			if variant.language == "" {
				log.errorf("Compiled page %s: variant %d has no language", page.path, v)
				return false
			}
			if variant.language in languages {
				log.errorf("Compiled page %s declares language %s more than once", page.path, variant.language)
				return false
			}
			if variant.recovery_label == "" {
				log.errorf("Compiled page %s (%s) has no recovery label", page.path, variant.language)
				return false
			}
			if !module_url_ok(variant.module_url) {
				log.errorf(
					"Compiled page %s (%s): module URL %q must be a root-absolute .js path",
					page.path,
					variant.language,
					variant.module_url,
				)
				return false
			}
			variant_count += 1
			if variant_count > l.max_files {
				log.errorf("Compiled page variants exceed the limit of %d", l.max_files)
				return false
			}
			languages[variant.language] = true
			source, read := assets.read_limited(variant.source_file, l.max_file_bytes, allocator)
			if read.kind != .None {
				log.errorf(
					"Cannot read %s (limit %d bytes): %v %v",
					variant.source_file,
					l.max_file_bytes,
					read.kind,
					read.io,
				)
				return false
			}
			template, diagnostic := jsx.compile_page_template(
				string(source),
				variant.source_file,
				allocator,
			)
			if diagnostic.message != "" || !template.supported {
				log.errorf(
					"Cannot compile template %s: %s",
					variant.source_file,
					diagnostic.message,
				)
				return false
			}
			// A virtual sibling preserves the resolution base for relative imports.
			view := slashpath.join(
				{slashpath.dir(variant.module_url), fmt.aprintf(".saba-view-%d-%d.js", n, v)},
			)
			start := fmt.aprintf("/__saba/entry-%d-%d.js", n, v)
			if view in linker.input || start in linker.input {
				log.errorf("Generated module %s or %s collides with an application module", view, start)
				return false
			}
			linker.input[view] = template.javascript
			linker.input[start] = fmt.aprintf(
				"import {{startPage}} from '/__saba/template-entry.js';\nimport {{__sabaAttach}} from %s;\nstartPage(%s,%s,%s,__sabaAttach);",
				js_literal(view, allocator),
				js_literal(placeholder, allocator),
				js_literal(pattern, allocator),
				js_literal(variant.language, allocator),
			)
			if !link_module(&linker, start) {
				log.errorf("Could not link compiled page %s (%s)", page.path, variant.language)
				return false
			}
			document := fmt.aprintf(
				`<!doctype html><html lang="%s"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>%s</title>%s</head><body><div id="app" data-saba-pending aria-busy="true" data-generation="%s" data-route="%s">%s</div><a data-saba-recover href="">%s</a><script type="module" src="%s"></script></body></html>`,
				page_attribute(variant.language, allocator),
				page_attribute(template.title, allocator),
				preload_tags(&linker, start),
				placeholder,
				page_attribute(pattern, allocator),
				template.html,
				page_attribute(variant.recovery_label, allocator),
				page_attribute(build_asset_url(prefix, start, allocator), allocator),
			)
			append(&pending, Pending_Document{pattern, variant.language, document})
		}
		configs[pattern] = page
	}

	// Name the generation after everything it will serve, in a stable order.
	keys := make([dynamic]string)
	for key in linker.output {
		append(&keys, key)
	}
	slice.sort(keys[:])
	slice.sort_by(pending[:], proc(a, b: Pending_Document) -> bool {
		return a.pattern < b.pattern || (a.pattern == b.pattern && a.language < b.language)
	})
	hasher: sha2.Context_256
	sha2.init_256(&hasher)
	total := 0
	hash_length(&hasher, len(keys))
	for key in keys {
		hash_text(&hasher, key)
		hash_generation_text(&hasher, linker.output[key], placeholder)
		total += len(linker.output[key])
	}
	hash_length(&hasher, len(pending))
	for document in pending {
		hash_text(&hasher, document.pattern)
		hash_text(&hasher, document.language)
		hash_generation_text(&hasher, document.html, placeholder)
		total += len(document.html)
	}
	if total > l.max_total_bytes {
		log.errorf("Compiled pages exceed the limit of %d bytes: %d", l.max_total_bytes, total)
		return false
	}
	digest: [sha2.DIGEST_SIZE_256]u8
	sha2.final(&hasher, digest[:])
	id := hex_string(digest[:BUILD_ID_BYTES], allocator)

	build := Build_Cache {
		id        = id,
		documents = make(map[string]Compiled_Document),
		files     = make(map[string]assets.Prepared_Representation),
	}
	for pattern, page in configs {
		build.documents[pattern] = {
			config   = page,
			variants = make(map[string]assets.Prepared_Representation),
		}
	}
	for document in pending {
		html, _ := strings.replace_all(document.html, placeholder, id)
		doc := &build.documents[document.pattern]
		doc.variants[document.language], _ = assets.prepare_encoded_representation(
			transmute([]u8)html,
			"text/html; charset=utf-8",
			allocator,
		)
	}
	linked := make(map[string]string)
	for key in keys {
		source, _ := strings.replace_all(linker.output[key], placeholder, id)
		linked[key] = source
		build.files[fmt.aprintf("%s%s%s", BUILD_PATH, id, key)], _ = assets.prepare_encoded_representation(
			transmute([]u8)source,
			build_content_type(key),
			allocator,
		)
	}
	if config.archive_directory != "" &&
	   !archive_build(&build, linked, config.archive_directory, config.archive_retention, allocator) {
		return false
	}
	cache.patterns = patterns[:]
	slice.sort_by(cache.patterns, literal_first)
	cache.build = build
	return true
}

// A linked file keeps the type its extension names; modules are JavaScript.
build_content_type :: proc(key: string) -> string {
	if module_script(key) {
		return "text/javascript; charset=utf-8"
	}
	return assets.asset_content_type(key)
}

ARCHIVE_SUFFIX :: ".saba-build.json"
STAGING_SUFFIX :: ".saba-build.json.staging"
// A staging file this old belongs to a writer that died before its rename.
STAGING_GRACE :: 15 * time.Minute
DEFAULT_ARCHIVE_MAX_AGE :: 7 * 24 * time.Hour
DEFAULT_ARCHIVE_MAX_COUNT :: 8

Retained_Build :: struct {
	id:         string,
	files:      map[string]string,
	// Unix seconds at which a later build first found this generation
	// superseded. Zero while it has only ever been the active one.
	retired_at: i64,
}

@(private)
Archive_Candidate :: struct {
	id, path:   string,
	retired_at: i64,
	stamp:      bool, // retired_at was assigned by this build and must be stored
}

@(private)
archive_id_ok :: proc(id: string) -> bool {
	if id == "" || len(id) > 64 {
		return false
	}
	for c in transmute([]u8)id {
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-') {
			return false
		}
	}
	return true
}

// Reads and checks one archive. Every failure is a reason to ignore the file,
// never a reason to refuse the build that found it.
@(private)
read_archive :: proc(
	path, id: string,
	limit: int,
	allocator: mem.Allocator,
) -> (
	archive: Retained_Build,
	reason: string,
) {
	bytes, read := assets.read_limited(path, limit, allocator)
	#partial switch read.kind {
	case .None:
	case .Limit_Exceeded:
		return {}, fmt.tprintf("it exceeds the limit of %d bytes", limit)
	case .Open_Failed:
		return {}, fmt.tprintf("it could not be opened (%v)", read.io)
	case:
		return {}, fmt.tprintf("it could not be read (%v %v)", read.kind, read.io)
	}
	if json.unmarshal(bytes, &archive, allocator = allocator) != nil {
		return {}, "it is not a complete build archive"
	}
	if archive.id != id {
		return {}, "its name does not match the generation it holds"
	}
	for key in archive.files {
		if !strings.has_prefix(key, "/") || strings.contains(key, "//") || strings.contains_any(key, "\\?#") {
			return {}, "it holds a file that is not a module path"
		}
	}
	return archive, ""
}

// Durable replace: the bytes reach storage before the name does.
@(private)
write_archive :: proc(directory: string, archive: Retained_Build, scratch: mem.Allocator) -> bool {
	data, json_err := json.marshal(archive, allocator = scratch)
	if json_err != nil {
		return false
	}
	nonce: [8]u8
	crypto.rand_bytes(nonce[:])
	final := fmt.aprintf("%s/%s%s", directory, archive.id, ARCHIVE_SUFFIX, allocator = scratch)
	// Two processes preparing the same generation must not share a staging file.
	temp := fmt.aprintf(
		"%s/%s.%s%s",
		directory,
		archive.id,
		hex_string(nonce[:], scratch),
		STAGING_SUFFIX,
		allocator = scratch,
	)
	file, open_err := os.open(temp, {.Write, .Create, .Excl}, os.Permissions_Default_File)
	if open_err != nil {
		return false
	}
	written := 0
	for written < len(data) {
		n, write_err := os.write(file, data[written:])
		if write_err != nil || n <= 0 {
			break
		}
		written += n
	}
	stored := written == len(data) && os.sync(file) == nil
	os.close(file)
	if !stored || os.rename(temp, final) != nil {
		os.remove(temp)
		return false
	}
	return true
}

// Publishes this generation's modules for later builds and loads the retained
// ones. Superseded generations are dropped once `retention` says so, and a file
// this build cannot use is reported and skipped.
archive_build :: proc(
	build: ^Build_Cache,
	files: map[string]string,
	directory: string,
	retention: Archive_Retention,
	allocator: mem.Allocator,
) -> bool {
	max_age, max_count, max_bytes := retention.max_age, retention.max_count, retention.max_archive_bytes
	if max_age == 0 {
		max_age = DEFAULT_ARCHIVE_MAX_AGE
	}
	if max_count == 0 {
		max_count = DEFAULT_ARCHIVE_MAX_COUNT
	}
	if max_bytes <= 0 || max_bytes > assets.FILE_BYTES_MAX {
		max_bytes = assets.FILE_BYTES_MAX
	}
	if err := os.make_directory_all(directory); err != nil && !os.is_dir(directory) {
		log.errorf("Could not create build archive directory %s: %v", directory, err)
		return false
	}
	handle, err := os.open(directory)
	if err != nil {
		log.errorf("Could not open build archive directory %s: %v", directory, err)
		return false
	}
	defer os.close(handle)
	// Listings and rejected or expired archives never enter the build's storage.
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	scratch := mem.dynamic_arena_allocator(&arena)
	listing: mem.Dynamic_Arena
	mem.dynamic_arena_init(&listing)
	defer mem.dynamic_arena_destroy(&listing)
	names := mem.dynamic_arena_allocator(&listing)
	entries, list_err := os.read_directory(handle, -1, names)
	if list_err != nil {
		log.errorf("Could not list build archive directory %s: %v", directory, list_err)
		return false
	}
	now := time.now()
	seconds := time.to_unix_seconds(now)
	candidates := make([dynamic]Archive_Candidate, names)
	for file in entries {
		if file.type != .Regular {
			continue
		}
		if strings.has_suffix(file.name, STAGING_SUFFIX) {
			if time.diff(file.modification_time, now) > STAGING_GRACE {
				if os.remove(file.fullpath) == nil {
					log.infof("Removed abandoned build archive staging file %s", file.fullpath)
				}
			}
			continue
		}
		if !strings.has_suffix(file.name, ARCHIVE_SUFFIX) {
			continue
		}
		id := file.name[:len(file.name) - len(ARCHIVE_SUFFIX)]
		if id == build.id {
			continue // rewritten below as the active generation
		}
		if !archive_id_ok(id) {
			log.warnf("Ignoring build archive %s: its name is not a generation", file.fullpath)
			continue
		}
		mem.dynamic_arena_free_all(&arena)
		archive, reason := read_archive(file.fullpath, id, max_bytes, scratch)
		if reason != "" {
			log.warnf("Ignoring build archive %s: %s", file.fullpath, reason)
			continue
		}
		candidate := Archive_Candidate{id = id, path = file.fullpath, retired_at = archive.retired_at}
		if candidate.retired_at <= 0 || candidate.retired_at > seconds {
			// First seen superseded now; its retention period starts here.
			candidate.retired_at = seconds
			candidate.stamp = true
		}
		if max_age > 0 && time.Duration(seconds - candidate.retired_at) * time.Second > max_age {
			if remove_err := os.remove(file.fullpath); remove_err != nil {
				log.warnf("Could not remove expired build archive %s: %v", file.fullpath, remove_err)
			} else {
				log.infof("Removed build archive %s: retired longer than %v", file.fullpath, max_age)
			}
			continue
		}
		append(&candidates, candidate)
	}
	slice.sort_by(candidates[:], proc(a, b: Archive_Candidate) -> bool {
		return a.retired_at > b.retired_at || (a.retired_at == b.retired_at && a.id < b.id)
	})
	for candidate, index in candidates {
		if max_count > 0 && index >= max_count {
			if remove_err := os.remove(candidate.path); remove_err != nil {
				log.warnf("Could not remove surplus build archive %s: %v", candidate.path, remove_err)
			} else {
				log.infof("Removed build archive %s: more than %d generations retained", candidate.path, max_count)
			}
			continue
		}
		mem.dynamic_arena_free_all(&arena)
		archive, reason := read_archive(candidate.path, candidate.id, max_bytes, scratch)
		if reason != "" {
			log.warnf("Ignoring build archive %s: %s", candidate.path, reason)
			continue
		}
		if candidate.stamp {
			archive.retired_at = candidate.retired_at
			if !write_archive(directory, archive, scratch) {
				// Still served by this process; a later build restarts its period.
				log.warnf("Could not record the retirement of build archive %s", candidate.path)
			}
		}
		for key, previous in archive.files {
			url := fmt.aprintf("%s%s%s", BUILD_PATH, archive.id, key, allocator = allocator)
			source, clone_err := strings.clone(previous, allocator)
			if clone_err != nil {
				log.error("Could not allocate a retained build module")
				return false
			}
			build.files[url], _ = assets.prepare_encoded_representation(
				transmute([]u8)source,
				build_content_type(key),
				allocator,
				level = assets.RETAINED_BROTLI_LEVEL,
			)
		}
	}
	mem.dynamic_arena_free_all(&arena)
	if !write_archive(directory, Retained_Build{id = build.id, files = files}, scratch) {
		log.errorf("Could not write build archive %s/%s%s", directory, build.id, ARCHIVE_SUFFIX)
		return false
	}
	// Make the new names durable too. Not every filesystem can sync a directory.
	_ = os.sync(handle)
	return true
}

serve_build_asset :: proc(request: ^Request, cache: Page_Cache) -> (Response, bool) {
	if !strings.has_prefix(request.path, BUILD_PATH) {
		return {}, false
	}
	if request.method != "GET" && request.method != "HEAD" {
		return core.not_found(request), true
	}
	path, valid := document_path(request.path, request.allocator)
	rep, found := cache.build.files[path]
	if !valid || !found {
		// Another process may hold this generation, or it has retired. Neither
		// answer may be remembered for a URL that is immutable where it exists.
		return core.make_response(
				request,
				.Not_Found,
				{{"Content-Type", "text/plain; charset=utf-8"}, {"Cache-Control", "no-store"}, assets.NOSNIFF},
				transmute([]u8)string("Not Found"),
			),
			true
	}
	return assets.prepared_representation_response(request, &rep, .Immutable), true
}

serve_document :: proc(request: ^Request, doc: Compiled_Document, development := false) -> Response {
	if authorize := doc.config.authorize; authorize != nil {
		denial, allowed := authorize(request)
		if !allowed {
			return denial
		}
	}
	lang := doc.config.variants[0].language
	if select_language := doc.config.language; select_language != nil {
		if selected := select_language(request); selected in doc.variants {
			lang = selected
		}
	}
	rep := doc.variants[lang]
	policy := assets.Prepared_Cache_Policy.Revalidate
	if development || !doc.config.revalidate {
		policy = .Private_No_Store if doc.config.authorize != nil else .No_Store
	} else if doc.config.authorize != nil {
		policy = .Private_Revalidate
	}
	vary := doc.config.vary
	if vary == "" && doc.config.language != nil {
		// No-store negotiation may inspect arbitrary application headers. Revalidating
		// routes must instead declare their selectors at build time.
		vary = "*"
	}
	if development {
		// The application inserts its reload client before core content coding.
		rep = {body = rep.body, content_type = rep.content_type}
	}
	return assets.prepared_representation_response(request, &rep, policy, vary)
}
