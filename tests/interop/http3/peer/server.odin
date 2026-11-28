package saba_test_h3_peer

import harness "../../../support/harness"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

CERTIFICATE :: "tests/fixtures/tls/localhost.pem"
KEY :: "tests/fixtures/tls/rsa2048.pem"

// A Saba program under test: it prints READY <port>, serves until its stdin
// has a byte or closes, then prints what it counted and exits.
Server :: struct {
	process: ^harness.Process,
	input:   ^os.File,
	port:    int,
}

@(private)
builds: struct {
	mutex:     sync.Mutex,
	directory: string,
	binaries:  map[string]string,
}

// Builds source once per test program, however many tests ask for it.
binary :: proc(t: ^testing.T, source: string) -> (string, bool) {
	sync.guard(&builds.mutex)
	context.allocator = runtime.heap_allocator()
	if path, found := builds.binaries[source]; found {
		return path, path != ""
	}
	if builds.directory == "" {
		directory, error := os.make_directory_temp("", "saba-interop-*", context.allocator)
		if !testing.expectf(t, error == nil, "could not create a build directory: %v", error) {
			return "", false
		}
		builds.directory = directory
	}
	target := fmt.tprintf("%s/%d", builds.directory, len(builds.binaries))
	os.make_directory(target)
	path, ok := harness.build(t, source, target)
	builds.binaries[strings.clone(source)] = strings.clone(path) if ok else ""
	return path, ok
}

@(fini, private)
remove_builds :: proc "contextless" () {
	if builds.directory != "" {
		context = runtime.default_context()
		_ = os.remove_all(builds.directory)
	}
}

// Builds and starts a server program with arguments, and waits for its port.
serve :: proc(t: ^testing.T, source: string, arguments: ..string) -> (s: Server, ok: bool) {
	path := binary(t, source) or_return
	command := make([dynamic]string, context.temp_allocator)
	append(&command, path)
	append(&command, ..arguments)
	s.process, s.input = harness.start_with_input(t, command[:]) or_return
	s.port, ok = harness.ready(t, s.process)
	if !ok {
		stop(t, &s)
	}
	return
}

// Stops the server and returns the line starting with prefix it printed on
// the way out ("" without one, or when it did not exit cleanly).
stop :: proc(t: ^testing.T, s: ^Server, prefix := "RESULT ", loc := #caller_location) -> string {
	if s.process == nil {
		return ""
	}
	_, _ = os.write_string(s.input, "s")
	os.close(s.input)
	line := ""
	if harness.exited_cleanly(t, s.process, loc = loc) && prefix != "" {
		found := harness.lines_with(s.process, prefix)
		if len(found) > 0 {
			line = found[len(found) - 1]
		} else {
			testing.expectf(
				t,
				false,
				"the server printed no %q line\n%s",
				prefix,
				harness.transcript(s.process),
				loc = loc,
			)
		}
	}
	harness.stop(s.process)
	s.process = nil
	return line
}
