# OKAMI-86 — bounded single-range file responses

Completed 2026-11-07 in the HTTP and Saba nested repositories. The issue's
streaming/caching prerequisites (77/78) were verified Done in Linear before
selection. Other unfinished worktrees and unrelated Metalized edits were left
intact. No push or Mesa vendored-copy update.

HTTP owns the allocation-free single-byte-range selector and 206 status text.
The optional assets package and facade expose `serve_file_stream` plus
`File_Stream_Config`. Existing buffered helpers and preloaded mounts keep their
behavior. The adapter validates a decoded relative path within a canonical root,
opens/stats a regular file, and transfers one file/producer owner to the stream
driver. Its lazy buffer is reused after each accepted chunk's final socket use.
It never copies a whole file/range or creates a thread per response.

All acceptance criteria are covered:

- Documented fixed/open/suffix single-range policy with exact 206 Content-Range,
  fixed Content-Length and unchanged MIME type; empty/unsatisfiable selections
  return bodyless 416 with `bytes */size`. Unknown units, malformed/reversed,
  duplicate/multi-range and over-1024-byte values select a full 200. Arbitrarily
  large decimal ends/suffixes clamp safely; reversed huge endpoints remain invalid.
- Default 1 GiB whole-file cap, configurable positive chunk size up to 1 MiB
  (64 KiB default), one lazy buffer and descriptor; stable rooted containment,
  private/dot/JSX and regular-file checks. Input tag/type metadata is capped at
  1024 bytes each. The tested producer is 72 bytes plus the payload allocation;
  stdlib file metadata, path/header/request-arena/exchange/kernel memory are
  separate and no global memory admission claim is made.
- Optional host-supplied immutable-generation strong ETag, If-None-Match before
  Range, exact strong If-Range with full-response fallback for weak/date/unknown/
  duplicate values, HEAD ignoring Range, zero-length files, keep-alive,
  cancellation/timeout/disconnect, rejected head/admission, OOM, truncation and
  shutdown cleanup. HEAD/304/416 never allocate/read a payload buffer.

Validation: Darwin arm64, `../odin` version `dev-2026-11:c826157de`, SHA256
`dac83d6eb5faaf9f62cef37297f34a0e21dbe3976a8b8a52c81f3db3d90f0b9c`, LLVM 22.1.8.
The consumer gate records checkout revision `7202140cb89d4e17b52eaa716d9dbc12e457f820`;
later commits since the compiler revision are library/docs work, not a compiler
rebuild. Commands below run from `shared/`:

```sh
../odin test http -warnings-as-errors -sanitize:address -out:/tmp/http-range-asan
../odin test http/v1 -warnings-as-errors -sanitize:address -out:/tmp/http-v1-range-asan
../odin test saba/assets -warnings-as-errors -define:ODIN_TEST_THREADS=1 -sanitize:address -out:/tmp/assets-range-final
../odin test saba/core -warnings-as-errors -sanitize:address -out:/tmp/saba-core-range-asan
../odin test saba -warnings-as-errors -sanitize:address -out:/tmp/saba-facade-range-asan
python3 saba/tests/file_ranges.py --odin "$PWD/../odin" --sanitize address
python3 saba/tests/file_ranges.py --odin "$PWD/../odin" --sanitize thread --workers 4
python3 saba/tests/streaming.py --odin "$PWD/../odin" --sanitize address
python3 saba/tests/conditional_assets.py --odin "$PWD/../odin" --sanitize address
python3 ../ci/webtools_consumer_gate.py --odin "$PWD/../odin" --packages http http/v1 saba auth --report /tmp/webtools-range-consumers.json
```

All pass: HTTP common 2, HTTP/1 16, assets 11, core 31, facade 9 ASan tests;
eight file-wire groups under ASan/one worker and TSan/four workers; existing nine
stream/SSE and six conditional-cache wire groups; empty executable plus four
isolated consumers. The range codec runs with both allocators set to panic.
Tracked file producers request exactly one owner plus one reusable buffer;
owner/buffer allocation failures, rejected grants and truncation return tracked
bytes to zero. Wire tests independently decode Python HTTP responses and hash a
14 MiB range using a configured 16 KiB buffer; exercise 40 concurrent ranges,
repeated disconnects, slow-reader timeout, cheap-route progress and active stop;
all tracked allocations balance and server descriptors return to baseline.

The first adapter test exposed a missing canonical-root normalization for macOS
symlinked temporary roots; matching the existing preload normalization fixed it.
Sized producer free makes custom allocator accounting exact. A wire-fixture
assertion initially counted its client socket in the server's descriptor total;
correcting that expectation produced passing ASan/TSan runs.

Scope limits: file contents and directory tree must be trusted/stable through
disposal; this is the existing resolve/check/open policy, not protection against
concurrent hostile directory replacement. Same-size in-place mutation is outside
the immutable-generation contract. Filesystem canonicalize/open/stat/read calls
are synchronous and non-preemptible; this opt-in adapter accepts that host
latency policy. General blocking offload is still OKAMI-91 and global byte/job
admission OKAMI-122. Socket writes keep the existing stream/request deadlines.
No multipart, date preconditions, automatic digest scan, changed preload policy,
Linux/Windows execution, performance claim or application integration is implied.

Policy reference: [RFC 9110 section 14](https://www.rfc-editor.org/rfc/rfc9110.html#section-14).
