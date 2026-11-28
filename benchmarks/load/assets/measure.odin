package main

import assets "../../../src/assets"
import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"

// One cell, in a process of its own so its peak RSS is its own: load the
// files with one strategy, then look up and read iterations of them and print
// the timings as one JSON row.
measure :: proc(args: []string) {
	assert(len(args) == 4)
	mode, directory := args[0], args[1]
	count, count_ok := strconv.parse_int(args[2])
	assert(count_ok)
	iterations, iterations_ok := strconv.parse_int(args[3])
	assert(iterations_ok && iterations > 1)
	start := time.tick_now()
	caches: []assets.Asset_Cache
	manifest_data: []u8
	entries := make(map[string][32]u8)
	defer delete(entries)
	defer delete(manifest_data)
	defer assets.destroy_assets(&caches, context.allocator)

	if mode == "preload" {
		error: assets.Asset_Error
		caches, error = assets.prepare_assets_bounded({{directory, ""}}, {}, context.allocator)
		assert(error.kind == .None)
	} else if mode == "manifest" {
		path := fmt.aprintf("%s.manifest", directory)
		defer delete(path)
		error: assets.Read_Error
		manifest_data, error = assets.read_limited(path, 1 << 20)
		assert(error.kind == .None)
		text := string(manifest_data)

		for line in strings.split_iterator(&text, "\n") {
			if line == "" {
				continue
			}

			name, _, digest_text := strings.partition(line, "\t")
			digest: [32]u8
			decoded, ok := hex.decode_into_buffer(transmute([]u8)digest_text, digest[:])
			assert(ok && len(decoded) == 32)
			entries[name] = digest
		}

		assert(len(entries) == count)
	} else {
		assert(mode == "on_demand")
	}

	startup := i64(time.tick_since(start))
	samples := make([]i64, iterations)
	defer delete(samples)
	sum: i64

	for index in 0 ..< iterations {
		name := fmt.aprintf("%04d.bin", index % count)
		began := time.tick_now()
		body: []u8

		if mode == "preload" {
			item, found := caches[0].files[name]
			assert(found)
			body = item.body
		} else {
			path := fmt.aprintf("%s/%s", directory, name)
			error: assets.Read_Error
			body, error = assets.read_limited(path, 8 << 20)
			delete(path)
			assert(error.kind == .None)

			if mode == "manifest" {
				expected, found := entries[name]
				assert(found)
				digest: [32]u8
				hash.hash(.SHA256, body, digest[:])
				assert(digest == expected)
			}
		}

		sum += i64(len(body)) + i64(body[0]) + i64(body[len(body) - 1])

		if mode != "preload" {
			delete(body)
		}

		samples[index] = i64(time.tick_since(began))
		delete(name)
	}

	first := samples[0]
	slice.sort(samples[1:])
	retained := 0

	for cache in caches {
		for _, file in cache.files {
			retained += len(file.body)
		}
	}

	usage: posix.rusage
	assert(posix.getrusage(.SELF, &usage) == .OK)
	fmt.print("{")
	fmt.printf(
		"\"mode\":\"%s\",\"files\":%d,\"startup_ns\":%d,\"first_ns\":%d,\"steady_p50_ns\":%d,\"steady_p95_ns\":%d,\"steady_p99_ns\":%d,\"retained_body_bytes\":%d,\"peak_rss_bytes\":%d,\"checksum\":%d",
		mode,
		count,
		startup,
		first,
		samples[1 + (iterations - 1) / 2],
		samples[1 + (iterations - 2) * 95 / 100],
		samples[1 + (iterations - 2) * 99 / 100],
		retained,
		usage.ru_maxrss,
		sum,
	)
	fmt.println("}")
}
