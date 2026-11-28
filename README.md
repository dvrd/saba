# Saba

Saba is a web server and UI framework written in Odin.

- **Server** (`src/core`, imported as `shared:saba/core`): HTTP/1.1, HTTP/2 and
  HTTP/3 on one non-blocking task runtime, with TLS, gzip and Brotli response
  coding, streamed and deferred responses, request and connection budgets,
  keep-alive, graceful drain and request observability.
- **Facade** (`src/saba.odin`, imported as `shared:saba`): a `Server` that adds
  static assets, JSX module mounts, file-based pages, development hot reload
  and an optional SQLite database handle (kakunou) on top of the core server.
- **UI**: JSX components compiled at build time. Markup the compiler can prove
  is emitted as HTML; the rest becomes plain JavaScript that attaches in the
  browser with signals and fine-grained bindings. There is no per-request
  rendering and no hydration.
- **Adapters**: offloaded work (`src/offload`), upstream HTTP (`src/upstream`),
  WebSocket (`src/websocket`) and S3 (`src/s3`).

[docs/system.html](docs/system.html) explains the architecture with diagrams,
[docs/architecture.html](docs/architecture.html) steps through a page from JSX
to a live binding with the real source at each step, and
[docs/features.html](docs/features.html) walks through each feature the same way.
The other notes in [docs/](docs/) record UI work and measurements.

## Requirements

- The owner's Odin fork, [dvrd/Odin](https://github.com/dvrd/Odin). Saba does
  not build with upstream Odin. Set `ODIN` to use a compiler that is not on `PATH`.
