// Running a suite program: start it, optionally with a pipe on its stdin, read
// the lines it prints, stop it.
package saba_test_harness

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

// A running program whose stdout and stderr are collected line by line.
Process :: struct {
	handle:    os.Process,
	// The reader threads allocate the lines with the allocator start ran
	// with, so stop frees them with the same one.
	allocator: runtime.Allocator,
	// Set once the process was reaped: its pid may belong to another process
	// by then, so stop must not signal it.
	reaped:    bool,
	name:      string,
	mutex:     sync.Mutex,
	lines:     [dynamic]string,
	stderr:    strings.Builder,
	readers:   [2]^thread.Thread,
	output:    [2]^os.File,
}

// Starts command. env adds variables to the inherited environment.
start :: proc(t: ^testing.T, command: []string, env: []string = nil, directory := "") -> (^Process, bool) {
	p, _, ok := launch(t, command, env, directory, false)
	return p, ok
}

// Starts command like start, with a pipe on its stdin for a program that takes
// commands there. The caller writes with send_input and closes input
// (os.close) after stop; a program that reads until end of file takes that as
// its last command.
start_with_input :: proc(
	t: ^testing.T,
	command: []string,
	env: []string = nil,
	directory := "",
) -> (
	p: ^Process,
	input: ^os.File,
	ok: bool,
) {
	ignore_broken_pipes()
	return launch(t, command, env, directory, true)
}

// A write to the stdin of a program that already exited raises SIGPIPE, which
// would end the whole test binary without a word. Ignored, the write returns
// an error the test reports instead.
ignore_broken_pipes :: proc() {
	_ = posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
}

@(private)
launch :: proc(
	t: ^testing.T,
	command: []string,
	env: []string,
	directory: string,
	piped: bool,
) -> (
	p: ^Process,
	input: ^os.File,
	ok: bool,
) {
	environment: []string
	if env != nil {
		inherited, _ := os.environ(context.temp_allocator)
		joined := make([dynamic]string, context.temp_allocator)
		append(&joined, ..inherited)
		append(&joined, ..env)
		environment = joined[:]
	}
	error: os.Error
	p, input, error = spawn(command, environment, directory, piped)
	if error != nil {
		testing.expectf(t, false, "could not start %s: %v", command[0], error)
		return nil, nil, false
	}
	return p, input, true
}

// Starts command with env as its whole environment (nil: this one). The pipes
// are made and the program forked under descriptors (see descriptors.odin).
@(private)
spawn :: proc(
	command: []string,
	env: []string,
	directory: string,
	piped: bool,
) -> (
	p: ^Process,
	input: ^os.File,
	error: os.Error,
) {
	stdin_read, stdin_write: ^os.File
	stdout_read, stdout_write, stderr_read, stderr_write: ^os.File
	handle: os.Process
	{
		sync.guard(&descriptors)
		if piped {
			stdin_read, stdin_write = os.pipe() or_return
		}
		e1, e2: os.Error
		stdout_read, stdout_write, e1 = os.pipe()
		stderr_read, stderr_write, e2 = os.pipe()
		if e1 != nil || e2 != nil {
			for f in ([]^os.File{stdin_read, stdin_write, stdout_read, stdout_write, stderr_read, stderr_write}) {
				if f != nil {
					os.close(f)
				}
			}
			return nil, nil, e1 if e1 != nil else e2
		}
		handle, error = os.process_start(
			{
				command = command,
				env = env,
				working_dir = directory,
				stdin = stdin_read,
				stdout = stdout_write,
				stderr = stderr_write,
			},
		)
	}
	if stdin_read != nil {
		os.close(stdin_read)
	}
	os.close(stdout_write)
	os.close(stderr_write)
	if error != nil {
		if stdin_write != nil {
			os.close(stdin_write)
		}
		os.close(stdout_read)
		os.close(stderr_read)
		return nil, nil, error
	}
	p = new(Process)
	p.allocator = context.allocator
	p.name = strings.clone(last_segment(command[0]))
	p.lines.allocator = context.allocator
	strings.builder_init(&p.stderr)
	p.handle = handle
	p.output = {stdout_read, stderr_read}
	p.readers[0] = thread.create_and_start_with_poly_data(p, read_stdout)
	p.readers[1] = thread.create_and_start_with_poly_data(p, read_stderr)
	return p, stdin_write, nil
}

