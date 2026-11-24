package saba_javascript_test

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

// The browser runtime's logic that needs no DOM (scheduler, reads, mutations,
// editor, window math, entries) is exercised by Node's own test runner. This
// suite runs it so `task test` covers it. Chromium cases live in tests/ui.
@(test)
runtime_modules_under_node :: proc(t: ^testing.T) {
	a := context.temp_allocator
	node := os.get_env("SABA_NODE", a)
	if node == "" {
		node = "node"
	}
	_, _, _, located := os.process_exec({command = {node, "--version"}}, a)
	if located != nil {
		log.warnf("Skipping the JavaScript runtime tests: %s is not available (%v). Set SABA_NODE.", node, located)
		return
	}
	directory := "tests/javascript"
	if !os.is_dir(directory) {
		directory = "."
	}
	state, output, errors, started := os.process_exec(
		{command = {node, "--test", "--test-reporter=spec"}, working_dir = directory},
		a,
	)
	if !testing.expectf(t, started == nil, "could not run node --test: %v", started) {
		return
	}
	testing.expectf(
		t,
		state.success && strings.contains(string(output), "fail 0"),
		"node --test failed (exit %d):\n%s\n%s",
		state.exit_code,
		string(output),
		string(errors),
	)
}
