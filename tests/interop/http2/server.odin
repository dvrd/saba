package saba_interop_http2_test

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import harness "../../support/harness"
import peer "../../support/peer"

// A suite program that serves until its stdin closes.
Server :: struct {
	p:     ^harness.Process,
	input: ^os.File,
	port:  int,
}

launch :: proc(t: ^testing.T, source: string, args: ..string) -> (s: Server, ok: bool) {
	binary := harness.build_shared(t, source) or_return
	command := make([dynamic]string, context.temp_allocator)
	append(&command, binary)
	append(&command, ..args)
	// A program forked while a peer socket is open would hold it open.
	{
		sync.guard(&peer.descriptors)
		s.p, s.input, ok = harness.start_with_input(t, command[:])
	}
	if !ok {
		return
	}
	s.port, ok = harness.ready(t, s.p)
	if !ok {
		release(&s)
	}
	return
}

// Closes the program's stdin, which stops it, and checks that it exited 0
// without a sanitizer report. Its output stays readable until release.
finish :: proc(t: ^testing.T, s: ^Server, loc := #caller_location) -> bool {
	if s.input != nil {
		os.close(s.input)
		s.input = nil
	}
	code := harness.wait(s.p)
	if !testing.expectf(t, code == 0, "%s exited with %d\n%s", s.p.name, code, harness.transcript(s.p), loc = loc) {
		return false
	}
	output := harness.transcript(s.p)
	for report in ([]string{"ERROR: AddressSanitizer", "WARNING: ThreadSanitizer"}) {
		if strings.contains(output, report) {
			return testing.expectf(t, false, "%s: %s\n%s", s.p.name, report, output, loc = loc)
		}
	}
	return true
}

release :: proc(s: ^Server) {
	if s.input != nil {
		os.close(s.input)
		s.input = nil
	}
	harness.stop(s.p)
	s.p = nil
}
