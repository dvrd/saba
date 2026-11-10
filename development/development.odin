package saba_development

import "core:fmt"
import "core:hash"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

Development :: struct {
	// Empty preserves ODIN environment then the historical "odin" default.
	compiler: string,
	// Explicit source roots need not live under the compiler's SDK root.
	watch_directories: []string,
	package_directory: string,
	shared_packages:   []string,
	build_arguments:   []string,
}

@(private)
development_stopping: bool
@(private)
DEVELOPMENT_CHILD :: "SABA_DEVELOPMENT_CHILD"

@(private)
development_signal :: proc "c" (signal: posix.Signal) {
	sync.atomic_store(&development_stopping, true)
}

// Call before opening databases or listeners. The supervisor runs the current
// executable as a child; that child returns handled=false and starts normally.
// Only successful, current builds replace the running child.
develop :: proc(config: Development) -> (handled, success: bool) {
	if os.get_env(DEVELOPMENT_CHILD, context.temp_allocator) != "" do return false, true
	handled = true
	if !os.is_dir(config.package_directory) {
		log.error("Development package directory is missing"); return
	}
	compiler := development_compiler(config)
	paths, paths_ready := development_paths(config, compiler)
	if !paths_ready {return}
	executable, located := os.get_executable_path(context.temp_allocator)
	if located != nil {
		log.error("Could not locate development executable"); return
	}
	directory, created := os.make_directory_temp("", "saba-development-*", context.temp_allocator)
	if created != nil {
		log.error("Could not create development build directory"); return
	}
	defer _ = os.remove_all(directory)
	environment := make([dynamic]string, context.temp_allocator)
	inherited, env_error := os.environ(context.temp_allocator)
	if env_error != nil {
		log.error("Could not inherit development environment"); return
	}
	append(&environment, ..inherited)
	append(&environment, DEVELOPMENT_CHILD + "=1")
	command := make([]string, len(os.args), context.temp_allocator)
	copy(command, os.args); command[0] = executable
	observed, scanned := development_signature(paths[:]); if !scanned do return
	child, started := os.process_start(
		{
			command = command,
			env = environment[:],
			stdin = os.stdin,
			stdout = os.stdout,
			stderr = os.stderr,
		},
	)
	if started != nil {
		log.error("Could not start development server", started); return
	}
	active := true
	defer if active do development_stop(child)
	sync.atomic_store(&development_stopping, false)
	old_int := posix.signal(.SIGINT, development_signal)
	old_term := posix.signal(.SIGTERM, development_signal)
	defer {_ = posix.signal(.SIGINT, old_int); _ = posix.signal(.SIGTERM, old_term)}
	log.info("Backend reload enabled: watching application and shared package sources")
	development_supervise(
		config, compiler, directory, executable, paths, command, environment[:],
		&child, &active, observed,
	)
	if command[0] != executable do delete(command[0])
	return true, true
}

@(private)
development_compiler :: proc(config:Development)->string {
	if config.compiler!="" do return config.compiler
	compiler:=os.get_env("ODIN",context.temp_allocator)
	return "odin" if compiler=="" else compiler
}

@(private)
development_paths :: proc(config: Development, compiler: string) -> ([]string, bool) {
	paths := make([dynamic]string, context.temp_allocator)
	append(&paths, config.package_directory)
	if len(config.watch_directories)>128 do return nil,false
	for directory in config.watch_directories {
		if directory=="" || !os.is_dir(directory) {
			log.error("Development watched directory is missing:",directory)
			return nil,false
		}
		append(&paths,directory)
	}
	if len(config.shared_packages) > 0 {
		state, output, errors, err := os.process_exec(
			{command = {compiler, "root"}},
			context.temp_allocator,
		)
		if err != nil || !state.success {
			log.error("Could not locate Odin shared packages", string(errors)); return nil, false
		}
		root := strings.trim_space(string(output))
		for name in config.shared_packages {
			if name == "" || strings.contains_any(name, "/\\") || name == "." || name == ".." {
				log.error("Invalid shared package name"); return nil, false
			}
			path, _ := filepath.join({root, "shared", name}, context.temp_allocator)
			if !os.is_dir(path) {
				log.error("Development shared package is missing:", path); return nil, false
			}
			append(&paths, path)
		}
	}
	return paths[:], true
}

