// Asset strategy microbenchmark on Darwin: synthetic files, warm filesystem
// cache. From the checkout root:
//
//   odin run benchmarks/load/assets -o:speed -collection:shared=<collection> -- --report <path.json> [--repetitions N]
//
// The preload strategy is the production bounded cache. The manifest and
// on-demand strategies are diagnostic prototypes, not server modes. No claim is
// made about HTTP, concurrency, a cold cache or deployment performance.
package main

import "core:crypto/hash"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"

ITERATIONS :: "1001"
MODES :: [3]string{"preload", "manifest", "on_demand"}

Case :: struct {
	files:            int,
	file_bytes:       int,
	total_body_bytes: int,
	manifest_build_ns: i64,
}

Row :: struct {
	mode:                string,
	files:               int,
	startup_ns:          i64,
	first_ns:            i64,
	steady_p50_ns:       i64,
	steady_p95_ns:       i64,
	steady_p99_ns:       i64,
	retained_body_bytes: int,
	peak_rss_bytes:      i64,
	checksum:            i64,
	repetition:          int,
	file_bytes:          int,
	total_body_bytes:    int,
}

Report :: struct {
	platform:        string,
	clock:           string,
	repetitions:     int,
	limits:          string,
	manifest_policy: string,
	compiler:        string,
	cases:           [dynamic]Case,
	rows:            [dynamic]Row,
}

main :: proc() {
	if len(os.args) > 1 && os.args[1] == "measure" {
		measure(os.args[2:])
		return
	}
	when ODIN_OS != .Darwin {
		fmt.eprintln("This benchmark measures Darwin ru_maxrss bytes only.")
		os.exit(1)
	}
	report_path := ""
	repetitions := 3
	for index := 1; index < len(os.args); index += 1 {
		switch os.args[index] {
		case "--report":
			index += 1
			report_path = os.args[index] if index < len(os.args) else ""
		case "--repetitions":
			index += 1
			repetitions, _ = strconv.parse_int(os.args[index] if index < len(os.args) else "")
		case:
			fmt.eprintln("usage: assets --report <path.json> [--repetitions N]")
			os.exit(2)
		}
	}
	if report_path == "" {
		fmt.eprintln("usage: assets --report <path.json> [--repetitions N]")
		os.exit(2)
	}
	// Each mode runs first once in every three repetitions.
	if repetitions < 3 {
		fmt.eprintln("At least three repetitions are required.")
		os.exit(2)
	}
	self, located := os.get_executable_path(context.allocator)
	assert(located == nil)
	parent, _ := os.split_path(report_path)
	if parent != "" {
		_ = os.make_directory_all(parent)
	}
	machine: posix.utsname
	_ = posix.uname(&machine)
	report := Report {
		platform        = fmt.aprintf("%s-%s-%s", cstring(&machine.sysname[0]), cstring(&machine.release[0]), cstring(&machine.machine[0])),
		clock           = "monotonic ns",
		repetitions     = repetitions,
		limits          = "warm cache; file lookup/read only, no HTTP/concurrency/cold disk",
		manifest_policy = "SHA256 fingerprint prepared at build time; verify full body on every diagnostic read",
		compiler        = fmt.aprintf("odin version %s:%s", ODIN_VERSION, ODIN_VERSION_HASH),
	}
	temporary, made := os.make_directory_temp(parent, "asset-strategies-*", context.allocator)
	assert(made == nil)
	defer os.remove_all(temporary)

	for shape in ([][2]int{{32, 1024}, {256, 16 * 1024}, {512, 64 * 1024}}) {
		count, size := shape[0], shape[1]
		directory := fmt.aprintf("%s/%d-%d", temporary, count, size)
		assert(os.make_directory(directory) == nil)
		body := make([]u8, size)
		for &b, index in body {
			b = u8(index % 256)
		}
		for index in 0 ..< count {
			assert(os.write_entire_file(fmt.tprintf("%s/%04d.bin", directory, index), body) == nil)
		}
		began := time.tick_now()
		// Fingerprint the files on disk as a build step would, outside the
		// measured startup.
		manifest := strings.builder_make()
		for index in 0 ..< count {
			name := fmt.tprintf("%04d.bin", index)
			data, read := os.read_entire_file(fmt.tprintf("%s/%s", directory, name), context.allocator)
			assert(read == nil)
			digest: [32]u8
			hash.hash(.SHA256, data, digest[:])
			delete(data)
			fmt.sbprintf(&manifest, "%s\t%s\n", name, string(hex.encode(digest[:], context.temp_allocator)))
		}
		assert(os.write_entire_file(fmt.tprintf("%s.manifest", directory), strings.to_string(manifest)) == nil)
		append(&report.cases, Case{count, size, count * size, i64(time.tick_since(began))})
		strings.builder_destroy(&manifest)
		delete(body)

		for repetition in 0 ..< repetitions {
			// Rotate the order against whatever effect running first has.
			modes := MODES
			for offset in 0 ..< len(modes) {
				mode := modes[(repetition + offset) % len(modes)]
				state, output, errors, error := os.process_exec(
					{command = {self, "measure", mode, directory, fmt.tprint(count), ITERATIONS}},
					context.allocator,
				)
				if error != nil || !state.success {
					fmt.eprintf("%s %s failed: %v\n%s", mode, directory, error, string(errors))
					os.exit(1)
				}
				row: Row
				assert(json.unmarshal(output, &row) == nil)
				row.repetition, row.file_bytes, row.total_body_bytes = repetition, size, count * size
				append(&report.rows, row)
				delete(output)
				delete(errors)
				// Saved after every cell, so an interrupted run keeps what it measured.
				text, marshalled := json.marshal(report, {pretty = true, use_spaces = true, spaces = 2})
				assert(marshalled == nil)
				assert(os.write_entire_file(report_path, string(text)) == nil)
				delete(text)
			}
		}
	}
	fmt.printf("%d measured cells saved to %s\n", len(report.rows), report_path)
}
