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
the opt-in file/range adapter is described below.

## Content coding

Asset, module and page responses go through the core queue's gzip negotiation.
The full coding, `Vary`, threshold and memory policy is in the Saba README under
"Response content coding". Production `Cache-Control: no-cache` may be gzipped.
Development `no-store` is not, and neither are `private` responses, responses
that already set `Content-Encoding`, or 206/304 responses. Identity remains
available, so OKAMI-78 HEAD and 304 behavior is unchanged unless the client
sends a valid `Accept-Encoding` and the representation is eligible. Eligible
buffered HEAD advertises the compressed `Content-Length` and still sends no
body. Eligible file streams are one gzip member with chunked GET framing; their
HEAD does not read the file or send a body. Unknown-length streams, files
outside 1024 bytes through 1 MiB, and already-compressed media types stay
identity. Ranges stay identity so `Content-Range` continues to describe the
uncompressed file.

## Streamed file downloads and single byte ranges

`serve_file_stream(request,root,relative,config)` serves an explicitly selected
regular file through `Response.stream`. Both `shared:saba/assets` and the facade
export it and `File_Stream_Config`. It does not preload the file or change
existing `serve_file`, asset-mount, module or page response behavior. For example,
from an asynchronous server handler:

```odin
return server.serve_file_stream(request, "downloads", "release.zip", {
    max_file_bytes = 2 * 1024 * 1024 * 1024,
    chunk_bytes = 64 * 1024,
    etag = `"release-2026-11-07"`,
})
```

`root` is host-selected; `relative` is percent-decoded once, then passed through
asset path validation and canonical containment. Dot/private segments, absolute
paths, backslashes, `.jsx`, directories and symlinks escaping the root return 404.
Keep the directory tree trusted and stable while serving: this uses the existing
resolve/check/open path policy, not an OS capability sandbox against concurrent
hostile directory replacement. File contents must remain immutable until final
stream disposal, preferably published as new names with atomic replacement.
Unexpected truncation terminates the connection instead of reusing an incomplete
fixed-length response; same-size in-place mutation is outside this contract.

GET supports one `bytes=first-last`, `bytes=first-` or `bytes=-suffix` range.
Satisfiable ranges return 206, exact Content-Range and Content-Length, and the
original Content-Type. Unsatisfiable ranges, including any range on an empty
file or a zero suffix, return 416 with `bytes */size` and an empty body. Ends and
suffixes larger than the file clamp safely, even beyond machine integer size.
Malformed/reversed, unknown-unit, multi-range, repeated Range fields and values
over 1024 bytes are ignored in full, producing the normal 200 response. No multipart
allocation or per-range work is performed. HEAD ignores Range and describes the
full GET representation with no body. Other methods return 405 with Allow.

An optional host-supplied strong ETag identifies the exact immutable generation.
It is cloned into request storage; it is never guessed from timestamps or an
inode. With a tag, responses use `no-cache` and existing If-None-Match weak/list/
wildcard handling before range selection. Without a tag, use `no-store`;
If-None-Match wildcard can still yield 304 for an existing file. If-Range enables
a partial response only on exact strong-tag equality. Weak, date, unknown,
malformed or duplicate If-Range conditions cause a full 200. Last-Modified/date
preconditions and the wider If-Match/If-Unmodified-Since policy remain outside
this adapter. ETag and explicit Content-Type inputs are capped at 1024 bytes each.

Defaults are a 1 GiB whole-file admission cap and 64 KiB payload buffer per response;
zero selects defaults, negative limits fail, and chunks are configurable from 1
byte to 1 MiB. Oversized files/configuration fail with 500 before body allocation.
One descriptor and a 72-byte producer on the validated Darwin arm64 toolchain own
one lazy reusable payload allocation of `min(chunk_bytes,response_length)` bytes.
No payload is allocated/read for HEAD or 304/416. A custom allocator must support
individual sized frees, worker migration and survival until final drop. The
core's one-slot exchange charges the whole backing buffer; the buffer is reused
only after its previous socket use ends. Header failure, cancellation, disconnect,
timeout and stop release it and close the file exactly once. An unqueued response
must be passed to `discard_response`; the blocking `send_response` rejects streams.

Open/stat/canonicalization and each bounded read are synchronous filesystem work.
They can occupy a network worker on a cold, slow or network filesystem and cannot
be preempted by stream deadlines. Use this opt-in adapter only when the host
accepts that latency; bounded offload remains OKAMI-91. Socket writes retain the
core's slow-reader, total-stream and request-context deadlines. Per-file/per-chunk
bounds exclude OS caches, path/header/request-arena metadata and global concurrent
admission (OKAMI-122). No zero-copy or throughput improvement is claimed.

```sh
../odin test http -sanitize:address -out:/tmp/http-range-tests
../odin test saba/assets -define:ODIN_TEST_THREADS=1 -sanitize:address -out:/tmp/assets-range-tests
python3 saba/tests/file_ranges.py --odin "$PWD/../odin" --sanitize address
python3 saba/tests/file_ranges.py --odin "$PWD/../odin" --sanitize thread --workers 4
```

The owned loopback fixture exercises the facade export, independently decodes
range bytes/metadata, and tracks all producer/buffer grants and server descriptors.
It covers large downloads, concurrency, slow readers, disconnects and active
shutdown. Results are Darwin arm64 only; no Mesa vendored-copy update is implied.

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
