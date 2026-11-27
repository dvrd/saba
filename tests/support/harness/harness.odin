// Shared by the e2e and interop suites: build a program against the staged
// collection, run it, read what it prints, talk to it over raw HTTP/1, stop
// it. Every path is relative to the staged repository, which is the working
// directory of every suite.
//
//   harness.odin  where things are: compiler, shared, fixture, workdir, tool, skip
//   build.odin    build, build_shared, libraries, suite_libraries
//   process.odin  start, start_with_input, send_input, expect_line, ready,
//                 lines_with, await_lines, last_field, transcript, stderr_text,
//                 running, wait, exited_cleanly, stop, execute
//   descriptors.odin  descriptors, close_on_exec, socket, dial_loopback: no
//                 program inherits a socket or pipe of a test running beside it
//   http1.odin    request_wire, dial, connect, send_text, read_head,
//                 read_response, read_chunked, read_to_close, await_close,
//                 expect_closed, quiet, reset, and the head and field helpers
//   inspect.odin  tcp_sockets, threads
package saba_test_harness

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

// The compiler task test runs with (ODIN), else odin on PATH.
compiler :: proc() -> string {
	odin := os.get_env("ODIN", context.temp_allocator)
	return odin if odin != "" else "odin"
}

// The staged collection that holds saba and its dependencies.
shared :: proc() -> string {
	return os.get_env("SABA_TEST_SHARED", context.temp_allocator)
}

// A path under tests/fixtures.
fixture :: proc(relative: string) -> string {
	return fmt.tprintf("tests/fixtures/%s", relative)
}

// A directory removed by the caller (defer os.remove_all).
workdir :: proc(t: ^testing.T, prefix: string) -> string {
	directory, error := os.make_directory_temp("", fmt.tprintf("saba-%s-*", prefix), context.temp_allocator)
	testing.expectf(t, error == nil, "could not create a work directory: %v", error)
	return directory
}

last_segment :: proc(path: string) -> string {
	trimmed := strings.trim_right(path, "/")
	if slash := strings.last_index_byte(trimmed, '/'); slash >= 0 {
		return trimmed[slash + 1:]
	}
	return trimmed
}

// Missing tools skip a suite instead of failing it. Odin's test runner has no
// skip, so the test logs why and returns.
skip :: proc(reason: string, args: ..any) {
	log.warnf(strings.concatenate({"SKIP: ", reason}, context.temp_allocator), ..args)
}

// A program on PATH (or the value of variable when it is set), or "".
tool :: proc(name: string, variable := "") -> string {
	if variable != "" {
		if value := os.get_env(variable, context.temp_allocator); value != "" {
			return value
		}
	}
	path := os.get_env("PATH", context.temp_allocator)
	for directory in strings.split_iterator(&path, ":") {
		candidate := fmt.tprintf("%s/%s", directory, name)
		if os.is_file(candidate) {
			return candidate
		}
	}
	return ""
}