// Runs command to its end, like os.process_exec, with env as its whole
// environment (nil: this one), forked like every program the harness starts.
// The output is in the temporary allocator.
execute :: proc(command: []string, env: []string = nil) -> (state: os.Process_State, output, errors: string, error: os.Error) {
	p: ^Process
	p, _, error = spawn(command, env, "", false)
	if error != nil {
		return
	}
	defer stop(p)
	state, error = os.process_wait(p.handle)
	p.reaped = error == nil
	for reader in p.readers {
		thread.join(reader)
	}
	b := strings.builder_make(context.temp_allocator)
	for line in p.lines {
		fmt.sbprintln(&b, line)
	}
	return state, strings.to_string(b), stderr_text(p), error
}

@(private)
read_stdout :: proc(p: ^Process) {
	context.allocator = p.allocator
	buffer: [4096]u8
	pending := strings.builder_make()
	defer strings.builder_destroy(&pending)
	for {
		n, error := os.read(p.output[0], buffer[:])
		if n <= 0 || error != nil {
			break
		}
		for b in buffer[:n] {
			if b != '\n' {
				strings.write_byte(&pending, b)
				continue
			}
			sync.lock(&p.mutex)
			append(&p.lines, strings.clone(strings.to_string(pending)))
			sync.unlock(&p.mutex)
			strings.builder_reset(&pending)
		}
	}
	if strings.builder_len(pending) > 0 {
		sync.lock(&p.mutex)
		append(&p.lines, strings.clone(strings.to_string(pending)))
		sync.unlock(&p.mutex)
	}
}

@(private)
read_stderr :: proc(p: ^Process) {
	context.allocator = p.allocator
	buffer: [4096]u8
	for {
		n, error := os.read(p.output[1], buffer[:])
		if n <= 0 || error != nil {
			break
		}
		sync.lock(&p.mutex)
		strings.write_bytes(&p.stderr, buffer[:n])
		sync.unlock(&p.mutex)
	}
}

// Writes a command to the program's stdin.
send_input :: proc(t: ^testing.T, input: ^os.File, text: string, loc := #caller_location) -> bool {
	n, error := os.write_string(input, text)
	return testing.expectf(t, error == nil && n == len(text), "could not write %q to the program: %v", text, error, loc = loc)
}

// Waits for the first stdout line that starts with prefix and takes only that
// line: the lines before it stay for later calls and for lines_with, so
// replies to commands may interleave with lines the program prints on its own.
expect_line :: proc(
	t: ^testing.T,
	p: ^Process,
	prefix: string,
	timeout := 10 * time.Second,
	loc := #caller_location,
) -> (
	string,
	bool,
) {
	deadline := time.tick_add(time.tick_now(), timeout)
	last_look := false
	for {
		sync.lock(&p.mutex)
		for line, index in p.lines {
			if strings.has_prefix(line, prefix) {
				found := strings.clone(line, context.temp_allocator)
				ordered_remove(&p.lines, index)
				delete(line, p.allocator)
				sync.unlock(&p.mutex)
				return found, true
			}
		}
		sync.unlock(&p.mutex)
		if last_look || time.tick_since(deadline) >= 0 {
			break
		}
		if !p.reaped {
			if state, error := os.process_wait(p.handle, 0); error == nil && state.exited {
				p.reaped = true
			}
		}
		if p.reaped {
			// Let the readers drain what it printed before it exited.
			time.sleep(20 * time.Millisecond)
			last_look = true
			continue
		}
		time.sleep(2 * time.Millisecond)
	}
	testing.expectf(t, false, "%s printed no line starting %q\n%s", p.name, prefix, transcript(p), loc = loc)
	return "", false
}

// The port of a "<prefix><port>" line, taken with expect_line. prefix is
// "READY " for suite programs; examples print their own. A program that exits
// ends the wait at once, so the bound only guards one that hangs: it is
// generous because starting a program on a loaded machine can take seconds.
ready :: proc(
	t: ^testing.T,
	p: ^Process,
	timeout := 60 * time.Second,
	prefix := "READY ",
	loc := #caller_location,
) -> (
	int,
	bool,
) {
	line, ok := expect_line(t, p, prefix, timeout, loc)
	if !ok {
		return 0, false
	}
	port := 0
	for c in line[len(prefix):] {
		if c < '0' || c > '9' {
			break
		}
		port = port * 10 + int(c - '0')
	}
	return port, testing.expectf(t, port > 0, "%s printed %q", p.name, line, loc = loc)
}

