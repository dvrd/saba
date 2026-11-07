package saba_assets

import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import files "shared:files"

Asset_Mount :: struct {
	directory, prefix: string,
}
Asset_File :: struct {
	body:         []u8,
	content_type: string,
}
Asset_Cache :: struct {
	mount:          Asset_Mount,
	files:          map[string]Asset_File,
	// Effective limit also applies to development reads of changed/new files.
	max_file_bytes: int,
}
Asset_Limits :: struct {
	max_mounts, max_files, max_entries, max_file_bytes, max_total_bytes: int,
}
DEFAULT_ASSET_LIMITS :: Asset_Limits{16, 4096, 16384, 8 << 20, 64 << 20}
Asset_Error_Kind :: enum {
	None,
	Invalid_Limits,
	Mount_Limit,
	File_Limit,
	Entry_Limit,
	File_Bytes,
	Total_Bytes,
	Invalid_Mount,
	Unavailable,
	Outside_Mount,
	Allocation_Failed,
	Read_Failed,
}
Asset_Error :: struct {
	kind:                         Asset_Error_Kind,
	mount_index, limit, observed: int,
	read:                         files.Read_Error,
	io:                           os.Error,
	allocation:                   mem.Allocator_Error,
}

// Preserve the existing callable type; bounded defaults apply to old callers.
prepare_assets :: proc(mounts: []Asset_Mount, allocator: mem.Allocator) -> ([]Asset_Cache, bool) {
	caches, error := prepare_assets_bounded(mounts, {}, allocator)
	if error.kind != .None {
		log.errorf(
			"Asset preload failed: %v mount=%d limit=%d observed=%d",
			error.kind,
			error.mount_index,
			error.limit,
			error.observed,
		)
	}
	return caches, error.kind == .None
}

@(private)
normalize_limits :: proc(l: Asset_Limits) -> (Asset_Limits, bool) {
	out := l
	if out.max_mounts == 0 {
		out.max_mounts = DEFAULT_ASSET_LIMITS.max_mounts
	}
	if out.max_files == 0 {
		out.max_files = DEFAULT_ASSET_LIMITS.max_files
	}
	if out.max_entries == 0 {
		out.max_entries = DEFAULT_ASSET_LIMITS.max_entries
	}
	if out.max_file_bytes == 0 {
		out.max_file_bytes = DEFAULT_ASSET_LIMITS.max_file_bytes
	}
	if out.max_total_bytes == 0 {
		out.max_total_bytes = DEFAULT_ASSET_LIMITS.max_total_bytes
	}
	return out,
		out.max_mounts > 0 &&
		out.max_files > 0 &&
		out.max_entries > 0 &&
		out.max_file_bytes > 0 &&
		out.max_file_bytes <= files.FILE_BYTES_MAX &&
		out.max_total_bytes > 0
}

// Returns one owning cache slice. No partially prepared output escapes failure.
prepare_assets_bounded :: proc(
	mounts: []Asset_Mount,
	limits: Asset_Limits,
	allocator: mem.Allocator,
) -> (
	[]Asset_Cache,
	Asset_Error,
) {
	l, valid := normalize_limits(limits)
	if !valid || allocator.procedure == nil {
		return nil, {kind = .Invalid_Limits}
	}
	if len(mounts) > l.max_mounts {
		return nil, {kind = .Mount_Limit, limit = l.max_mounts, observed = len(mounts)}
	}
	if len(mounts) > max(int) / size_of(Asset_Cache) {
		return nil, {kind = .Invalid_Limits}
	}
	caches, ae := make([]Asset_Cache, len(mounts), allocator)
	if ae != nil || (len(mounts) > 0 && raw_data(caches) == nil) {
		return nil, {kind = .Allocation_Failed, allocation = ae}
	}
	success := false
	defer if !success {
		destroy_assets(&caches, allocator)
	}
	counts: Asset_Counts
	for mount, index in mounts {
		error := preload_mount(&caches[index], mount, l, &counts, allocator)
		if error.kind != .None {
			error.mount_index = index; return nil, error
		}
	}
	success = true
	return caches, {}
}

// Clear ownership before releasing storage; repeated teardown of this variable
// is harmless. Copies of owning caches are aliases, not additional owners.
destroy_assets :: proc(caches: ^[]Asset_Cache, allocator: mem.Allocator) {
	if caches == nil {
		return
	}
	old := caches^; caches^ = nil
	for cache in old {
		for key, value in cache.files {delete(key, allocator); delete(value.body, allocator)}
		delete(cache.files)
		delete(cache.mount.directory, allocator); delete(cache.mount.prefix, allocator)
	}
	delete(old, allocator)
}

@(private)
Asset_Counts :: struct {
	files, entries, bytes: int,
}

