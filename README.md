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
  rendering and no hydration ([ADR 0004](docs/adr/0004-saba-compile-time-html-no-request-rendering.md)).
- **Adapters**: offloaded work (`src/offload`), upstream HTTP (`src/upstream`),
  WebSocket (`src/websocket`) and S3 (`src/s3`).

Design notes live in [docs/](docs/) and [docs/adr/](docs/adr/).

## Requirements

- The owner's Odin fork, [dvrd/Odin](https://github.com/dvrd/Odin). Saba does
  not build with upstream Odin. Set `ODIN` to use a compiler that is not on `PATH`.
- [krs](https://github.com/dvrd/krs) to install the dependencies pinned in
  `.krs/packages.json` (async, surf, websocket, aws, kakunou, kessel).
- [Task](https://taskfile.dev) to run the suites.
- For the UI and JavaScript tests: Node (`SABA_NODE`) and Chrome or Chromium
  (`SABA_CHROME`).
- For the loopback harnesses: `python3` (`SABA_PYTHON`); Go (`SABA_GO`) for
  the HTTP/2, HTTPS and WebSocket harnesses; a Python with
  [aioquic](https://github.com/aiortc/aioquic) in `SABA_AIOQUIC_PYTHON` for
  the HTTP/3 harnesses.

A suite whose optional tool is missing is skipped with a warning naming the
variable to set.

## Tests

```sh
task test                                   # every suite
task test -- --package core --internal-only # one package's private suite
task test -- -- -define:ODIN_TEST_NAMES=saba_core.<test>
task test -- --help
```

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
  times out before it is received answers 408. A handler or deferred response
  that finishes after its deadline answers 504, because its effects may have
  happened (an expired deferred response on HTTP/2 or HTTP/3 resets its
  stream instead).
- **Handlers must not block a worker.** Workers default to one per logical
  core (at least four) and are never preempted. A handler that sleeps or waits
  on I/O holds its worker; when all are held nothing is accepted, read or timed
  out. Return a deferred or streamed response, or use `src/offload`, for work
  that waits.
- **Deprecated blocking helpers.** The facade's `read_connection`,
  `write_connection` and `send_response` block the calling worker on the raw
  socket and fail on TLS connections. Return a `Response` instead.
- **`backlog`** sets the listen queue length. Zero keeps 128; the kernel may
  clamp larger values.
- **`dedicated_poller`** (off by default) runs the reactor on its own thread,
  so accepts, timers, deadlines and drain become ready on time while every
  worker is busy. A ready connection still waits for a free worker: it keeps
  bookkeeping timely but does not make blocking handlers safe. Each readiness
  costs one thread handoff.

## Branches and releases

Work lands on `develop`. Releases reach `main` through a pull request from
`develop`.
