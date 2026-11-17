package server

import "core:fmt"
import "core:mem"
import "core:os"
import "core:testing"

// Synthetic configuration only. Run environment-mutating tests serially.
@(test)
credential_profile_rejects_oversize_before_allocation :: proc(t: ^testing.T) {
	directory, dir_error := os.make_directory_temp("", "saba-credentials-*", context.allocator)

	if !testing.expect(t, dir_error == nil) {
		return
	}

	defer delete(directory)
	defer os.remove(directory)
	path := fmt.aprintf("%s/credentials", directory)
	defer delete(path)
	defer os.remove(path)
	large := make([]u8, 1024 * 1024)
	defer delete(large)

	if !testing.expect(t, os.write_entire_file(path, large) == nil) {
		return
	}

	keys := []string {
		"AWS_ACCESS_KEY_ID",
		"AWS_SECRET_ACCESS_KEY",
		"AWS_SESSION_TOKEN",
		"AWS_PROFILE",
		"AWS_SHARED_CREDENTIALS_FILE",
		"AWS_CONTAINER_CREDENTIALS_RELATIVE_URI",
		"AWS_EC2_METADATA_DISABLED",
	}

	values := make([]string, len(keys))
	defer delete(values)
	present := make([]bool, len(keys))
	defer delete(present)

	for key, index in keys {
		values[index], present[index] = os.lookup_env(key, context.allocator)

		if !testing.expect(t, os.set_env(key, "") == nil) {
			return
		}
	}

	defer for key, index in keys {
		if present[index] {
			os.set_env(key, values[index])
		} else {
			os.unset_env(key)
		}

		delete(values[index])
	}

	testing.expect(t, os.set_env("AWS_SHARED_CREDENTIALS_FILE", path) == nil)
	testing.expect(t, os.set_env("AWS_EC2_METADATA_DISABLED", "true") == nil)
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.temp_allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	context.temp_allocator = mem.tracking_allocator(&tracker)
	credentials, ok := aws_credentials()
	testing.expect(t, !ok && credentials.access_key == "", "oversize profile fails closed")
	testing.expectf(
		t,
		tracker.total_memory_allocated < 64 * 1024,
		"oversize profile must be rejected before reading/allocating its payload; allocated %d bytes",
		tracker.total_memory_allocated,
	)
}