@(private)
preload_mount :: proc(
	cache: ^Asset_Cache,
	mount: Asset_Mount,
	l: Asset_Limits,
	counts: ^Asset_Counts,
	allocator: mem.Allocator,
) -> Asset_Error {
	if mount.directory == "" {
		return {kind = .Invalid_Mount}
	}
	prefix := mount.prefix
	if prefix == "" {
		prefix = "/assets/"
	}
	if len(prefix) < 3 ||
	   !strings.has_prefix(prefix, "/") ||
	   !strings.has_suffix(prefix, "/") ||
	   !module_relative_ok(prefix[1:len(prefix) - 1]) {
		return {kind = .Invalid_Mount}
	}
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	temporary := mem.dynamic_arena_allocator(&scratch)
	root, re := filepath.abs(mount.directory, temporary)
	if re != nil {
		return {kind = .Unavailable, io = re}
	}
	info, se := os.stat(root, temporary)
	if se != nil || info.type != .Directory {
		return {kind = .Unavailable, io = se}
	}
	owned_root, ae := strings.clone(root, allocator)
	if ae != nil || raw_data(owned_root) == nil {
		return {kind = .Allocation_Failed, allocation = ae}
	}
	cache.mount.directory = owned_root
	cache.mount.prefix, ae = strings.clone(prefix, allocator)
	if ae != nil || raw_data(cache.mount.prefix) == nil {
		return {kind = .Allocation_Failed, allocation = ae}
	}
	cache.max_file_bytes = l.max_file_bytes
	cache.files = make(map[string]Asset_File, allocator)
	// Keep iteration and File lifetimes together instead of depending on the
	// generic Walker's early-exit cleanup. Queued directory paths are bounded by
	// visited entries and destroyed even when a later file fails admission.
	pending: [dynamic]string
	pending.allocator = context.allocator
	defer {
		for path in pending {delete(path, pending.allocator)}
		delete(pending)
	}
	first, qe := strings.clone(cache.mount.directory, pending.allocator)
	if qe != nil {
		return {kind = .Allocation_Failed, allocation = qe}
	}
	if _, pe := append(&pending, first); pe != nil {
		delete(first, pending.allocator); return {kind = .Allocation_Failed, allocation = pe}
	}
	for head := 0; head < len(pending); head += 1 {
		error := preload_directory(cache, pending[head], &pending, l, counts, allocator, &scratch)
		delete(pending[head], pending.allocator); pending[head] = ""
		if error.kind != .None {
			return error
		}
	}

	return {}
}

@(private)
preload_directory :: proc(
	cache: ^Asset_Cache,
	directory: string,
	pending: ^[dynamic]string,
	l: Asset_Limits,
	counts: ^Asset_Counts,
	allocator: mem.Allocator,
	scratch: ^mem.Dynamic_Arena,
) -> Asset_Error {
	handle, oe := os.open(directory)
	if oe != nil {
		return {kind = .Unavailable, io = oe}
	}
	defer os.close(handle)
	iterator := os.read_directory_iterator_create(handle)
	defer os.read_directory_iterator_destroy(&iterator)
	temporary := mem.dynamic_arena_allocator(scratch)
	for file in os.read_directory_iterator(&iterator) {
		_, ie := os.read_directory_iterator_error(&iterator)
		if ie != nil {
			return {kind = .Unavailable, io = ie}
		}
		counts.entries += 1
		if counts.entries > l.max_entries {
			return {kind = .Entry_Limit, limit = l.max_entries, observed = counts.entries}
		}
		if file.type == .Directory {
			path, ce := strings.clone(file.fullpath, pending.allocator)
			if ce != nil {
				return {kind = .Allocation_Failed, allocation = ce}
			}
			if _, ae := append(pending, path); ae != nil {
				delete(path, pending.allocator)
				return {kind = .Allocation_Failed, allocation = ae}
			}
			continue
		}
		if file.type != .Regular {
			continue
		}
		relative := file.fullpath[len(cache.mount.directory) + 1:]
		if !module_relative_ok(relative) || strings.has_suffix(relative, ".jsx") {
			continue
		}
		if counts.files == l.max_files {
			return {kind = .File_Limit, limit = l.max_files, observed = counts.files + 1}
		}
		mem.dynamic_arena_free_all(scratch)
		path, found, allowed := module_file(cache.mount.directory, relative, temporary)
		if !allowed {
			return {kind = .Outside_Mount}
		}
		if !found {
			return {kind = .Unavailable}
		}
		// Directory mutation must not replace an existing owner and leak its body.
		if _, duplicate := cache.files[relative]; duplicate {
			return {kind = .Unavailable}
		}
		remaining := l.max_total_bytes - counts.bytes
		body, read := files.read_limited(path, max(1, min(l.max_file_bytes, remaining)), allocator)
		if read.kind != .None {
			if read.kind == .Limit_Exceeded {
				if remaining < l.max_file_bytes {
					return {
						kind = .Total_Bytes,
						limit = l.max_total_bytes,
						observed = l.max_total_bytes + int(l.max_total_bytes < max(int)),
						read = read,
					}
				}
				return {
					kind = .File_Bytes,
					limit = l.max_file_bytes,
					observed = l.max_file_bytes + 1,
					read = read,
				}
			}
			if read.kind == .Allocation_Failed {
				return {kind = .Allocation_Failed, read = read}
			}
			return {kind = .Read_Failed, read = read}
		}
		if len(body) > remaining {
			delete(body, allocator)
			return {
				kind = .Total_Bytes,
				limit = l.max_total_bytes,
				observed = counts.bytes + min(len(body), max(int) - counts.bytes),
			}
		}
		key, ke := strings.clone(relative, allocator)
		if ke != nil || raw_data(key) == nil {
			delete(body, allocator); return {kind = .Allocation_Failed, allocation = ke}
		}
		if len(cache.files) > max(int) / 2 - 1 {
			delete(key, allocator); delete(body, allocator)
			return {kind = .File_Limit, limit = l.max_files, observed = len(cache.files)}
		}
		if me := reserve(&cache.files, 2 * (len(cache.files) + 1)); me != nil {
			delete(key, allocator); delete(body, allocator)
			return {kind = .Allocation_Failed, allocation = me}
		}
		inserted, me := map_insert(
			&cache.files,
			key,
			Asset_File{body, asset_content_type(relative)},
		)
		if me != nil || inserted == nil {
			delete(key, allocator); delete(body, allocator)
			return {kind = .Allocation_Failed, allocation = me}
		}
		counts.files += 1; counts.bytes += len(body)
	}
	_, ie := os.read_directory_iterator_error(&iterator)
	if ie != nil {
		return {kind = .Unavailable, io = ie}
	}
	return {}
}
