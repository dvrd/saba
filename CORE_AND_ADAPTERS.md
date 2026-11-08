# Lean core and import-selected adapters

`shared:saba/core` owns HTTP/1 connection tasks, routing, request parsing and
response serialization, bounded keep-alive, deadlines, metrics, capacity and drain.
Wire parsing/framing and response-head encoding remain in `shared:http/v1`; this split adds no HTTP parser. The additive HTTP/1 response profile owns close, keep-alive and 101 upgrade wire output. The Saba wrapper retains default status, body policy and its 8192-byte response limit. Caller-supplied hop-by-hop fields (Keep-Alive, Proxy-Connection, Trailer and TE) are now rejected alongside managed framing fields; Upgrade is permitted only for 101 and must name a nonempty selected protocol. This intentionally hardens fields that the old wrapper did not reserve. The original HTTP120 close encoder interface and byte ordering remain unchanged.
The core imports `shared:async` and `shared:http` (HTTP uses `shared:ascii`) plus
Odin primitives. It has no database, authentication, S3, filesystem assets, pages,
JSX, watcher or WebSocket implementation imports.

Importing `shared:saba` keeps the convenience server and old two-argument handler,
including typed `conn.database`. It deliberately imports the optional packages.
Setting `development=false` changes runtime behavior; choosing the core and
selected imports changes the compiled dependency graph. No enable/disable flags
pretend to remove dependencies already imported by the facade.

| Import | Responsibility |
| --- | --- |
| `shared:saba/core` | Lean HTTP/1 server, pre-header deferred responses and protocol-neutral upgrade continuation |
| `shared:saba/offload` | Optional bounded blocking-work lane integration |
| `shared:saba/assets` | Prepared static mounts and files |
| `shared:saba/modules` | Prepared JS/JSX modules; imports assets, JSX and paths |
| `shared:saba/pages` | Prepared file pages; imports modules |
| `shared:saba/jsx` | JSX transformation |
| `shared:saba/development` | Supervisor, watcher, HTML injection, reload WebSocket adapter |
| `shared:saba/s3` | Thin compatibility adapter delegating credentials/signing/service I/O to AWS |
| `shared:saba` | Compatibility facade composing these packages and Kakunou |

Authentication remains in `shared:auth` and continues importing the facade. Core
does not import auth. Further auth decoupling is separate work; the optional S3 adapter delegates to AWS.

## Selecting assets without importing the facade

```odin
import server "shared:saba/core"
import assets "shared:saba/assets"
import "core:mem"

Application :: struct { assets: []assets.Asset_Cache }

routes :: proc(data: rawptr, conn: ^server.Connection,
               request: ^server.Request) -> server.Response {
    app := cast(^Application)data
    if response, matched := assets.serve_assets(request, app.assets, false); matched {
        return response
    }
    return server.not_found(request)
}

run :: proc() -> bool {
    arena: mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena)
    defer mem.dynamic_arena_destroy(&arena)
    allocator := mem.dynamic_arena_allocator(&arena)
    prepared, ok := assets.prepare_assets({{directory="web", prefix="/"}}, allocator)
    if !ok do return false
    app := Application{assets=prepared}
    return server.serve({port=8080, handler=routes, handler_data=&app})
}
```

Prepare only chosen adapters before `serve`; their cache memory and handler_data
must remain alive until `serve` returns. Adapters return the same core Response
and borrow request.allocator for per-request allocations. Preparation errors are
returned to the application. There is no automatic request allocation for handler
state or a facade Connection wrapper.

Core handlers receive the real core connection and explicit caller-owned data.
Facade handlers receive a stack Connection view containing the application's
borrowed database pointer. The view is valid only during that synchronous
handler/helper call: never retain its pointer. Helpers copy transport mutations
back before returning, and handler return copies the view back to core. Sockets
still belong to the server; handlers must not close or adopt them. Existing auth
and fixture consumers only pass conn synchronously; no retained pointers were
found in that review. Applications retaining a facade pointer must migrate to
explicit application data rather than keeping this temporary view.

## Optional upgrade ownership

A handler can return status101 and `Response.upgrade={data,resume,drop}`. This
transfers the continuation state to core immediately, including when response
allocation or the101 write subsequently fails. Any supplied drop runs exactly
once, outside internal locks after async I/O has quiesced. State is cleared before
drop is invoked. Non101 continuations or a continuation with no resume are
rejected and dropped. Nil drop is allowed for stateless/caller-owned state; the
caller then keeps data alive until serve returns. Continuation data cannot borrow
the HTTP request arena: that arena is released after101 completes.

