# Saba

Choose `shared:saba/core` for the lean server and import only the adapters you need.
`shared:saba` remains the convenience facade with the existing database, assets,
pages, development and S3 interface. See [CORE_AND_ADAPTERS.md](CORE_AND_ADAPTERS.md)
for imports, lifetime rules, migration and measured dependency/layout results.
Use the optional [bounded offload adapter](offload/README.md) for synchronous
work that must run outside connection workers.
[Resource budgets](RESOURCES.md) separately bound managed backing, streaming
exchanges and retained jobs without changing metadata capacity limits.

This Odin package contains the existing HTTP connection handling, request parsing,
response serialization, status enum, JSON decoding, route matching, WebSocket
handshake/frame helpers, static assets, file-based pages, JSX transformation,
S3 storage and development live reloading.
SQLite operations and schema types belong to the separate `kakunou` module.

The application owns its schema, SQL, row decoders, route declarations, handlers,
and UI files. The package uses Odin core/vendor libraries, native system
libraries, and `kakunou` for database handles and SQL operations; it never imports the application.

## Startup

Install this repository at `$(odin root)/shared/saba` and Kakunou at
`$(odin root)/shared/kakunou`, and the async library at
`$(odin root)/shared/async`. The convenience facade requires SQLite and libcurl as system
libraries; the core does not. Projects import the server and database packages through Odin’s shared collection:

```odin
import server "shared:saba"
import db "shared:kakunou"
```

Configure `context.logger`, initialize your database, then serve:

```odin
database: ^db.SQLite_DB

err := init_database(&database, "my-app.sqlite")
if err.kind != .None {
    db.log_error(err, "Database initialization failed")

    return
}
defer db.close(database)

server.serve(server.Server {
    address = "127.0.0.1",
    port = 8080,
    initial_connections = 64,
    max_connections = 4096,
    workers = 4,
    database = database,
    handler = router,
})
```

`init_database` and `router` are application procedures. Address defaults to `127.0.0.1`;
port `0` requests an OS-assigned port. `database` may be nil for handlers that do
not use SQLite. `serve` blocks while accepting requests and returns false after
logging a startup failure or an unrecoverable listener error. The caller controls
application shutdown; the package does not call `os.exit`.

Database setup and error handling belong to `shared:kakunou` (see its README).

The caller owns the database and logger backing state and keeps them alive while
`serve` runs. Workers borrow the server runtime and use the configured logger;
each handled connection closes after its response is sent. Before `serve` returns,
it stops and joins its watcher and waits for its connection tasks and cleanup to finish.

### Worker pool and shutdown

Saba uses `shared:async` for acceptance, request headers/bodies, response writes,
and its reload WebSocket. A connection is a resumable task; socket waits park the
task rather than a thread. Request arenas and partial-I/O offsets survive until
the task finishes, and the runtime closes its socket before final cleanup. Reload
WebSockets release their HTTP request/response arena after the upgrade, retaining
only frame state and any prefetched frame bytes.

`Server.workers` selects a fixed pool size. Zero selects four; negative values
fail startup. The thread calling `serve` is one of those workers. Development
mode also retains its separate file-watcher thread. Application handlers keep the
same `Handler` interface and return one `Response`; do not perform raw socket I/O
or call the synchronous send/read helpers from a handler. The HTTP server still
sends one response and closes each ordinary connection; keep-alive and chunked
request bodies are not introduced by this integration.

Handlers, SQLite calls, filesystem access and S3/libcurl operations remain
synchronous. They occupy their worker while executing. This integration makes
network waits asynchronous; it does not make arbitrary handler code preemptible.

For application-controlled shutdown, keep a `Server_Control` at a stable address
and pass its pointer in `Server.control`. Another application thread can call
`stop_server(&control)`: new admission stops, parked connections are cancelled,
and running handlers finish cooperatively. `serve` joins the pool before
returning. A stop requested before listener publication is remembered. A control
can be reused after `serve` returns, but cannot control concurrent server calls.
`server_endpoint(&control)` returns the bound endpoint and a publication flag,
which is useful when `port=0`. Keep control, database, logger and configuration
storage alive until `serve` returns.

