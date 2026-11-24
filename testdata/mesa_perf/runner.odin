package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

bench_interrupted: bool

bench_interrupt :: proc "c" (_: posix.Signal) {
	sync.atomic_store(&bench_interrupted, true)
}

// Put Node and its children in a separate group before replacing this process.
exec_browser_driver :: proc(args: []string) -> int {
	if posix.setsid() == -1 {
		fmt.fprintln(os.stderr, "Could not isolate the browser driver:", posix.errno())
		return 2
	}
	node := os.get_env("SABA_BENCH_NODE", context.temp_allocator)
	if node == "" {
		node = "node"
	}
	argv := make([]cstring, len(args) + 3, context.temp_allocator)
	argv[0] = strings.clone_to_cstring(node, context.temp_allocator)
	argv[1] = "testdata/mesa_perf/measure.cjs"
	for arg, i in args {
		argv[i + 2] = strings.clone_to_cstring(arg, context.temp_allocator)
	}
	_ = posix.execvp(argv[0], raw_data(argv))
	fmt.fprintln(os.stderr, "Could not start Node:", posix.errno())
	return 2
}

bench_stop :: proc(child: os.Process, group: bool) {
	_, err := os.process_wait(child, 0)
	if err != .Timeout {
		return
	}
	pid := posix.pid_t(child.pid)
	if !group || posix.killpg(pid, .SIGTERM) != .OK {
		_ = os.process_terminate(child)
	}
	_, err = os.process_wait(child, 3 * time.Second)
	if err == .Timeout {
		if !group || posix.killpg(pid, .SIGKILL) != .OK {
			_ = os.process_kill(child)
		}
		_, _ = os.process_wait(child)
	}
}

// Playwright launches Chromium in its own process group on POSIX. The driver
// records that group in our private directory and clears it on orderly close.
stop_detached_browser :: proc(pid_file: string) {
	raw, err := os.read_entire_file(pid_file, context.temp_allocator)
	if err != nil {
		return
	}
	id, valid := strconv.parse_int(strings.trim_space(string(raw)))
	if valid && id > 1 && id <= int(max(i32)) {
		pid := posix.pid_t(id)
		if posix.getpgid(pid) == pid {
			_ = posix.killpg(pid, .SIGKILL)
		}
	}
}

run_benchmark :: proc(args: []string) -> int {
	if len(args) > 0 && args[0] == "--driver" {
		return exec_browser_driver(args[1:])
	}
	_ = posix.signal(.SIGINT, bench_interrupt)
	_ = posix.signal(.SIGTERM, bench_interrupt)
	_ = posix.signal(.SIGHUP, bench_interrupt)
	temp, err := os.make_directory_temp("", "saba-mesa-perf-*", context.temp_allocator)
	if err != nil {
		fmt.fprintln(os.stderr, "Could not create benchmark directory:", err)
		return 2
	}
	defer _ = os.remove_all(temp)
	executable, path_error := os.get_executable_path(context.temp_allocator)
	if path_error != nil {
		fmt.fprintln(os.stderr, "Could not locate benchmark executable:", path_error)
		return 2
	}
	ready := fmt.tprintf("%s/ready", temp)
	browser_pid := fmt.tprintf("%s/browser.pid", temp)
	if env_error := os.set_env("SABA_MESA_PERF_BROWSER_PID_FILE", browser_pid); env_error != nil {
		fmt.fprintln(os.stderr, "Could not configure browser cleanup:", env_error)
		return 2
	}
	server_args := make([dynamic]string, context.temp_allocator)
	append(&server_args, executable, "0", fmt.tprintf("%s/items.sqlite", temp), ready)
	for arg, i in args {
		if arg == "--suite" && i + 1 < len(args) {
			switch args[i + 1] {
			case "generated": append(&server_args, "--generated")
			case "windowed":  append(&server_args, "--windowed")
			}
			break
		}
	}
	server, launch_error := os.process_start(
		{
			command = server_args[:],
			stdout = os.stdout,
			stderr = os.stderr,
		},
	)
	if launch_error != nil {
		fmt.fprintln(os.stderr, "Could not start Saba benchmark server:", launch_error)
		return 2
	}
	defer bench_stop(server, false)
	port := 0
	started := time.tick_now()
	for !sync.atomic_load(&bench_interrupted) && time.tick_since(started) < 15 * time.Second {
		if raw, read_error := os.read_entire_file(ready, context.temp_allocator);
		   read_error == nil {
			candidate, valid := strconv.parse_int(strings.trim_space(string(raw)))
			if valid && candidate > 0 && candidate <= 65535 {
				port = candidate
			}
			break
		}
		result, wait_error := os.process_wait(server, 25 * time.Millisecond)
		if wait_error != .Timeout {
			fmt.fprintln(
				os.stderr,
				"Benchmark server exited before publishing its port:",
				result.exit_code,
				wait_error,
			)
			return 2
		}
	}
	if sync.atomic_load(&bench_interrupted) {
		return 130
	}
	if port == 0 {
		fmt.fprintln(
			os.stderr,
			"Benchmark server did not publish a valid port before the deadline",
		)
		return 2
	}
	command := make([dynamic]string, context.temp_allocator)
	append(&command, executable, "bench", "--driver", fmt.tprintf("http://127.0.0.1:%d", port))
	append(&command, ..args)
	driver, driver_error := os.process_start(
		{command = command[:], stdout = os.stdout, stderr = os.stderr},
	)
	if driver_error != nil {
		fmt.fprintln(os.stderr, "Could not start browser driver:", driver_error)
		return 2
	}
	defer stop_detached_browser(browser_pid)
	defer bench_stop(driver, true)
	deadline := time.tick_add(time.tick_now(), 20 * time.Minute)
	for !sync.atomic_load(&bench_interrupted) && time.tick_since(deadline) < 0 {
		result, wait_error := os.process_wait(driver, 250 * time.Millisecond)
		if wait_error == .Timeout {
			continue
		}
		if wait_error != nil {
			fmt.fprintln(os.stderr, "Could not wait for browser driver:", wait_error)
			return 2
		}
		return result.exit_code
	}
	if sync.atomic_load(&bench_interrupted) {
		return 130
	}
	fmt.fprintln(os.stderr, "Browser benchmark exceeded its 20-minute deadline")
	return 124
}
