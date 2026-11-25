package saba_ui_test

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

// Chromium is launched directly (chromium_path). Firefox and WebKit run the
// same fixture pages through tests/browsers/driver.mjs, a Playwright driver.
// Without Node, Playwright or the engine's browser build the engine's tests
// log a skip notice and assert nothing (README.md describes the setup).
Engine :: enum {
	Chromium,
	Firefox,
	WebKit,
}

ENGINE_SKIP :: 77
ENGINE_DRIVER :: "tests/browsers/driver.mjs"

// Each Playwright engine runs one fixture at a time. Every fixture also
// prepares its own Saba server, so running all of them at once on a busy
// machine starves the server deadlines rather than testing anything more.
engine_gates: [Engine]sync.Mutex

engine_leave :: proc(engine: Engine) {
	if engine != .Chromium {
		sync.mutex_unlock(&engine_gates[engine])
	}
}

// A queued fixture waits for the others of its engine within its deadline.
engine_timeout :: proc(engine: Engine, timeout: time.Duration) -> time.Duration {
	return timeout if engine == .Chromium else 3 * timeout
}

engine_name :: proc(engine: Engine) -> string {
	switch engine {
	case .Chromium:
		return "Chromium"
	case .Firefox:
		return "Firefox"
	case .WebKit:
		return "WebKit"
	}
	return ""
}

// The driver's name for the engine: the Playwright browser type.
driver_engine :: proc(engine: Engine) -> string {
	return strings.to_lower(engine_name(engine), context.temp_allocator)
}

node_path :: proc() -> string {
	if path := os.get_env("SABA_NODE", context.temp_allocator); path != "" {
		return path
	}
	return "node"
}

// Waits for the engine's turn and reports whether it can run here. A missing
// engine is logged as a skip notice. Chromium is expected to be present and
// is not queued. Each true result is paired with engine_leave.
engine_enter :: proc(t: ^testing.T, engine: Engine, test: string) -> bool {
	if engine == .Chromium {
		return true
	}
	sync.mutex_lock(&engine_gates[engine])
	available := probe_engine(t, engine, test)
	if !available {
		sync.mutex_unlock(&engine_gates[engine])
	}
	return available
}

probe_engine :: proc(t: ^testing.T, engine: Engine, test: string) -> bool {
	a := context.temp_allocator
	result, output, errors, error := os.process_exec(
		{command = {node_path(), ENGINE_DRIVER, driver_engine(engine), "probe"}},
		a,
	)
	if error != nil {
		log.warnf("Skipping %s in %s: Node is not available (%v). Set SABA_NODE.", test, engine_name(engine), error)
		return false
	}
	if result.exit_code == ENGINE_SKIP {
		log.warnf("Skipping %s in %s: %s", test, engine_name(engine), strings.trim_prefix(strings.trim_space(string(output)), "SKIP: "))
		return false
	}
	if result.success {
		log.infof("Running %s in %s %s", test, engine_name(engine), strings.trim_space(string(output)))
	}
	return testing.expectf(
		t,
		result.success,
		"could not start %s through Playwright (exit %d, signal %d): %s%s",
		engine_name(engine),
		result.exit_code,
		result.signal,
		string(output),
		string(errors),
	)
}

// The Playwright driver command that loads url in engine. "dump" prints the
// document once #result holds a result; "navigate" keeps the browser open.
driver_command :: proc(engine: Engine, mode, url: string, seconds: int) -> []string {
	command := make([]string, 6, context.temp_allocator)
	command[0] = node_path()
	command[1] = ENGINE_DRIVER
	command[2] = driver_engine(engine)
	command[3] = mode
	command[4] = url
	command[5] = fmt.tprint(seconds)
	return command
}
