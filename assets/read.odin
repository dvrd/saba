package saba_assets

import "core:crypto"
import "core:io"
import "core:os"
import "core:strings"

FILE_BYTES_MAX :: 64 << 20
Read_Error_Kind :: enum {
	None,
	Invalid_Input,
	Open_Failed,
	Read_Failed,
	Limit_Exceeded,
	Size_Changed,
	Allocation_Failed,
}
Read_Error :: struct {
	kind: Read_Error_Kind,
	io:   os.Error,
}

// Return an owned snapshot of a regular configuration/data file. Check the
// size before allocation and read one extra byte to detect concurrent growth.
read_limited :: proc(
	path: string,
	size_max: int,
	allocator := context.allocator,
	erase_on_failure := false,
) -> (
	[]u8,
	Read_Error,
) {
	if path == "" ||
	   len(path) > 4096 ||
	   strings.contains_rune(path, 0) ||
	   size_max < 1 ||
	   size_max > FILE_BYTES_MAX {
		return nil, {kind = .Invalid_Input}
	}

	file, open_error := os.open(path, {.Read, .Non_Blocking})
	if open_error != nil {
		return nil, {kind = .Open_Failed, io = open_error}
	}
	// This handle is read-only; close cannot change the returned snapshot.
	defer os.close(file)

	info, stat_error := os.fstat(file, context.allocator)
	if stat_error != nil {
		return nil, {kind = .Read_Failed, io = stat_error}
	}
	defer os.file_info_delete(info, context.allocator)

	if info.type != .Regular {
		return nil, {kind = .Invalid_Input}
	}
	size := info.size

	if size < 0 {
		return nil, {kind = .Read_Failed}
	}
	if size > i64(size_max) {
		return nil, {kind = .Limit_Exceeded}
	}
	assert(size >= 0)
	assert(size <= i64(size_max))
	data, allocation_error := make([]u8, int(size), allocator)
	if allocation_error != nil {
		return nil, {kind = .Allocation_Failed}
	}
	success := false
	defer if !success {
		if erase_on_failure {
			crypto.zero_explicit(raw_data(data), len(data))
		}
		delete(data, allocator)
	}
	used := 0
	for used < len(data) {
		count, read_error := os.read(file, data[used:])
		used += count
		if read_error != nil && read_error != io.Error.EOF {
			return nil, {kind = .Read_Failed, io = read_error}
		}
		if count == 0 || read_error == io.Error.EOF {
			break
		}
	}
	if i64(used) != size {
		return nil, {kind = .Size_Changed}
	}
	extra: [1]u8
	count, probe_error := os.read(file, extra[:])
	if probe_error != nil && probe_error != io.Error.EOF {
		return nil, {kind = .Read_Failed, io = probe_error}
	}
	if count > 0 {
		if used == size_max {
			return nil, {kind = .Limit_Exceeded}
		}
		return nil, {kind = .Size_Changed}
	}
	success = true
	return data, {}
}