### Connection capacity

`Server.initial_connections` selects startup storage (default 64, clamped to
`max_connections`). `Server.max_connections` is the admission ceiling (default
4,096). Explicit positive maximums keep their hard-limit meaning. To keep a fixed
capacity, set both fields to the same value. Negative values or an initial value
above the ceiling fail startup.

Before admitting a connection that would reach 80% occupancy, the accept task
doubles capacity, clamped to the ceiling. The async runtime stages the ready
queue, I/O slots and free-slot storage, then commits all of them together.
Existing socket tokens, pending I/O, timers and ready-queue order survive;
workers and thread count do not change. Growth retains the expanded storage.
Request bodies, response buffers and connection tasks are still allocated only
for actual connections, not for every reserved slot. Growth temporarily holds
both old and replacement bookkeeping buffers and briefly locks the scheduler
and reactor while allocating/copying; it is not a zero-latency operation.

If expansion fails, admission continues within the old capacity. Expansion is
retried on subsequent admissions at most once per second. At capacity, the
listener makes one nonblocking best-effort `503 Service Unavailable` send and
closes the new socket. Existing connections remain active. Their slots return
after cleanup; a failed new task releases its reservation too.

Successful expansion emits an informational log. Approaching 80% of the ceiling,
failed expansion, or failed task allocation/admission emits a pressure warning,
limited to one per ten seconds per server. Warnings report occupancy, current
capacity, ceiling and failure/rejection counts. These use the configured logger;
external notification delivery is owned by the application.

`server_capacity(&control)` returns a thread-safe `Connection_Capacity` snapshot
and publication flag without opening an HTTP connection: active/current/maximum,
peak occupancy, growth count, growth failures, capacity rejections and admission
failures. The snapshot is unavailable after unpublication; keep `Server_Control`
alive until `serve` returns. Custom logging happens outside the capacity lock.

An optional `Server.runtime_allocator` supplies the thread-safe allocator used
for runtime bookkeeping and worker setup; zero selects the normal heap. Keep
its backing state alive until `serve` returns. Its
callbacks must not reenter the server/runtime. The maximum bounds connection
count rather than total process memory: request limits, response sizes and
handler allocations still matter when selecting a ceiling.


## Local environment configuration

Call `load_environment_file()` before reading application settings or starting
workers. It loads `.env` from the working directory by default and accepts an
explicit path. Missing files are optional; malformed files fail with a line
number, without logging their values. Call this at application startup.

The loader supports `KEY=value`, optional `export`, comments and single/double
quoted values. It does not execute shell commands or expand variables. Exported
process variables (including empty values) override the file, and duplicate keys
within a file use the final assignment. Keep application values in the root
`.env`, not in the Saba source package. The root `.env` is ignored by Git.

## Routes and handlers

The configured handler receives `^server.Connection` and `^server.Request` and
returns a `server.Response`. The router returns the selected handler's response;
the connection worker sends it once:

```odin
router :: proc(conn: ^server.Connection, request: ^server.Request) -> server.Response {
    if server.match_route(request, "GET", "/messages/:id") {
        return handle_get_message(conn, request)
    }

    return server.not_found(request)
}
```

For a file response, return `server.serve_file(request, "web/index.html")`.