// Every stdout line so far that starts with prefix, oldest first. Unlike
// expect_line it takes nothing.
lines_with :: proc(p: ^Process, prefix: string, allocator := context.temp_allocator) -> []string {
	sync.lock(&p.mutex)
	defer sync.unlock(&p.mutex)
	found := make([dynamic]string, allocator)
	for line in p.lines {
		if strings.has_prefix(line, prefix) {
			append(&found, strings.clone(line, allocator))
		}
	}
	return found[:]
}

// Waits until at least count stdout lines start with prefix, taking nothing.
await_lines :: proc(
	t: ^testing.T,
	p: ^Process,
	prefix: string,
	count := 1,
	timeout := 10 * time.Second,
	loc := #caller_location,
) -> bool {
	deadline := time.tick_add(time.tick_now(), timeout)
	for time.tick_since(deadline) < 0 {
		if len(lines_with(p, prefix)) >= count {
			return true
		}
		time.sleep(2 * time.Millisecond)
	}
	return testing.expectf(
		t,
		false,
		"%s printed fewer than %d lines starting %q\n%s",
		p.name,
		count,
		prefix,
		transcript(p),
		loc = loc,
	)
}

// The last space-separated field of a line.
last_field :: proc(line: string) -> string {
	if space := strings.last_index_byte(line, ' '); space >= 0 {
		return line[space + 1:]
	}
	return line
}

// What the program printed so far, stdout then stderr, for failure messages.
transcript :: proc(p: ^Process) -> string {
	sync.lock(&p.mutex)
	defer sync.unlock(&p.mutex)
	b := strings.builder_make(context.temp_allocator)
	for line in p.lines {
		fmt.sbprintln(&b, line)
	}
	fmt.sbprint(&b, strings.to_string(p.stderr))
	return strings.to_string(b)
}

// What the program wrote to stderr so far.
stderr_text :: proc(p: ^Process, allocator := context.temp_allocator) -> string {
	sync.lock(&p.mutex)
	defer sync.unlock(&p.mutex)
	return strings.clone(strings.to_string(p.stderr), allocator)
}

// Whether the program still runs; a program that exited is reaped here.
running :: proc(p: ^Process) -> bool {
	if p.reaped {
		return false
	}
	state, error := os.process_wait(p.handle, 0)
	if error == nil && state.exited {
		p.reaped = true
		return false
	}
	return true
}

// Waits for the program to exit and returns its exit code, or -1 when it did
// not exit in time (it is killed then).
wait :: proc(p: ^Process, timeout := 10 * time.Second) -> int {
	state, error := os.process_wait(p.handle, timeout)
	if error != nil || !state.exited {
		_ = os.process_kill(p.handle)
		_, _ = os.process_wait(p.handle)
		p.reaped = true
		return -1
	}
	p.reaped = true
	return state.exit_code
}

// Waits for the program to exit and checks that it exited 0 without a
// sanitizer report. The readers have drained its output when this returns.
exited_cleanly :: proc(t: ^testing.T, p: ^Process, timeout := 10 * time.Second, loc := #caller_location) -> bool {
	code := wait(p, timeout)
	for reader in p.readers {
		thread.join(reader)
	}
	if !testing.expectf(t, code == 0, "%s exited with %d\n%s", p.name, code, transcript(p), loc = loc) {
		return false
	}
	errors := stderr_text(p)
	for report in ([]string{"ERROR: AddressSanitizer", "WARNING: ThreadSanitizer"}) {
		if strings.contains(errors, report) {
			return testing.expectf(t, false, "%s: %s\n%s", p.name, report, errors, loc = loc)
		}
	}
	return true
}

// Kills the program if it still runs, joins the readers and frees p.
stop :: proc(p: ^Process) {
	if p == nil {
		return
	}
	if !p.reaped {
		if state, error := os.process_wait(p.handle, 0); error != nil || !state.exited {
			_ = os.process_kill(p.handle)
			_, _ = os.process_wait(p.handle, 5 * time.Second)
		}
	}
	for reader in p.readers {
		thread.join(reader)
		thread.destroy(reader)
	}
	os.close(p.output[0])
	os.close(p.output[1])
	context.allocator = p.allocator
	for line in p.lines {
		delete(line)
	}
	delete(p.lines)
	strings.builder_destroy(&p.stderr)
	delete(p.name)
	free(p)
}
