# Bounded asset mounts

Import `shared:saba/assets` independently, or use the Saba convenience facade.
The facade forwards `Server.asset_limits`; importing `saba/core` does not include
asset loading. Limits apply before the listener starts.

`prepare_assets(mounts,allocator)` preserves its existing two-argument callable
type and uses bounded defaults. `prepare_assets_bounded(mounts,limits,allocator)`
returns owned caches and a typed `Asset_Error`. Failure releases all partially
prepared owners. The error reports its kind, mount index, limit and observed
count, with underlying read/OS/allocation diagnostics where applicable.

| Limit | Default |
| --- | ---: |
| Mounts | 16 |
| Preloaded files across all mounts | 4096 |
| Visited entries, including directories/skipped files | 16384 |
| Bytes per file | 8 MiB |
| Retained file-body bytes across all mounts | 64 MiB |

Zero fields select defaults; negative values fail. Explicit file-byte limits
cannot exceed the shared bounded-file reader's 64 MiB envelope. Other limits
are configurable. Exact limits are accepted, including empty files after the
body-byte budget is exhausted. At that boundary the reader may temporarily read
one byte to distinguish empty and nonempty files; it never retains an excess.
Oversized files fail before payload allocation. Concurrent file growth/shrink
fails rather than silently publishing a partial body.

Body budgets exclude cache/map/path/iterator and allocator overhead. Mount,
file and visited-entry caps separately bound metadata/work. Directory traversal
uses an explicit bounded queue and paired iterator/file cleanup, including early
failure. OS/allocator internal reservations are not a precise total-memory cap.

Call `destroy_assets(&caches,allocator)` after all requests stop using the cache.
It clears the owning slice before freeing keys, bodies, maps and mount strings;
repeat destruction of that same variable is harmless. Copies are aliases, not
new owners. The supplied allocator must outlive its allocations and support
ordinary allocation/failure/free semantics. Configuration and cache contents
are immutable while serving.

Development reads also enforce the effective per-file limit for changed/new
files. They use the request allocator and do not add new retained cache entries;
concurrent request/global memory admission remains host policy. Prefix/path
validation, containment checks and exclusion of `.jsx` files are preserved.
The standalone `serve_file` helper is outside mount-preload budgeting.

## HEAD and browser revalidation

Asset mounts, prepared modules, page shells and the built-in module runtime
scripts accept GET and HEAD. HEAD takes the same routing, representation and
path-validation path as GET. Response bodies remain borrowed internally so the
core sender can report the GET `Content-Length`; both core senders suppress
all body bytes for HEAD.

Production responses use `Cache-Control: no-cache` and a quoted lowercase SHA256
ETag of the exact representation bytes. This allows storage with revalidation;
it does not promise that an unversioned URL stays immutable. Hashing currently
runs on each response, including conditional requests, without copying the body.
It adds linear CPU work in representation size, within existing asset bounds.
The public cache structs and existing callable signatures are unchanged.

`If-None-Match` supports weak comparison, comma-separated tags, repeated field
lines and a standalone wildcard. A matching GET or HEAD returns 304 with the
same ETag/cache policy and no body or Content-Length. Malformed conditions are
ignored as a whole, yielding the normal 200 response; a valid prefix never
causes a partial match. Path validation and existence checks precede conditional
handling, so a wildcard cannot turn a missing/private resource into a 304.
This policy uses ETags rather than Last-Modified/date conditions.

Development asset, module and page responses use `Cache-Control: no-store`,
ignore cache conditions and read/transform current files, including HEAD.
Page metadata describes the final HTML, including facade hot-reload injection.
Production caches remain startup snapshots: restart/reprepare to publish changed
files and validators. Built-in runtime scripts have fixed process bytes and use
revalidation in either mode. The standalone `serve_file` helper retains its
existing behavior; `representation_response` exposes this policy to adapters
that already own complete representation bytes. The core now supports resumable `Response.stream` producers (OKAMI-77);
file/range integration remains separate work (OKAMI-86).

Validation:

```sh
../odin test saba/assets -define:ODIN_TEST_THREADS=1 -out:/tmp/assets-tests
python3 saba/tests/conditional_assets.py --odin "$PWD/../odin"
python3 saba/tests/conditional_assets.py --odin "$PWD/../odin" --sanitize address
```

Run from `shared/`. Use one test thread for the assets package because its
descriptor cleanup tests measure process-wide open files. The loopback harness
checks actual HEAD/304 framing, independent SHA256 validators, development
freshness and containment across the facade's asset/module/page routes.

## Strategy experiment

`tests/benchmark.py` compares the actual bounded preload cache with two diagnostic
prototypes: a build-fingerprinted manifest that verifies SHA256 on every read,
and bounded on-demand reads. They are not supported server modes. Run with a
compiler executable (not a wrapper that appends compile flags to `version`):

```sh
python3 shared/saba/assets/tests/benchmark.py --odin /path/to/odin --report /path/to/assets.json
```

The script uses synthetic trees, three repetitions, rotated strategy order,
1001 lookups per process, and reports startup, first/steady lookup latency and
Darwin peak RSS. It uses warm filesystem caches and excludes HTTP/concurrency.
Keep bounded preload for small static trees. Defer a production manifest mode:
the prototype reduces retained bodies/startup but adds file I/O and hash work
per request. Larger-file streaming needs its own backpressure/body-lifetime
integration rather than exposing this diagnostic as a server API.
