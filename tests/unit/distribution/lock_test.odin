package saba_distribution_test

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

Pin :: struct {
	name, source, tag, commit, hash: string,
}
Lock :: struct {
	format:   int,
	packages: []Pin,
}

@(test)
frozen_kessel_verifies_the_recorded_source :: proc(t: ^testing.T) {
	a := context.temp_allocator
	file, err := os.read_entire_file(".krs/packages.json", a)
	if !testing.expect(t, err == nil) {
		return
	}
	lock: Lock
	if !testing.expect(t, json.unmarshal(file, &lock, allocator = a) == nil) {
		return
	}
	pin: Pin
	for candidate in lock.packages {
		if candidate.name == "kessel" {
			pin = candidate; break
		}
	}
	if !testing.expect(
		t,
		len(pin.hash) == 64 && pin.source == "https://github.com/dvrd/kessel.git",
	) {
		return
	}
	work, made := os.make_directory_temp("", "saba-locked-parser-*", a)
	if !testing.expect(t, made == nil) {
		return
	}
	defer os.remove_all(work)
	project := fmt.tprintf("%s/probe", work)
	assert(os.make_directory_all(fmt.tprintf("%s/.krs", project)) == nil)
	assert(
		os.write_entire_file(
			fmt.tprintf("%s/main.odin", project),
			"package probe\nimport \"shared:kessel\"\n",
		) ==
		nil,
	)
	for bad in ([]bool{false, true}) {
		root := fmt.tprintf("%s/root-%t", work, bad)
		assert(os.make_directory(root) == nil)
		if bad {
			pin.hash = "0000000000000000000000000000000000000000000000000000000000000000"
		}
		data, marshal_err := json.marshal(Lock{lock.format, {pin}}, allocator = a)
		assert(
			marshal_err == nil &&
			os.write_entire_file(fmt.tprintf("%s/.krs/packages.json", project), data) == nil,
		)
		result, out, errors, failure := os.process_exec(
			{
				command = {"krs", "install", "--frozen", fmt.tprintf("--root=%s", root)},
				working_dir = project,
			},
			a,
		)
		if !testing.expect(t, failure == nil) {
			return
		}
		if bad {
			testing.expect(t, !result.success)
			testing.expect(
				t,
				strings.contains(string(errors), "hash") || strings.contains(string(out), "hash"),
			)
			testing.expect(t, !os.exists(fmt.tprintf("%s/shared/kessel", root)))
		} else {
			testing.expectf(t, result.success, "%s%s", out, errors)
			testing.expect(t, os.exists(fmt.tprintf("%s/shared/kessel/ast.odin", root)))
		}
	}
}
