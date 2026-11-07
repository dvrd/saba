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
