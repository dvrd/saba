package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

SHARED_FLAG :: "-collection:shared="
SUITE_CHILD :: "--saba-suite-child"
USAGE :: `Usage: task test -- [options] -- [Odin flags]

  --odin PATH       Odin compiler (default: ODIN or odin)
  --shared PATH     use a development collection (also WEBTOOLS_SHARED). By default
                    krs installs the project lock into a fresh, private test root.
  --package NAME   limit to a package relative to tests/ (use . for the library root)
  --internal-only  run only the private package suites
  --help           show this help
`

Options :: struct {
	compiler, shared, package_name: string,
	internal_only, help:            bool,
	flags:                          [dynamic]string,
}

interrupted: bool

main :: proc() {
	if len(os.args) > 2 && os.args[1] == SUITE_CHILD {
		os.exit(exec_suite(os.args[2:]))
	}
	_ = posix.signal(.SIGINT, interrupt)
	_ = posix.signal(.SIGTERM, interrupt)
	_ = posix.signal(.SIGHUP, interrupt)
	os.exit(run())
}

interrupt :: proc "c" (_: posix.Signal) {
	sync.atomic_store(&interrupted, true)
}

// Give each suite its own process group before replacing this process with Odin.
// Both the compiler and any fixtures it starts can then be stopped together.
exec_suite :: proc(command: []string) -> int {
	if posix.setsid() == -1 {
		fmt.fprintln(os.stderr, "Could not isolate Odin suite process group:", posix.errno())
		return 2
	}
	arguments := make([]cstring, len(command) + 1, context.temp_allocator)
	for arg, index in command {
		arguments[index] = strings.clone_to_cstring(arg, context.temp_allocator)
	}
	_ = posix.execvp(arguments[0], raw_data(arguments))
	fmt.fprintln(os.stderr, "Could not execute Odin:", posix.errno())
	return 2
}

run :: proc() -> int {
	options, valid := parse_options(os.args[1:])
	if !valid {
		fmt.fprint(os.stderr, USAGE)
		return 2
	}
	if options.help {
		fmt.print(USAGE)
		return 0
	}
	if !locate_toolchain(&options) {
		return 2
	}

	suites, found := discover_suites(options)
	if !found {
		return 2
	}
	work, created := os.make_directory_temp("", "saba-tests-*", context.temp_allocator)
	if created != nil {
		return fail("Could not create test directory", created)
	}
	defer _ = os.remove_all(work)

	// Krs excludes a project's own shared: imports by its directory name.
	repository := join(work, "saba")
	if error := os.make_directory(repository); error != nil {
		return fail("Could not create staged repository", error)
	}
	// examples/ is built by the loopback harnesses (tests/streaming.py).
	for directory in ([]string{"src", "tests", "testdata", "examples"}) {
		if !os.is_dir(directory) {
			continue
		}
		if error := os.copy_directory_all(join(repository, directory), directory); error != nil {
			return fail(fmt.tprintf("Could not stage %s", directory), error)
		}
	}
	if error := os.make_directory(join(repository, ".krs")); error != nil {
		return fail("Could not create staged lock directory", error)
	}
	if error := os.copy_file(join(repository, ".krs/packages.json"), ".krs/packages.json"); error != nil {
		return fail("Could not stage .krs/packages.json", error)
	}
	shared := join(work, "shared")
	if options.shared == "" {
		if !install_locked(work, repository) {
			return 2
		}
	} else {
		if error := stage_shared(options.shared, shared); error != nil {
			return fail("Could not stage shared collection", error)
		}
		fmt.println("Staged development collection from", options.shared)
	}
	if error := os.symlink(join(repository, "src"), join(shared, "saba")); error != nil {
		return fail("Could not mount Saba in the test collection", error)
	}

	if error := os.set_env("ODIN", options.compiler); error != nil {
		return fail("Could not set test compiler", error)
	}
	if error := os.set_env("SABA_TEST_SHARED", shared); error != nil {
		return fail("Could not set test collection", error)
	}

	append(&options.flags, fmt.tprintf("%s%s", SHARED_FLAG, shared))
	has_output := false
	for flag in options.flags {
		has_output ||= strings.has_prefix(flag, "-out:")
	}
	if !has_output {
		append(&options.flags, fmt.tprintf("-out:%s", join(work, "test-suite")))
	}
	runner, located := os.get_executable_path(context.temp_allocator)
	if located != nil {
		return fail("Could not locate test runner", located)
	}
	for suite in suites {
		if sync.atomic_load(&interrupted) {
			return 130
		}
		status := run_suite(options, repository, suite, runner)
		if status != 0 {
			return status
		}
	}
	return 0
}