Resume executes serially on the existing task and may migrate across workers.
It receives a borrowed Upgrade_IO and returns the normal async Resume_Result.
Use core.upgrade_read for saved prefetched bytes before socket reads. Do not
retain IO or its prefetched slices, concurrently perform I/O, block a worker, or
close/adopt the socket. An adapter sets connection.read_deadline with its async
deadline. The core owns scheduling, native close, saved bytes and cancellation;
the adapter owns protocol state/framing. Development reload WebSocket framing is
entirely in `development/session.odin`. A pending upgrade is cancelled by shutdown
or the configured drain deadline; already established sessions are not new HTTP
requests and do not emit additional HTTP completion events.

## Pre-header deferred responses

`Response.deferred` transfers a `Deferred_Response {data, poll, drop, timeout}`
to the existing connection task before any response head is committed. Return it
alone: status, headers, body, close flag, stream and upgrade must remain zero.
Poll and drop run serially on the owner outside locks; poll must be bounded and
nonblocking. Poll returns Waiting, Ready with the final Response, or Failed. Ready
may select a normal response, stream or upgrade, but cannot recursively defer.
Drop runs once on invalid setup, failure, completion, cancellation or shutdown.

`Deferred_IO` borrows the request allocator/context and a detachable wake signal
for the call. Retain the signal separately before publishing it to a job. Never
publish raw request/connection/runtime/task pointers or the request allocator.
The server detaches every retained producer signal before retiring its target.
A successful result must copy its data to the live owner arena before independent
job storage is released. `shared:saba/offload` implements that ownership bridge;
see [its contract](offload/README.md).

The total pre-header budget inherits the response timeout by default and is capped
by the handler deadline. A late result cannot change the final status after expiry.
While waiting, bounded read readiness observes peer EOF and saves at most the normal
8192-byte header limit of pipelined input. Overflow closes without dispatching the
pipeline. Existing keep-alive reuses preserved bytes only after the ready response
is sent. Shutdown/drain detach the target without joining non-interruptible jobs on
a network worker. Blocking `send_response` rejects and disposes deferred responses.

## Compatibility and migration

Named and zero-value facade Server/Response fields and two-argument Handler work
as before. Root aliases preserve Request, HTTP statuses, response/routing helpers,
optional mount/cache types and helpers, plus S3 public functions. Core Handler adds
explicit `data:rawptr` and Server.handler_data; core has no database field. Core
Connection and facade Connection are different types. Use the matching helper
package for each; do not cast between them.

Response includes Upgrade, Response_Stream and Deferred_Response fields. Positional
Response literals must supply the current fields or use named fields; Connection layouts and previously public implementation structs
also changed. They are source interfaces, not a binary ABI. Root aliases for
Connection_Task/Server_Runtime remain for diagnostics but no longer expose
WebSocket/cache/database implementation fields. Private helpers are not aliases.
Manual inclusion of the old flat .odin implementation files must become package
imports. Browser resources moved from javascript/ into modules/ and development/;
public URLs are unchanged. Mesa remains on its existing bundled server until a
separate explicit migration; this change does not claim its application refactor.

## Measured scope and checks

Historical extraction measurements on macOS arm64 with Odin c826157de, sizes in bytes
(the later offload layout change is measured separately in [RESULTS91.md](RESULTS91.md)):

| Type | Before split | Core | Facade |
| --- | ---: | ---: | ---: |
| Server | 288 | 184 | 288 |
| Connection | 96 | 80 | 64 (temporary view) |
| Connection_Task | 2080 | 1672 | 1672 |
| Server_Runtime | 6080 | 5776 | 5776 |
| Response | 48 | 72 | 72 |

The task removes fixed reload frame/output arrays; reload session state is
allocated only for actual upgrades. Ordinary requests add no facade wrapper
allocation (tracked allocation regression verifies zero). These are layout and
allocation checks, not RSS or end-to-end performance claims. The same optimized keep-alive serving fixture measured 522144 bytes before the
split, 522272 through the facade and 367104 through core (`-o:speed`, same compiler
and macOS arm64 target). Baseline/facade linked Foundation and libSystem; core
linked only libSystem. Unused SQLite/curl symbols were already omitted in the
baseline: importing a package does not imply all its code is retained. These
fixture-specific sizes are not a general application size or throughput claim. A clean collection containing only
async/http/ascii/saba/core compiles a core consumer, and adding only assets/paths
compiles the selected-assets consumer. An actual core serving fixture links only
libSystem and contains no SQLite/curl/optional-adapter symbols.

The same19-case public keep-alive corpus runs through facade and core with
`tests/keep_alive.py --core`; omit --core for facade. Existing async development,
assets, modules/pages and reload WebSocket wire fixtures still run through the
facade. `core/tests/upgrade.py` exercises raw upgrades, prefetched/fragmented
reads, stateless callbacks, rejected upgrades, peer-reset/write failure and
shutdown ownership. Core/facade/auth units retain their normal test commands.