- [krs](https://github.com/dvrd/krs) to install the dependencies pinned in
  `.krs/packages.json` (async, surf, aws, kakunou, kessel).
- [Task](https://taskfile.dev) to run the suites.
- Optional, for some suites: Node and Chrome for the browser and JavaScript
  tests, and libcurl, OpenSSL, ngtcp2 and nghttp3 (through pkg-config) for the
  interoperability tests. A suite whose tool is missing is skipped with a
  notice. [tests/README.md](tests/README.md) lists them.

## Tests

```sh
task test                          # every suite
task test -- unit                  # one kind: unit, integration, e2e, interop, browser, javascript
task test -- integration/core      # one suite
task test -- --help
```

Every suite is Odin except the JavaScript runtime's own tests. What each kind
covers and where fixtures live is in [tests/README.md](tests/README.md).

`task test` copies the checkout to a temporary directory and runs
`krs install --frozen` into a private root, so it tests the locked
dependencies, not sibling working copies. `--shared PATH` (or
`WEBTOOLS_SHARED`) uses an existing collection instead.

## Operating a server

- **Signals.** SIGTERM and SIGINT start a graceful drain by default: the
  listener closes, admitted requests finish within `drain_timeout` (five
  seconds when zero) and `serve` returns. A second signal terminates the
  process. Handlers are installed only while `serve` runs and only for signals
  still at their default disposition. Set `signals = {disabled = true}` to
  handle signals in the application and call `drain_server` from a thread.
- **Deadlines follow progress.** Header and idle timeouts are fixed. Body and
  response timeouts are stall budgets on HTTP/1: each byte of progress re-arms
  them while the transfer keeps a minimum average rate, so a slow but live
  peer is served and a stalled or trickling one is cut off. A request that
  times out before it is received answers 408. A handler, deferred response,
  offload job or upstream call that finishes after its deadline answers 504,
  because its effects may have happened (an expired deferred response on
  HTTP/2 or HTTP/3 resets its stream instead).
- **Handlers must not block a worker.** Workers default to one per logical
  core (at least four) and are never preempted. A handler that sleeps or waits
  on I/O holds its worker; when all are held nothing is accepted, read or timed
  out. Return a deferred or streamed response, or use `src/offload`, for work
  that waits.
- **Deprecated blocking helpers.** The facade's `read_connection`,
  `write_connection` and `send_response` block the calling worker on the raw
  socket and fail on TLS connections. Return a `Response` instead.
- **Programs the server starts** (a tool run from a handler, a development
  build) inherit none of its sockets. The listening sockets, the accepted
  connections, the HTTP/3 socket and the connections the upstream client
  opens are all close-on-exec, so such a program cannot keep a port bound or
  a connection open after the server stops.
- **`backlog`** sets the listen queue length. Zero keeps 128; the kernel may
  clamp larger values.
- **`dedicated_poller`** (off by default) runs the reactor on its own thread,
  so accepts, timers, deadlines and drain become ready on time while every
  worker is busy. A ready connection still waits for a free worker: it keeps
  bookkeeping timely but does not make blocking handlers safe. Each readiness
  costs one thread handoff.
- **HTTP/3 listener limits** (`Http3_Config`). `max_request_fields` (default
  128, the maximum) and `max_request_field_bytes` (default 16 KiB, at most
  48 KiB) bound one request's field section; a request over either answers
  431. `max_connections_per_address` (default 8) caps the connections one
  client address holds in the table (`max_connections`, default 32); a value
  of `max_connections` or more lifts it. With `retry` tokens configured, new
  connections skip the Retry round trip while fewer than `retry_above` are
  held (default half the table) and are challenged after that;
  `retry_every_connection` challenges every new connection instead.
- **Served paths are typed without opening them.** Asset, module and page
  lookups name each entry with `lstat(2)` (and `stat(2)` for a symbolic link)
  before resolving it. Only a regular file or a directory is resolved and
  served, so a FIFO or device under a served root is never opened.

### Upstream HTTP

`attach` in `shared:saba/upstream` initializes the Surf client from the
`surf.Client_Config` it is given, then dispatches its completions; the
application closes the client, calls `detach` and destroys it. Outbound URLs
often carry request data, so by default the client refuses any upstream
address that is not global unicast (`address_policy_public_only`: loopback,
private, link-local, metadata and similar ranges), checked after DNS and
before every dial, including redirects. An application with an internal
upstream supplies its own `config.http.address_policy`, with any state it
needs in `address_policy_data`, for example one that accepts only that
upstream's addresses. A refused upstream answers 502 Bad Gateway; a request
whose deadline passes answers 504 Gateway Timeout.

### S3

The S3 adapter lives in `shared:saba/s3`; the facade re-exports the calls
below.

- **Servers lease cached credentials.** Call `credential_cache_init` once at
  startup (`credential_clock_system` is the wall clock it takes), keep the
  cache filled with `credential_refresh` from a maintenance thread or timer
  (it blocks on the provider), and in a request handler take
  `credential_lease_cached`, which never blocks or does I/O. Sign with
  `lease_credentials(lease)` and return every lease with
  `credential_lease_release`. The cache holds one copy of the secret and wipes
  it once it is replaced and no lease holds it.
- **Signing without sending.** `s3_put_request`, `s3_delete_request`,
  `s3_get_request` and `s3_head_request` build a signed request with no I/O;
  send it through an asynchronous transport such as the upstream adapter.
- **Scripts only.** `aws_credentials` resolves again on every call and can
  block for seconds. `s3_put` and `s3_delete` hold the calling thread for up
  to 15 seconds and `s3_put_file` for up to 120 seconds of upload. None of them
  is safe on a request worker; call them from scripts, tools or a worker pool.

### Pages and modules

- **Shared build archives.** With `Page_Mount.templates.archive_directory`
  set, a request for a generation the process does not hold looks for its
  archive there, so processes that share the directory serve each other's
  builds, including ones written after they started.
  `archive_retention.rescan_interval` bounds how often each generation is
  looked for: zero selects two seconds and a negative value turns the lookup
  off. Generations loaded this way live until `release_build`, which the
  facade calls; an application that prepares pages itself calls it once no
  request can reach the build.
- **Development source maps.** In development a module compiled from JSX ends
  with `//# sourceMappingURL=<module>.js.map`, and that URL serves a map
  whose file and source names are relative to it and which embeds the JSX
  source. Production never serves or advertises a map, and compiled page
  templates have no maps yet.

## Branches and releases

Work lands on `develop`. Releases reach `main` through a pull request from
`develop`.

## License

Saba is released under the MIT License. See [LICENSE](LICENSE).