parse_options :: proc(args: []string) -> (options: Options, valid: bool) {
	options.compiler = os.get_env("ODIN", context.temp_allocator)
	if options.compiler == "" {
		options.compiler = "odin"
	}
	options.shared = os.get_env("WEBTOOLS_SHARED", context.temp_allocator)
	options.package_name = "all"
	options.flags.allocator = context.temp_allocator

	args := args
	forward := false
	for len(args) > 0 {
		arg := args[0]
		args = args[1:]
		if strings.has_prefix(arg, SHARED_FLAG) {
			options.shared = strings.trim_prefix(arg, SHARED_FLAG)
			continue
		}
		if forward {
			append(&options.flags, arg)
			continue
		}
		switch arg {
		case "--":
			forward = true
		case "--help", "-h":
			options.help = true
		case "--internal-only":
			options.internal_only = true
		case "--odin", "--shared", "--package":
			if len(args) == 0 || strings.has_prefix(args[0], "-") {
				fmt.fprintln(os.stderr, "Missing value for", arg)
				return
			}
			switch arg {
			case "--odin":
				options.compiler = args[0]
			case "--shared":
				options.shared = args[0]
			case "--package":
				options.package_name = args[0]
			}
			args = args[1:]
		case:
			append(&options.flags, arg)
		}
	}
	return options, true
}

locate_toolchain :: proc(options: ^Options) -> bool {
	if strings.contains_any(options.compiler, "/\\") {
		compiler, error := filepath.abs(options.compiler, context.temp_allocator)
		if error != nil {
			fmt.fprintln(os.stderr, "Could not resolve Odin compiler:", error)
			return false
		}
		options.compiler = compiler
	}
	if options.shared == "" {
		return true
	}
	shared, error := filepath.abs(options.shared, context.temp_allocator)
	if error != nil || !os.is_dir(shared) {
		fmt.fprintln(os.stderr, "Shared collection not found:", options.shared)
		return false
	}
	options.shared = shared
	return true
}

discover_suites :: proc(options: Options) -> ([]string, bool) {
	found := make(map[string]bool, context.temp_allocator)
	test_root, located := filepath.abs("tests", context.temp_allocator)
	if located != nil {
		fmt.fprintln(os.stderr, "Could not locate tests:", located)
		return nil, false
	}
	walker := os.walker_create(test_root)
	defer os.walker_destroy(&walker)
	for entry in os.walker_walk(&walker) {
		if entry.type == .Directory &&
		   (strings.has_prefix(entry.name, ".") || entry.name == "__pycache__") {
			os.walker_skip_dir(&walker)
		}
		if entry.type != .Regular || !strings.has_suffix(entry.name, "_test.odin") {
			continue
		}
		directory, error := filepath.rel(
			test_root,
			filepath.dir(entry.fullpath),
			context.temp_allocator,
		)
		if error != nil {
			fmt.fprintln(os.stderr, "Could not resolve test suite:", entry.fullpath, error)
			return nil, false
		}
		package_name := directory
		private := filepath.base(directory) == "internal"
		if private {
			package_name = filepath.dir(directory)
			if package_name == "" {
				package_name = "."
			}
		}
		if (!options.internal_only || private) &&
		   (options.package_name == "all" || options.package_name == package_name) {
			found[directory] = true
		}
	}
	if path, error := os.walker_error(&walker); error != nil {
		fmt.fprintln(os.stderr, "Could not read test suites:", path, error)
		return nil, false
	}
	if len(found) == 0 {
		fmt.fprintln(os.stderr, "No matching test suites")
		return nil, false
	}
	suites := make([]string, len(found), context.temp_allocator)
	index := 0
	for suite in found {
		suites[index] = suite
		index += 1
	}
	slice.sort(suites)
	return suites, true
}

