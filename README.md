# Saba

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
`$(odin root)/shared/kakunou`. SQLite and libcurl must be installed as system
libraries. Projects import both through Odin’s built-in shared collection:

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
each handled connection closes when its handler returns. Before `serve` returns,
it stops and joins its watcher and waits for its connection workers to finish.

### Connection capacity

`Server.max_connections` bounds admitted connections before worker creation and
request-body allocation. Zero selects the default of 64; a positive value sets
an explicit limit, and negative values fail startup. WebSockets and requests
waiting for headers or bodies count toward the same limit.

When full, the listener makes one nonblocking attempt to send `503 Service
Unavailable` and closes the new socket. Delivery of that response is best effort;
the listener does not wait for a rejected client to read. Capacity returns after
the admitted connection's request memory and socket are released, including error
paths and WebSocket closure. Failure to create a worker releases its reservation
as well.

This bounds concurrent request resources; each admitted request still has its own
body-size and I/O deadlines. For example, 64 simultaneous requests at the app's
5 MiB upload limit can reserve up to 320 MiB of body buffers, in addition to other
server memory. Choose a lower connection limit for a smaller memory budget.

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
both files, their shared URL, and the selected source; startup continues. Development discovers source changes on requests;
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
under an asset mount are handled by `serve_assets` first. The lower-level `serve_modules(request, directory, prefix, development)`
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

## Development

This repository is independent of the consuming application. Run its internal
transformer tests from the repository root:

```sh
odin check . -no-entry-point -warnings-as-errors
odin test . -warnings-as-errors
node --test javascript/utilities_test.mjs
```

Consumers should test their own routes and handlers against the shared package.

## S3 storage

Saba supports private S3 uploads, deletion, and temporary download URLs through
`s3.odin`. AWS credentials stay on the server and can come from environment
variables, static local profiles, or EC2/ECS IAM roles. See [S3.md](S3.md) for configuration and bucket permissions.

Applications can set `Server.request_body_limit` to a callback returning a byte
limit for each parsed request. The default remains 4096 bytes. For example, a picture PUT handler can permit
5 MiB; larger buffers use the request arena and are
released when the connection finishes. Bodies above 4096 bytes have a bounded
30-second read deadline.