// The caller owns the process handle and command storage until shutdown. This
// loop ends on SIGINT/SIGTERM; no build can replace a child after that signal.
@(private)
development_supervise :: proc(
	config: Development, compiler, directory, executable: string,
	paths, command, environment: []string, child: ^os.Process, active: ^bool,
	observed_start: u64,
) {
	observed, published := observed_start, observed_start
	generation := 0
	for !sync.atomic_load(&development_stopping) {
		time.sleep(250 * time.Millisecond)
		if active^ {
			state, err := os.process_wait(child^, 0)
			if err == nil && state.exited {
				active^ = false
				log.error("Development server exited; edit a watched file to rebuild")
			}
		}
		current, valid := development_signature(paths[:]); if !valid do continue
		if current != observed {
			observed = current; continue
		}
		if current == published do continue
		published = current
		generation += 1
		// Scratch output never overwrites the executable that is still serving.
		next := fmt.aprintf("%s/server-%d", directory, generation)
		built, build_started := development_build(config, compiler, next)
		latest, checked := development_signature(paths[:])
		if !built || !checked || latest != current || sync.atomic_load(&development_stopping) {
			_ = os.remove(next); delete(next)
			if !sync.atomic_load(&development_stopping) {
				if !built {
					log.error(
						"Build failed; the previous server is unchanged. " +
						"Save a correction to retry.",
					)
				} else {
					log.info("Sources changed during the build; waiting for the latest edits")
				}
			}
			continue
		}
		log.infof(
			"Backend rebuilt in %.2f seconds; restarting",
			f64(time.tick_since(build_started))/f64(time.Second),
		)
		if active^ do development_stop(child^)
		active^ = false
		previous := command[0]; command[0] = next
		next_child, start_error := os.process_start(
			{
				command = command,
				env = environment[:],
				stdin = os.stdin,
				stdout = os.stdout,
				stderr = os.stderr,
			},
		)
		child^ = next_child
		if start_error != nil {
			log.error("Could not start rebuilt server", start_error)
		} else {
			active^ = true; log.info("Backend restarted; connected browsers will refresh")
		}
		if previous != executable {
			_ = os.remove(previous); delete(previous)
		}
	}
}

@(private)
development_build :: proc(config: Development, compiler, next: string) -> (bool, time.Tick) {
	args := make([dynamic]string)
	append(&args, compiler, "build", config.package_directory, "-warnings-as-errors")
	optimized := false
	for argument in config.build_arguments {
		if strings.has_prefix(argument, "-o:") do optimized = true
	}
	if !optimized do append(&args, "-o:none")
	append(&args, ..config.build_arguments)
	flag := fmt.aprintf("-out:%s", next); append(&args, flag)
	log.info("Server source changed; rebuilding while the current server stays available")
	build_started := time.tick_now()
	builder, err := os.process_start(
		{command = args[:], stdout = os.stdout, stderr = os.stderr},
	)
	built := false
	if err == nil {
		builder_running := true
		for !sync.atomic_load(&development_stopping) {
			state, waiting := os.process_wait(builder, 100 * time.Millisecond)
			if waiting == nil && state.exited {
				builder_running = false; built = state.success && state.exit_code == 0; break
			}
			if waiting != nil && waiting != os.General_Error.Timeout {
				development_stop(builder); builder_running = false; break
			}
		}
		if builder_running do development_stop(builder)
	}
	delete(args); delete(flag)
	return built, build_started
}

@(private)
development_stop :: proc(process: os.Process) {
	_ = os.process_terminate(process)
	state, err := os.process_wait(process, 2 * time.Second)
	if err != nil || !state.exited {
		_ = os.process_kill(process); _, _ = os.process_wait(process)
	}
}

@(private)
development_signature :: proc(paths: []string) -> (signature: u64, ok: bool) {
	ok = true
	for path in paths {
		walker := os.walker_create(path)
		for info in os.walker_walk(&walker) {
			if info.type == .Directory {
				name := filepath.base(info.fullpath)
				if name == ".git" || name == ".cruft" || name == "node_modules" {
					os.walker_skip_dir(&walker)
				}
			}
			if info.type != .Regular do continue
			extension := filepath.ext(info.fullpath)
			if extension != ".odin" && extension != ".js" && extension != ".json" &&
			   extension != ".sql" && extension != ".html" && extension != ".css" &&
			   extension != ".c" && extension != ".h" {
				continue
			}
			if strings.contains(info.fullpath, "/.git/") do continue
			bytes, err := os.read_entire_file(info.fullpath, context.allocator)
			if err != nil {
				ok = false; break
			}
			signature ~= hash.fnv64a(bytes, hash.fnv64a(transmute([]byte)info.fullpath))
			delete(bytes)
		}
		_, err := os.walker_error(&walker)
		os.walker_destroy(&walker)
		if err != nil do ok = false
		if !ok do return
	}
	return
}
