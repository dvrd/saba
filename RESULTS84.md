# OKAMI-84 — bounded chunked HTTP/1 request bodies

Implemented 2026-11-07 across HTTP, Saba and Auth. The shared HTTP/1 codec now
provides an opt-in framed request-head parser and an allocation-free incremental
chunk decoder using the existing size/extension and trailer validators. Existing
fixed-body parser entry points still reject transfer coding. Saba opts in, owns
bounded request-arena decoding/input storage, applies the route's decoded-byte
limit, retains its total body deadline and preserves unread next-request bytes.
Both the async task path and blocking helper dispatch only complete bodies.

Handlers see decoded body length and the original `chunked` framing flag; Auth's
explicit and compatibility Saba adapters communicate complete-body knowledge to
the JSON mapper without requiring a wire Content-Length. Trailer fields are
validated/discarded and never change request headers. HTTP/Saba READMEs document
hard caps, up-front body reservation, framing/error/timeout policy and API use.
This does not add streaming handlers, SSE, range responses or global byte budgets.

Validation on Darwin arm64, Odin `dev-2026-11:c826157de`:

- HTTP/1: 15 tests pass, ordinary and AddressSanitizer. Includes every wire split,
  output backpressure, nil allocation, malformed/EOF/sticky failures and exact/
  cap+1 body/line/chunk-count/aggregate-metadata/trailer limits.
- Saba core: 20 ASan tests; facade: 9 ASan tests; HTTP parser parity: 2 ASan
  tests; Auth/Saba identity regressions: 3 ASan tests pass.
- `python3 shared/saba/tests/chunked_requests.py --odin ./odin --sanitize address`:
  8 wire groups pass. Covers every split, an independent Python HTTP chunk encoder
  with binary data, coalesced persistence and exact byte metrics, caps, ambiguity,
  forbidden/malformed trailers, premature EOF, progress-independent body timeout,
  disconnect and shutdown cleanup.
- Existing async_server.py and keep_alive.py loopback regressions pass; async
  server exercises one/four workers, backpressure, growth and reload WebSockets.
  The unsupported-coding fixture now uses gzip, since chunked is supported.
- Auth wire.py: 5 ASan groups pass; signup now explicitly uses independent Python
  chunked JSON encoding, followed by existing login/session/password/logout flows.
- Isolated executable consumer gate: empty program plus HTTP, HTTP/1, Saba and
  Auth build/run successfully (`/tmp/webtools-chunked-consumers.json`).

Run commands from the Odin root as written above, or remove `shared/` and select
`../odin` from this directory's parent. Test binaries/reports are temporary.
All sockets/listeners/stores belong to the harness. No real provider/network
request, Mesa vendored update or Linux/Windows runtime result is claimed.
