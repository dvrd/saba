package saba_test_harness

import "core:fmt"
import "core:os"
import "core:strings"

// The TCP sockets a running program holds, listed by lsof. ok is false when
// lsof is missing or fails.
tcp_sockets :: proc(p: ^Process) -> (count: int, ok: bool) {
	lsof := tool("lsof")
	if lsof == "" && os.is_file("/usr/sbin/lsof") {
		lsof = "/usr/sbin/lsof"
	}
	if lsof == "" {
		return 0, false
	}
	state, output, _, error := execute({lsof, "-nP", "-a", "-p", fmt.tprintf("%d", p.handle.pid), "-iTCP", "-Fn"})
	// lsof exits 1 when nothing matches.
	if error != nil || (state.exit_code != 0 && state.exit_code != 1) {
		return 0, false
	}
	text := output
	for line in strings.split_lines_iterator(&text) {
		if strings.has_prefix(line, "n") {
			count += 1
		}
	}
	return count, true
}

// The threads of a running program: /proc on Linux, ps elsewhere (where the
// count includes a header line).
threads :: proc(p: ^Process) -> (count: int, ok: bool) {
	directory := fmt.tprintf("/proc/%d/task", p.handle.pid)
	if os.is_dir(directory) {
		entries, error := os.read_all_directory_by_path(directory, context.temp_allocator)
		return len(entries), error == nil
	}
	// One line per thread after a header; only differences are compared.
	// Under sh, which must not exec it in its place: os.process_wait cannot
	// wait for macOS's setuid ps itself (Permission_Denied).
	state, output, _, error := execute({"/bin/sh", "-c", fmt.tprintf("ps -M -p %d; true", p.handle.pid)})
	if error != nil || !state.success {
		return 0, false
	}
	text := output
	for line in strings.split_lines_iterator(&text) {
		if strings.trim_space(line) != "" {
			count += 1
		}
	}
	return count, true
}
