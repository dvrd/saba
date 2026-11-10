# Database-free server composition

Import `shared:saba/application` for reusable assets, JavaScript modules, pages
and development reload around `shared:saba/core`. It has no database dependency.
Business handlers use the real `core.Handler(data, connection, request)` and
`core.Request`/`core.Response`; no application-local server facade is needed.

```odin
import application "shared:saba/application"
import core "shared:saba/core"

handler :: proc(data: rawptr, connection: ^core.Connection,
                request: ^core.Request) -> core.Response {
    return core.make_response(request, .OK, nil, []u8{'o', 'k'})
}

// Keep config, handler_data and borrowed mount inputs valid through return.
ok := application.serve({server = {port = 8080, handler = handler}})
```

`Config.server` preserves core resources, deadlines, cancellation, observation,
keep-alive, streaming, deferred responses, upgrades and drain behavior. Optional
mounts are prepared before listening and destroyed after the server and watcher
retire. Built-in development/runtime routes precede assets, modules, pages, then
the business handler. Development injects its client into buffered HTML, never
into a streaming response.

`Config.dispatch` is an optional handler adapter for the existing Saba legacy
facade. It is mutually exclusive with `server.handler` and uses
`server.handler_data`. Its `Dispatch_Context` pointers and development reload
state are borrowed only until the callback returns. Calls run outside internal
locks and retain the core's cooperative handler requirements. Normal applications
should use `server.handler` directly.

For backend rebuilds, call `shared:saba/development.develop` before opening
application resources. `Development.compiler` explicitly selects a compiler
launcher; empty retains the `ODIN` environment then `odin` default.
`watch_directories` adds up to128 explicit source roots independently of the SDK's
`shared/` directory. Existing `shared_packages` and build arguments remain valid.
These helpers do not add HTTPS or HTTP/2 server integration.
