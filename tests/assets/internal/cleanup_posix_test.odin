#+build darwin,linux
package saba_assets

import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:testing"

asset_count_fds :: proc() -> int {
	count := 0

	for fd in 0 ..< 4096 {
		if posix.fcntl(posix.FD(fd), .GETFD) >= 0 {
			count += 1
		}
	}

	return count
}

@(test)
asset_early_failure_closes_directory_files_and_iterators :: proc(t: ^testing.T) {
	directory := asset_test_directory()
	defer delete(directory)
	defer os.remove_all(directory)
	assert(os.make_directory(fmt.tprintf("%s/sub", directory)) == nil)
	asset_test_write(directory, "sub/a", "large-body")
	asset_test_write(directory, "sub/b", "body")
	// Warm platform filesystem helpers before taking the descriptor baseline.
	caches, error := prepare_assets_bounded({{directory, ""}}, {}, context.allocator)
	assert(error.kind == .None)
	destroy_assets(&caches, context.allocator)
	before := asset_count_fds()

	for _ in 0 ..< 32 {
		output, failure := prepare_assets_bounded({{directory, ""}}, {max_file_bytes = 1}, context.allocator)
		testing.expect_value(t, failure.kind, .File_Bytes)
		testing.expect(t, output == nil)
		output, failure = prepare_assets_bounded({{directory, ""}}, {max_entries = 1}, context.allocator)
		testing.expect_value(t, failure.kind, .Entry_Limit)
		testing.expect(t, output == nil)
	}

	testing.expect_value(t, asset_count_fds(), before)
}

@(test)
asset_symlinks_cannot_escape_a_mount :: proc(t: ^testing.T) {
	directory := asset_test_directory()
	defer delete(directory)
	defer os.remove_all(directory)
	outside := asset_test_directory()
	defer delete(outside)
	defer os.remove_all(outside)
	asset_test_write(outside, "secret.txt", "private")
	assert(os.symlink(fmt.tprintf("%s/secret.txt", outside), fmt.tprintf("%s/link.txt", directory)) == nil)
	caches, error := prepare_assets_bounded({{directory, ""}}, {}, context.allocator)
	assert(error.kind == .None)
	defer destroy_assets(&caches, context.allocator)
	testing.expect_value(t, len(caches[0].files), 0)
	request := Request {
		allocator = context.temp_allocator,
		method    = "GET",
		path      = "/assets/link.txt",
	}

	response, matched := serve_assets(&request, caches, true)
	testing.expect(t, matched)
	testing.expect_value(t, response.status, .Not_Found)
}