install_locked :: proc(root, repository: string) -> bool {
	result, output, errors, error := os.process_exec(
		{command = {"krs", "install", "--frozen", fmt.tprintf("--root=%s", root)}, working_dir = repository},
		context.temp_allocator,
	)
	if error != nil || !result.success {
		fmt.fprintln(os.stderr, "Could not install the frozen test collection:", error, string(output), string(errors))
		return false
	}
	fmt.println("Installed dependencies from .krs/packages.json")
	return true
}

stage_shared :: proc(source, destination: string) -> os.Error {
	os.make_directory(destination) or_return
	directory := os.open(source) or_return
	defer _ = os.close(directory)
	entries := os.read_directory(directory, -1, context.temp_allocator) or_return
	for entry in entries {
		if entry.name == "saba" || strings.has_prefix(entry.name, ".") {
			continue
		}
		target := join(destination, entry.name)
		#partial switch entry.type {
		case .Directory:
			os.copy_directory_all(target, entry.fullpath) or_return
		case .Regular:
			os.copy_file(target, entry.fullpath) or_return
		case .Symlink:
			os.symlink(entry.fullpath, target) or_return
		}
	}
	return nil
}

run_suite :: proc(options: Options, repository, suite, runner: string) -> int {
	source := join(join(repository, "tests"), suite)
	target := source
	if filepath.base(suite) == "internal" {
		target = join(join(repository, "src"), filepath.dir(suite))
		if error := stage_private(source, target); error != nil {
			return fail(fmt.tprintf("Could not stage private tests for %s", suite), error)
		}
	}
	// Later suites build the staged library itself (the loopback harnesses do,
	// some with -vet); leftover private test files would be part of that build.
	defer if target != source {
		unstage_private(source, target)
	}

	command := make([dynamic]string, context.temp_allocator)
	append(&command, runner, SUITE_CHILD, options.compiler, "test", target)
	append(&command, ..options.flags[:])
	fmt.println("Testing", join("tests", suite))
	process, started := os.process_start(
		{command = command[:], working_dir = repository, stdout = os.stdout, stderr = os.stderr},
	)
	if started != nil {
		return fail("Could not start Odin", started)
	}
	deadline := time.tick_add(time.tick_now(), 5 * time.Minute)
	for !sync.atomic_load(&interrupted) && time.tick_since(deadline) < 0 {
		result, error := os.process_wait(process, 250 * time.Millisecond)
		if error == .Timeout {
			continue
		}
		if error != nil {
			kill_suite(process)
			return fail("Could not wait for Odin", error)
		}
		return result.exit_code
	}
	kill_suite(process)
	if sync.atomic_load(&interrupted) {
		return 130
	}
	fmt.fprintln(os.stderr, "Test timed out:", suite)
	return 124
}

kill_suite :: proc(process: os.Process) {
	if posix.killpg(posix.pid_t(process.pid), .SIGKILL) != .OK {
		_ = os.process_kill(process)
	}
	_, _ = os.process_wait(process)
}

stage_private :: proc(source, target: string) -> os.Error {
	directory := os.open(source) or_return
	defer _ = os.close(directory)
	entries := os.read_directory(directory, -1, context.temp_allocator) or_return
	for entry in entries {
		if entry.type == .Regular && strings.has_suffix(entry.name, ".odin") {
			os.copy_file(join(target, entry.name), entry.fullpath) or_return
		}
	}
	return nil
}

unstage_private :: proc(source, target: string) {
	directory, opened := os.open(source)
	if opened != nil {
		return
	}
	defer _ = os.close(directory)
	entries, _ := os.read_directory(directory, -1, context.temp_allocator)
	for entry in entries {
		if entry.type == .Regular && strings.has_suffix(entry.name, ".odin") {
			_ = os.remove(join(target, entry.name))
		}
	}
}

join :: proc(left, right: string) -> string {
	path, error := filepath.join({left, right}, context.temp_allocator)
	assert(error == nil)
	return path
}

fail :: proc(message: string, error: os.Error) -> int {
	fmt.fprintf(os.stderr, "%s: %v\n", message, error)
	return 2
}