For opt-in bounded large downloads with single byte ranges, use
`server.serve_file_stream(request, "downloads", "release.zip")` through the async
server. See [file/range policy and ownership](assets/README.md#streamed-file-downloads-and-single-byte-ranges),
including its synchronous filesystem latency and immutable-file requirement.
The application chooses the path; the helper reads the file into request memory
and returns a response for the connection worker to send. It defaults to
`text/html; charset=utf-8`; pass a third argument for other content types, such as
`server.serve_file(request, "web/style.css", "text/css; charset=utf-8")`.
Read failures are logged with the configured path and return `500`, preserving
the existing root-handler behavior. `server.not_found(request)` returns the
shared `404` response with a `Not Found` body. Live-reload injection still happens
centrally when sending successful HTML responses.

### Static asset directories

Declare public asset directories on the server:

```odin
assets = {{directory = "web/assets"}},
```

The default URL prefix is `/assets/`; set `prefix` for another mount such as
`/static/`. Saba recursively preloads file bytes before opening the listener and
`serve_assets` serves them before module/page handling and the application router.
No asset list, individual `serve_file` call, or MIME argument is required. For
example, `web/assets/images/logo.png` becomes `/assets/images/logo.png` with
`Content-Type: image/png`.

Types are inferred case-insensitively from file extensions. Stylesheets, scripts,
HTML, JSON, text, images, fonts, media, PDFs, archives, and WebAssembly have known
types; unrecognized extensions and extensionless files use
`application/octet-stream`. Binary and empty files retain their exact bytes.

Production serves the immutable startup cache, even if a source file changes or
is removed. Restart to load new assets. Development also preloads at startup but
reads current files on requests so edits, additions, and removals work with hot
reload. Missing directories, unreadable assets, and invalid mount configuration
prevent startup. The cache lives until the final connection worker finishes.

Asset mounts accept GET and own their configured prefix; missing assets return
404. Hidden paths, traversal, raw JSX, and links outside the directory are not
exposed. Keep only public static files in these directories.

### File-based pages

`Server.pages` maps a directory of JSX pages to HTML routes:

```odin
pages = {
    directory = "web/pages",
    shell = "web/index.html",
    module_prefix = "/pages/",
},
```

Use this alongside a module mount for `web`.
A page exports a default component and a string `title`. `index.jsx` maps to `/`,
`login/index.jsx` to `/login`, `events/index.jsx` to `/events`, and `events/new.jsx` to
`/events/new`. The shell must contain exactly one `<!--saba:page-->` placeholder;
Saba inserts its embedded `/__saba/page-entry.js` bootstrap and selected module URL there.
The bootstrap imports the page, sets its title, and mounts it into `#app`; applications
do not need to supply an entry script. No route registry is
required in either Odin or JavaScript. Page responses run before the application
handler, while unknown URLs continue to it.

When two pages map to the same URL, the directory’s `index.jsx` takes precedence
over the sibling file, regardless of discovery order. Saba logs a warning naming
both files, their shared URL, and the selected source; startup continues. Development discovers
source changes on requests;
production snapshots routes and HTML in the same server-owned arena as compiled
modules. Restart production to load changes. See [JSX components](JSX.md) for the
frontend layout, page contract, runtime, and authoring examples.

### JavaScript module directories

Declare module directories in the server configuration:

```odin
server.serve(server.Server {
    handler = routes,
    modules = {{directory = "web"}},
    development = DEV_MODE,
    hot_reload_directory = "web",
})
```

Saba handles module requests before the application router. Every `.jsx` file
under a mount is available as `.js`, including nested directories, without a
file list. `web/components/Button.jsx` becomes `/components/Button.js`. Ordinary
`.js` files are served through the same mount. For a subtree, configure
`modules = {{directory = "web/components", prefix = "/components/"}}`.

Saba embeds its DOM runtime and serves it at `/__saba/dom.js` in both development
and production, with no application runtime file or configuration. JSX compilation
injects only the helpers it uses, with aliases that avoid component bindings.
Import runtime utilities such as `ref`, `run`, `update`, and `mount` from the same built-in URL.
The endpoint is reserved and served before application mounts. Files without JSX
pass through unchanged. See [JSX components](JSX.md) for the runtime contract.

Development transforms JSX on request, sends `no-store`, and includes source
locations in error responses. New source files are available immediately.
Production preprocesses all mounted JSX and caches JavaScript at startup before
opening the listener. Compilation errors or output collisions fail startup.
Source files are untouched; production changes take effect after a restart.
The server frees its module cache only after its connection workers finish.
There is no standalone build command or generated asset directory.

Unrelated paths and non-GET methods reach the application handler. Static files
under an asset mount are handled by `serve_assets` first. The lower-level
`serve_modules(request, directory, prefix, development)`
helper remains available for custom routing: it transforms development sources
or reads existing JavaScript files; it does not own a production cache. Normal
server applications should use `Server.modules` to get the full startup pipeline.

Raw `.jsx` requests, dot paths, traversal, and links escaping the mounted root
return `404`. HTML routes use `Server.pages`; stylesheets, fonts, and other
static files use `Server.assets`. The module mount does not bundle imports or execute JavaScript.

JSX transformation is handled internally by the module pipeline. See
[JSX components](JSX.md) for supported syntax, component authoring, and runtime behavior.

The application defines `handle_get_message`. It retrieves captures with
`server.path_value(request, "id")`, validates them, and uses `conn.database` with
`db.query_one` and an application row decoder. Empty responses can return a
`Response` directly. For headers, use `make_response` to copy a locally built
header list into request memory:

```odin
return server.make_response(
    request,
    .OK,
    []server.Header{{"Content-Type", "application/json"}},
    body,
)
```

Allocate dynamic bodies and header strings with `request.allocator`; string
literals are also safe. `make_response` copies the header list but borrows those
strings and the body. Do not return references to local arrays or free response
data in the handler. The server owns the request arena and destroys it after the
send succeeds or fails. `context.temp_allocator` also points to this arena while
the handler runs, keeping temporary SQL decoder results alive through sending.

`read_json(request, &input)` allocates decoded data in the request arena and
returns `.None` on success, or an HTTP error status. It never sends a response:

```odin
if status := server.read_json(request, &input); status != .None {
    return server.Response{status = status}
}
```

Request buffers are borrowed for the duration of handling. The existing limits,
deadlines, and supported HTTP framing remain unchanged. Ordinary HTTP handlers
return responses without writing to the connection. The server-owned reload
WebSocket takes a separate path before HTTP dispatch and keeps using the frame
helpers; additional WebSocket endpoints would need their own upgrade dispatch.

## Development live reload

Enable reload when configuring the server:

```odin
server.serve(server.Server {
    port = 8080,
    database = database,
    handler = router,
    development = true,
    hot_reload_directory = "web",
})
```

`development` defaults to false. `hot_reload_directory` defaults to `web` when enabled;
it selects the watched directory, while the application still serves its own UI
files. Each server owns its watcher and reload version.

The server handles `GET /__reload` and `GET /__reload/client.js` before calling
the application router. `send_response` injects the reload script before `</head>`
in successful `text/html` responses and calculates the resulting content length.
An existing client tag is preserved; missing `</head>` produces a logged `500`
response. JSON, error responses, and source files are left unchanged.

The watcher scans recursively every 250 milliseconds and waits for two matching
scans before broadcasting a change. The client reloads the page and reconnects
after a server restart. This preserves full-page live reload; it does not replace
individual JavaScript modules. When disabled, responses pass through unchanged
and the application router receives requests for both reload paths.


## Backend development reload

Call `develop` before opening database connections or other application resources:

```odin
when DEV_MODE {
    handled, success := server.develop(server.Development {
        package_directory = "src",
        shared_packages = {"saba", "async", "auth", "kakunou"},
        build_arguments = {"-define:DEV_MODE=true"},
    })
    if handled {
        if !success do os.exit(1)
        return
    }
}
```

The supervisor initially launches the current executable. Child processes return
`handled=false` and run normal startup. It watches application/shared package
sources and embedded JS, JSON, SQL, HTML, CSS, C and header files. Documentation,
Git metadata, and generated outputs are ignored. Saves settle across two 250 ms
scans before a build. `ODIN` can select a compiler; otherwise it uses `odin`. Rebuilds default to
`-o:none` for short edit cycles; an explicit `-o:` in `build_arguments` overrides
that default. Successful rebuilds print their elapsed compilation time.

Successful builds replace the child after checking for edits made during
compilation. Failed builds leave the current child serving and retry on the next
edit. Build output lives in a temporary directory. Working directory, arguments,
and environment are preserved; applications must forward their compile definitions
through `build_arguments`. Existing browser reload clients reconnect and refresh
after restart. Runtime state restarts, while external databases remain in place.
Ctrl+C/SIGTERM stops child processes and removes temporary builds. A startup crash
is logged and waits for an edit; the utility does not undo database migrations.
This development-only supervisor supports macOS and Linux and must not be enabled
in production.

## Development

This repository is independent of the consuming application. Run its internal
tests from the repository root:

```sh
odin check . -no-entry-point -warnings-as-errors
odin test . -warnings-as-errors
node --test javascript/utilities_test.mjs
```

Run the loopback integration suite with the installed shared dependencies:

```sh
python3 tests/async_server.py
python3 tests/async_server.py --sanitize thread
python3 tests/async_server.py --sanitize address
```

Set `ODIN` to select the compiler. The suite checks fragmented uploads, retained
HTTP error statuses, backpressure, bounded threads with idle connections,
capacity recovery, assets/JSX/pages, reload WebSockets, deadlines and graceful
shutdown. It creates and cleans up only its own temporary files and processes.
Consumers should also test their own routes and handlers against the shared package.

## S3 storage

Saba supports private S3 uploads, deletion, and temporary download URLs through
`s3.odin`. AWS credentials stay on the server and can come from environment
variables, static local profiles, or EC2/ECS IAM roles. See [S3.md](S3.md) for configuration and
bucket permissions.

Applications can set `Server.request_body_limit` to a callback returning a byte
limit for each parsed request. The default remains 4096 bytes. For example, a picture PUT
handler can permit
5 MiB; larger buffers use the request arena and are
released when the connection finishes. Bodies above 4096 bytes have a bounded
30-second read deadline.

## Request deadlines and completion observations

`Server.timeouts` configures total phase budgets with `Timeout_Config{header, body, response, idle}`. Durations must be between zero and `MAX_SERVER_TIMEOUT` (24 hours); invalid values fail before listening. Zero preserves the previous defaults: 5 seconds for headers, 5 seconds for request bodies up to 4 KiB, 30 seconds for larger bodies, and 5 seconds for response writes. An explicit body budget applies to every body size.

Idle limits the wait for the **first request byte**, bounded by the header deadline. The header deadline starts at connection adoption and never resets on progress; body and response deadlines start when those phases begin and likewise never reset. Zero idle uses the header budget. Connections close after responses by default; optional `Server.keep_alive` enables bounded persistence as described in [KEEP_ALIVE.md](KEEP_ALIVE.md). Streaming remains unsupported, and HTTP timeouts do not change reload WebSocket polling/frame policy. Synchronous body/response helpers use the connection's configured budgets too. Handlers and observers remain cooperative; these settings do not preempt blocking application code.

`Server.observability` is optional. Set `enabled = true` for counters, or provide `on_complete` and caller-owned `data` to enable both counters and callbacks. Zero configuration disables clock/counter/route-label work. `server_metrics(control)` copies thread-safe counters while the runtime is published; after shutdown it returns false. `started`, `completed` and `active` describe admitted HTTP attempts: the first starts after connection adoption, later persistent requests on their first byte. Between-request idle/EOF are not extra requests; connection admission failures remain in capacity statistics. A 101 response completes once at upgrade, so later WebSocket frames are outside HTTP metrics.

Each `Request_Event` contains a generated server-local `u64` ID, normalized method, bounded matched route template, prepared HTTP status, total monotonic duration, received/sent wire-byte counts, and completion outcome. `Request.request_id` is zero when disabled. Incoming request-ID headers are ignored. Methods outside the fixed known set become `OTHER`; routes come from a successful `match_route` template, are omitted above 128 bytes, and remain empty if no template was selected. Never assign an untrusted raw path/query to `Request.route`. There are no raw headers, bodies, credentials or user IDs in automatic events, and counters have fixed status-code slots rather than per-path/ID maps.

Received counts include consumed request-head/body bytes; unread pipelined lookahead is attributed only when admitted as the next request. Incomplete heads count the bytes read before failure. Sent counts include successfully written HTTP headers/body bytes. Status is the prepared response status, not a promise it was completely delivered; zero means no status was prepared. Inspect outcome to distinguish successful completion from timeout, cancellation, peer closure, I/O, allocation or protocol failure. The `errors` counter counts non-Completed outcomes; use status counters separately for application HTTP failures. Cumulative duration saturates at its representable maximum.

The synchronous completion hook runs exactly once on the finishing worker, before request storage is freed and outside server/runtime locks. Different requests can invoke it concurrently. Keep `data` and its state valid until `serve` returns, make adapters thread-safe, and copy any retained event/strings before returning. Observers can query snapshots and request stop/drain. They must remain fast, avoid blocking, and must not reenter `serve`. No default request logging or external metrics dependency is introduced.

### Measured overhead and limits

A five-repetition, optimized 100,000-attempt **helper lifecycle microbenchmark** on the development machine measured medians of 1.33 ns disabled, 50.41 ns with counters, and 50.66 ns with an empty hook. This excludes HTTP I/O, initialization and real adapter work; it is not an end-to-end latency/throughput or RSS claim. Repeat `observability_overhead_benchmark` with `-define:SABA_OBSERVABILITY_BENCHMARK=true` for local measurements.

Inline bounded state avoids per-request observation allocations but has a fixed layout cost even when disabled. In the measured build, `Connection_Task` grew from 1864 to 2056 bytes (+192, including its connection); `Connection` from 56 to 96 bytes (+40, already included in that task delta); `Server_Runtime` from 1024 to 6008 bytes (+4984 per server). At 4096 simultaneously allocated tasks, the task delta is 768 KiB. These are struct sizes for this change, before other features such as drain; allocator/RSS and other architectures may differ.

### Validation

`tests/observability_timeout.py` builds only an isolated owned loopback fixture. It covers generated IDs and static routes without secret reflection, exact wire bytes, HEAD, slow headers/first-byte idle, partial body deadlines, stalled response writes, exactly-once shutdown cancellation, observer snapshots, and shutdown unpublication; `--sanitize address` is supported. Focused unit tests also exercise disabled operation, defaults/validation, duplicate completion and 4-thread snapshot consistency. The benchmark is an optional explicitly selected test and does not impose timing thresholds.

## Bounded chunked request bodies

Core and facade servers accept `Transfer-Encoding: chunked` through the shared
HTTP/1 framed parser and incremental chunk decoder. The route/body-limit callback
runs after headers; `request.chunked` is true and the eventual decoded length is
not yet known. Its returned limit bounds decoded bytes (default 4096). Chunked
requests additionally have the shared 64 MiB hard envelope. Negative route limits
reject the request. For this full-body handler API, chunked reads reserve the
effective body limit plus one bounded decoder/input scratch owner in the request
arena, even for an empty body; choose route limits accordingly. This does not add
streaming handlers or separate global byte admission.

Handlers receive only complete decoded `request.body`; `content_length` is then
its actual length, `chunked=true` and `has_content_length=false` preserve the
original wire framing. Original headers remain unchanged. `read_json` accepts
completed chunked bodies. Auth's Saba adapters pass the decoded-length knowledge
into their transport-independent mapper. Custom adapters that require wire
Content-Length must explicitly handle `request.chunked` as well.

Chunk/extension/trailer limits are shared with `http/v1`: 1024-byte lines including
CRLF, 4096 nonempty chunks, 64 KiB total framing metadata, 8192 trailer bytes and
32 trailer fields. Trailers are validated and discarded, never merged into
request headers. Size/cap violations return 413, malformed framing/forbidden
trailers/premature EOF return 400. CL/TE combinations and duplicate transfer
coding return 400; unsupported codings return 501. Expect remains unsupported
(417). Errors close the connection, leaving no unread body to become a request.

Unknown-length bodies use the configured total body deadline (default five
seconds); progress does not extend it. Async reads suspend on the existing task.
Coalesced bytes after the final trailer remain available for the next keep-alive
request, and observability accounts only consumed wire bytes, including metadata.
The blocking `read_request_body` helper also supports chunked input, enforces the
provided destination capacity and preserves buffered next-request bytes.

Reproduce with `python3 shared/saba/tests/chunked_requests.py --odin ./odin
--sanitize address` from the Odin root. The harness uses an independent Python
HTTP chunk encoder as well as fragmented/malformed raw wire fixtures. It checks
all split points, decoded/metadata bounds, EOF, total deadlines, cancellation,
keep-alive and exact metrics on test-owned loopback sockets.

## Cooperative request lifetime

Handlers receive a borrowed `request.cancellation` context. Poll it with
`request_cancelled` or inspect `request_context_status`/`request_deadline`.
`retain_request_context` creates an independently owned handle; release each
retained handle once through `release_request_context(&owner)`. Releasing the
same cleared variable again is harmless; copying a handle creates an alias, not
another reference. Retain before publishing to another thread and keep each
handle valid while using it. The borrowed request handle must not be released.

Contexts own only a small cancellation node and a reference to shared server
cancellation state. They retain no request allocator, body, headers, connection,
socket, runtime, callback data or response. Retained handles can be inspected and
released after request-arena reset or `serve` returns. Host work must copy its
inputs into separately owned memory and bound its own outstanding jobs/handles;
a retained context does not make borrowed request memory safe or publish a result.

The first observed terminal status is stable: Completed, Deadline, Shutdown,
Peer_Closed or Failed. Successful response completion (or upgrade handoff) ends
the HTTP request; keep-alive creates a fresh context for each request. Immediate
stop and drain expiry reach running cooperative handlers even with a single
worker. I/O failures cancel independently of observability configuration.
Disconnect is observable when I/O reports it: there is no background peer monitor
while a synchronous handler runs. Nil contexts are Unavailable, allowing direct
non-server adapter calls to preserve their existing behavior.

`Server.handler_timeout` optionally sets a monotonic context deadline at handler
entry; zero preserves the existing absence of a handler deadline. Negative or
more than 24 hours is invalid. Work must poll cooperatively. A response returned
after expiry is discarded and replaced by a closing 408; a response returned
after shutdown is discarded. Discard releases transferred continuations exactly
once. Context deadlines remain visible to retained work; existing read/write phase
deadlines continue to govern I/O. Arbitrary blocking work is not forcibly
preempted, and `serve` still joins running callbacks before returning. Callbacks
in the header/body-limit stage precede creation of the handler context.

Run `python3 shared/saba/tests/cancellation.py --odin ./odin --sanitize address`
(or `--sanitize thread`) from the Odin root. It checks retained handles across
keep-alive/teardown, late-response disposal, one-worker stop/drain and observable
peer failure using owned sockets. This API does not itself add blocking-job
workers, asynchronous result publication or distributed cancellation.

## Bounded streamed responses and SSE

Set `Response.stream` instead of `body` or `upgrade`. `Response_Stream` provides
host-owned `data`, a serial bounded/nonblocking `next(data,io)` callback, optional
`drop(data)`, representation `content_length` (`-1` unknown), byte limits and a
lifetime timeout. Returning the response transfers producer ownership to the
async server even when metadata validation or sending fails. A supplied drop runs
exactly once outside internal locks, after all accepted chunks are released. With
nil drop, the host retains ownership and keeps producer data alive through serving.
`discard_response` disposes an unqueued response, including a transferred stream.
The blocking `send_response` helper rejects/disposes streams; drive them through
core/facade `serve`. Existing buffered responses and upgrades keep their APIs.

`next` returns one `Stream_Step`:

- **Chunk:** first call `stream_submit(io,&owner)` with a valid nonempty
  `core:mem/owned.Chunk`. Accepted clears that exact owner; rejection/backpressure
  leaves it unchanged. Submit only once per callback. Retain and release rejected
  ownership yourself, including from producer drop. Byte admission charges the
  entire backing storage, even when the payload is a smaller view.
- **Waiting:** first arm `stream_wait(io,absolute_deadline)`. Pending means return
  Waiting. Reuse the absolute deadline after spurious wakes. The helper clamps it
  to the stream lifetime and rejects stale runtime epochs. Never return Waiting
  without a successfully armed wait. There is no asynchronous host-job waker yet.
- **Yield:** bounded preparation remains; reschedule without blocking a worker.
- **Done:** production ended. Known lengths must match exactly. Unknown lengths
  emit the final HTTP chunk only after successful production completion.
- **Failed:** abort the response and close; accepted owners still release once.

IO, its runtime pointer and cancellation handle are borrowed only during the
callback; copy request inputs and explicitly retain cancellation for other work.
Callbacks may migrate between workers and must not perform concurrent operations,
retain IO or touch the socket. Generic producers must not block on host work.
The opt-in file adapter is an explicit exception for synchronous bounded file
reads and documents their non-preemptible latency; general blocking job offload
remains separate work. An accepted chunk is never polled past: one
shared `http/exchange` slot retains it until its last partial write completes.
The producer is called again only after release. This uses the common owned-chunk
and exchange acceptance/length/teardown contracts, without a full-body copy.

Default retained backing per stream is 64 KiB, configurable up to 1 MiB; default
total produced-body limit is 8 MiB, separately configurable as a positive i64.
These are distinct from connection admission, producer-owned rejected buffers,
request-arena memory, kernel buffers and future global byte/job budgets. The
request arena remains alive through stream completion, so producer code must use
releasable chunk owners rather than repeatedly accumulating request allocations.
Streamed heads are bounded to 128 fields and 8 KiB on wire; header snapshots
and one-slot bookkeeping are separately allocated. A zero timeout
inherits the normal response timeout; an explicit positive timeout up to 24 hours
bounds the whole stream. A configured request-context deadline shortens it.
Each header/chunk/terminal write also has its own fixed response-write budget,
clamped to remaining lifetime. Progress does not extend either budget.

Known lengths use Content-Length; unknown lengths use generated HTTP/1 chunk
framing. HEAD and body-forbidden statuses dispose the producer without polling it
and transmit no body. Length mismatch, producer failure, timeout, disconnect and
shutdown close the connection and dispose pending owners. No successful chunked
terminator is sent after a producer error. Buffered and streamed responses may
reuse keep-alive serially. Streaming HTML bypasses development reload injection;
that transformation requires a complete body. Client delivery acknowledgment is
separate from local acceptance and storage release.

`examples/sse` is a runnable core-only server: build/run it, read its `ready PORT`,
then use `curl -N http://localhost:PORT/events`; press Enter to stop. It sends four
UTF-8 events interleaved with four comment heartbeats, uses timer suspension,
1 KiB chunk backing, a finite 64 KiB body budget and 15-second lifetime. Slow
readers are bounded by the one-second write budget; cancellation releases pending
chunks. This demonstrates framing/heartbeat/cancellation rather than event replay,
Last-Event-ID persistence, authentication or deployment buffering policy. See
[the EventSource format](https://html.spec.whatwg.org/multipage/server-sent-events.html).

Run `python3 shared/saba/tests/streaming.py --odin ./odin --sanitize address` from
the Odin root; `--sanitize thread --workers 4` covers worker concurrency. The
harness tests the actual example as well as independent HTTP decoding, partial
writes, exact owner release, pipelining, contract errors, timers and slow readers.
