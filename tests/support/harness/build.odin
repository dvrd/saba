// Building suite programs and finding the C libraries they link.
package saba_test_harness

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

// Vet Saba's packages and the test program, not the dependencies: async, surf
// and the rest are vetted in their own repositories.
VET_PACKAGES :: "-vet-packages:main,server,saba_application,saba_assets,saba_core,saba_development,saba_jsx,saba_modules,saba_offload,saba_pages,saba_s3,saba_upstream,saba_websocket"

// Builds the program in source into directory and returns its path. Strict:
// -vet on Saba's packages and -warnings-as-errors, as every suite program is.
// SABA_TEST_SANITIZE names a sanitizer for the build.
build :: proc(t: ^testing.T, source, directory: string, flags: ..string) -> (string, bool) {
	binary := fmt.tprintf("%s/%s", directory, last_segment(source))
	command := make([dynamic]string, context.temp_allocator)
	append(&command, compiler(), "build", source, fmt.tprintf("-out:%s", binary))
	append(&command, fmt.tprintf("-collection:shared=%s", shared()))
	append(&command, "-vet", VET_PACKAGES, "-warnings-as-errors")
	if sanitizer := os.get_env("SABA_TEST_SANITIZE", context.temp_allocator); sanitizer != "" {
		append(&command, fmt.tprintf("-sanitize:%s", sanitizer))
	}
	append(&command, ..flags)
	result, output, errors, error := execute(command[:])
	if error != nil || !result.success {
		testing.expectf(t, false, "could not build %s: %v\n%s%s", source, error, output, errors)
		return "", false
	}
	return binary, true
}

// Programs that several tests of a suite start are built once: the first test
// that asks builds the program, the others wait for it and share the binary.
// The binaries go beside the suite's own executable, in the work directory
// task test removes after the run: a test cannot know it is the last one, and
// the test runner exits without running fini procedures.

@(private = "file")
shared_mutex: sync.Mutex
@(private = "file")
shared_binaries: map[string]string
@(private = "file")
shared_directory: string

// Like build, into a directory this package owns; the path stays valid for the
// whole suite.
build_shared :: proc(t: ^testing.T, source: string, flags: ..string) -> (string, bool) {
	sync.guard(&shared_mutex)
	heap := runtime.heap_allocator()
	parts := make([dynamic]string, context.temp_allocator)
	append(&parts, source)
	append(&parts, ..flags)
	key := strings.join(parts[:], " ", context.temp_allocator)
	if binary, found := shared_binaries[key]; found {
		return binary, testing.expectf(t, binary != "", "%s did not build in an earlier test", source)
	}
	if shared_directory == "" {
		beside, located := os.get_executable_directory(context.temp_allocator)
		if !testing.expectf(t, located == nil, "could not locate the suite: %v", located) {
			return "", false
		}
		directory, error := os.make_directory_temp(beside, "saba-programs-*", heap)
		if !testing.expectf(t, error == nil, "could not create a build directory: %v", error) {
			return "", false
		}
		shared_directory = directory
		shared_binaries.allocator = heap
	}
	directory := fmt.tprintf("%s/%d", shared_directory, len(shared_binaries))
	if error := os.make_directory(directory); !testing.expectf(t, error == nil, "could not create %s: %v", directory, error) {
		return "", false
	}
	binary, ok := build(t, source, directory, ..flags)
	shared_binaries[strings.clone(key, heap)] = strings.clone(binary, heap) if ok else ""
	return strings.clone(binary, context.temp_allocator), ok
}

// Linker flags for C libraries, found with pkg-config. On a Homebrew machine
// the keg-only formulas (curl, openssl@4) are searched too. missing names the
// first module pkg-config does not know, and flags is nil then.
libraries :: proc(modules: []string) -> (flags: []string, missing: string) {
	pkg_config := tool("pkg-config", "SABA_PKG_CONFIG")
	if pkg_config == "" {
		return nil, "pkg-config"
	}
	env := make([dynamic]string, context.temp_allocator)
	inherited, _ := os.environ(context.temp_allocator)
	append(&env, ..inherited)
	search := os.get_env("PKG_CONFIG_PATH", context.temp_allocator)
	for prefix in ([]string{"/opt/homebrew", "/usr/local"}) {
		// Each one is put first, so the last listed wins: openssl@4, which
		// the Homebrew curl and ngtcp2 are built against.
		for keg in ([]string{"openssl@3", "openssl@4", "curl"}) {
			directory := fmt.tprintf("%s/opt/%s/lib/pkgconfig", prefix, keg)
			if os.is_dir(directory) {
				search = fmt.tprintf("%s:%s", directory, search) if search != "" else directory
			}
		}
	}
	append(&env, fmt.tprintf("PKG_CONFIG_PATH=%s", search))
	for module in modules {
		state, _, _, error := execute({pkg_config, "--exists", module}, env[:])
		if error != nil || !state.success {
			return nil, module
		}
	}
	command := make([dynamic]string, context.temp_allocator)
	append(&command, pkg_config, "--libs")
	append(&command, ..modules)
	state, output, _, error := execute(command[:], env[:])
	if error != nil || !state.success {
		return nil, modules[0]
	}
	linker := strings.trim_space(output)
	result := make([]string, 1, context.temp_allocator)
	result[0] = fmt.tprintf("-extra-linker-flags:%s", linker)
	return result, ""
}

// The modules a suite lists in its LIBRARIES file, one per line ('#' starts a
// comment). nil when the suite has no such file.
suite_libraries :: proc(directory: string) -> []string {
	bytes, error := os.read_entire_file(fmt.tprintf("%s/LIBRARIES", directory), context.temp_allocator)
	if error != nil {
		return nil
	}
	modules := make([dynamic]string, context.temp_allocator)
	text := string(bytes)
	for line in strings.split_lines_iterator(&text) {
		entry := strings.trim_space(line)
		if hash := strings.index_byte(entry, '#'); hash >= 0 {
			entry = strings.trim_space(entry[:hash])
		}
		if entry != "" {
			append(&modules, entry)
		}
	}
	return modules[:]
}
