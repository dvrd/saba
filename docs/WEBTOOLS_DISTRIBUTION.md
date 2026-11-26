# Webtools distribution and public ownership

Current implementation inventory, 2026-11-09. Tracking:
[OKAMI-108](https://linear.app/devoured/issue/OKAMI-108).
This guide distinguishes shipped owners from planned work.
A package existing on disk, an executable consumer, a native protocol test and
application integration are different evidence levels.

## Source and repository boundaries

`shared/` contains separate nested Git repositories. Run Git in the owning
library (`git -C shared/http ...`, for example); a clean parent Odin status says
nothing about an ignored nested repository. Core TLS/net/memory primitives,
parent `ci/` and these cross-library documents belong to Odin. Commit dependency
libraries before their consumers and preserve each repository's history.

A checkout/worktree is an evidence input, not a disposable copy. Preserve
`.webtools-worktrees/`, including partial native133 platform-trust/TLS work and
SDL artifacts. Keep Mesa's unrelated edits, application layout, toolchain and
vendored adaptations intact. Distribution checks use physical temporary copies;
they must not synchronize over application sources or replace its compiler.

### Network, TLS and ownership primitives

| Import | Actual owner and boundary |
| --- | --- |
| `core:net` | Sockets, endpoints, resolver/connection interfaces and bounded resolver snapshots. It does not implicitly import a complete QUIC stack. |
| `core:crypto/tls` | Native TLS authentication, handshake/secrets and TCP record processing, blocking/async client and server APIs. Its executor/connection contracts are explicit; crypto is not an HTTP policy layer. |
| `core:nbio` | A core event-loop backend and adapters. It is not an alias for the shared task runtime. |
| `core:net/quic` | QUIC wire/protection, bounded connection recovery and deterministic simulation. `core:net/quic/conn` retains application STREAM/FIN data until acknowledgment and adopts authenticated TLS state; HTTP/3 semantics stay in shared HTTP. |
| `core:mem/owned` | Owned chunks and bounded queues, full-backing release/provenance and explicit transfer. Local acceptance/release is distinct from peer delivery/acknowledgment. |
| `core:sync/budget`, `core:mem/budget` | Hierarchical byte/stream/job admission and retained managed allocation bindings. Capacity metadata does not raise admission limits. |
| `shared:async` | Bounded task scheduling, task-owned native TCP/UDP, timers, cancellation, affinity and explicit Runtime lifecycle. It implements an execution model rather than renaming core sockets. |
| `shared:async/connection` | A task-owned bridge to core connection/executor interfaces, request budgets and nonconsuming transport probes. TLS stays in core. |
| `shared:async/signal` | Retained wake handles for explicit target lifetime; not ownership of an application Task or a new executor. |
| `shared:async/offload` | Explicit bounded blocking-job lane, retained work/results and lifecycle. Network callbacks remain cooperative; offload is opt-in. |

Refer to each core/shared package README for exact synchronization, accepted
operation, deadline and destructor contracts. Copying an Odin owner struct does
not create a retained owner. Thread-safe operations also require a suitably
concurrent backing allocator; retain its context through late physical frees.

### HTTP, WebSocket, clients and services

| Import | Actual owner and dependency direction |
| --- | --- |
| `shared:files` | Bounded regular-file snapshots. `files` preserves the recorded owned Mesa extraction and imports no application paths. |
| `shared:http` | Common request/header/status/method/URL, framing policy helpers and conditional/range semantics. It does not import every HTTP version. |
| `shared:http/v1` | HTTP/1 codecs, strict head validation, explicit fixed/framed request profiles, chunk decoding and close/keep-alive/stream response encoding. No routing/pooling/socket owner. |
| `shared:http/exchange` | Version-independent response metadata, body-chunk admission and completion/cleanup. Hosts own connection/stream mappings and I/O. |
| `shared:http/v2` | Implemented bounded sans-I/O HTTP/2 engine for client/server roles: frames, settings, flow control, stream/header/data ownership and lifecycle. It supplies no TLS, routing, origin pool or retry policy. |
| `shared:http/v2/hpack` | Native HPACK primitives, tables and incremental field sections. Delivered header storage is independent of dynamic-table eviction. |
| `shared:http/testsupport` | Shared conformance corpus/test support, not a production networking driver. |
| `shared:http/v3` | HTTP/3 framing/QPACK and explicit endpoint/credential QUIC listener/client. Authenticated application traffic uses Core connection recovery; caller limits and ownership remain explicit. |
| `shared:websocket` | Pure upgrade/frame validation and caller-driven message assembly. No dial/client/socket/TLS/session execution. |
| `shared:surf` | Blocking native HTTP and blocking `websocket_*` connection operations, response ownership and service-facing HTTP seams. Its buffered compatibility API uses the native stack; HTTP/3 is opt-in. |
| `shared:surf/async` | Persistent native HTTP/1 Client with buffered compatibility and optional owned upload/response streams, explicit identity/gzip decoding, bounded retained credits, deadlines/cancellation, redirects and physical retirement on an existing Runtime. Async WebSocket and HTTP/2 adapters remain separate work. |
| `shared:surf/async/exchange` | Incremental HTTP/1 request/response engine over explicit async connection/executor interfaces. Client pool/trust/admission policy remains with its host. |
| `shared:aws` | Credentials, SigV4, S3/SES service semantics and provider seams; depends on `files`/Surf, not Saba or private Mesa helpers. |
| `shared:google` | Strict credential/token JSON and Google service clients; depends on files/HTTP/Surf. Its documented serialized token-cache contract remains in force. |

`surf/async/stream` supplies internal detached channel/credit ownership for the
Client and exchange; it is not an additional standalone application consumer
root. Public stream handles, heads and owned chunks are documented in
`shared/surf/async/STREAMING.md`. Taking a head/chunk does not refund retained
credit; the owner can outlive its request, Client and Runtime. Only a successful
stream End certifies framing and decoding integrity.

The streaming implementation requires paired Core `18bd5dad0` sources: incremental
DEFLATE/gzip and Decode_Error from `66aab4299` plus the owned-length validation
repair. HTTP `f557430` supplies request negotiation; async `5ac65b6` or later
supplies the earliest-timer operation used by the stream watchdog. The recorded
DAC83 compiler/LLVM22 pairing is
unchanged. Updating library files alone does not update an application SDK pin;
validate the actual application source/Core closure separately.

`shared/web-client` was renamed to `shared/surf`. `shared/transport` was removed;
import the actual `core:net` interfaces instead. HTTP/1 wire APIs moved under
`shared:http/v1`; common types remain at `shared:http`. Do not recreate removed
paths as independent implementations. Both HTTP/2/HPACK and HTTP/3/QPACK are implemented. Surf and Saba provide
protocol integration; validate their owned wire suites as well as the codecs.
Historical backlog completion alone does not establish interoperability or
application integration.

### Server and auth composition

| Imports | Ownership |
| --- | --- |
| `shared:saba/application` | Database-free composition of core, assets, modules, pages and development. Applications register core handlers and configure reusable routing/reload infrastructure directly. |
| `shared:saba/core` | Lean HTTP/1 task/listener with optional native TLS 1.3, routing, request/response lifecycle, keep-alive, deadlines, observability and drain. It reuses HTTP codecs and shared async; it imports no auth/database/assets/pages/JSX implementation. |
| `shared:saba/assets`, `modules`, `pages`, `jsx`, `paths` | Import-selected asset/module/page preparation, transformations and path utilities. Filesystem/transform work keeps its documented latency/ownership policy. |
| `shared:saba/development` | Development supervisor and reload WebSocket service. |
| `shared:saba/websocket` | Explicit application upgrade/origin/subprotocol policy and bounded resumable WebSocket sessions on existing HTTP/TLS tasks, reusing shared codecs. |
| `shared:saba/offload`, `shared:saba/s3` | Optional bounded blocking-work and AWS compatibility adapters. S3 signing/service behavior belongs to AWS. |
| `shared:saba` | Convenience facade composing core/optional adapters and Kakunou. Many public types alias core, but its Connection/handler view preserves facade/database compatibility; it is not the lean import. |
| `shared:auth/core` | Explicit authentication services/store/crypto dependencies without Saba/SQLite/Surf imports. See `shared/auth/EXPLICIT_SERVICE.md`. |
| `shared:auth/http`, `sqlite`, `surf`, `saba`, `offload` | Explicit HTTP/provider/store/server/offload integration adapters. Their import graphs, not runtime disable flags, choose dependencies. |
| `shared:auth/conformance` | Reusable store conformance helpers; distinguish a consumer of these helpers from live application/database certification. |
| `shared:auth` | Legacy convenience facade retaining Saba/Kakunou and existing integration behavior. It does not make all optional imports disappear. |

Kakunou, SQLite and other dependencies remain actual transitive dependencies of
selected facades/adapters. They are not silently added as new Webtools roots or
replaced with application-private helpers. Service signing, credential/refresh
policy and replay safety remain in AWS/Google/auth; a generic HTTP consumer does
not certify them. Run their offline injected-provider fixtures as well.

## Supported consumer catalog and evidence levels

The generic consumer gate (`ci/webtools_consumer_gate.py` in the parent Odin checkout) preserves the original
12 default roots/order and explicit `--packages` selection. Those defaults are
HTTP common/v1, Surf, AWS, Google, Saba, async, auth, WebSocket, HTTP exchange,
HTTP/2 and HPACK. Historically, the first nine consumers were import/build/link probes and the
three protocol additions executed bounded public API assertions. Preserving the
12-root selection does not freeze those weaker assertion bodies: current consumer
source, catalog API flags and executed report establish each root's actual level.
Neither level is a complete public API/runtime gate.

The explicit Webtools catalog (`ci/webtools_modules.json`) identifies 38 buildable
roots: ASCII/files; TLS compatibility; HTTP common/exchange/v1/v2/HPACK/v3/testsupport;
Surf/blocking+async+async-exchange; async/connection/offload/signal; Saba and its eleven
core/adapter packages; auth and its seven adapter/conformance packages; AWS, Google
and WebSocket. Entries distinguish `supported`, `compatibility`, `test-support`,
`docs-only` and `removed` status and whether a public API consumer exists.
Of the38 executable roots,37 have bounded API or corpus assertions;
`auth/conformance` is a callable-binding smoke check only, not a fake Store
behavior pass. `http/testsupport` asserts public corpus data, not protocol I/O.
The catalog is an explicit support list, not a scan that treats every shared
folder as supported. HTTP/3 has an offline framing assertion consumer; its
UDP/TLS/recovery behavior requires separate wire tests. Removed paths are status
records, not executable passes. A dependency copied for a root is not automatically another certified root.

Run from an Odin checkout, using explicit matching compiler/Core/shared sources:

```sh
python3 ci/webtools_consumer_gate.py \
  --odin /absolute/path/to/odin \
  --source-root /absolute/path/to/Odin \
  --shared-root /absolute/path/to/shared \
  --catalog ci/webtools_modules.json \
  --evidence-dir /tmp/webtools108-consumers \
  --report /tmp/webtools108.json
```

`--catalog` and `--packages` are alternative selections; omitting both retains the
original12 defaults. Use a fresh evidence directory: retained closures, consumers,
binaries and logs are evidence, not overwriteable scratch. Source roots never
fall back to a second installation. A partial candidate containing only HTTP
cannot provide complete service/facade dependencies.

The copier follows supported literal imports and literal `#load` resources,
copies regular files/notices and excludes Git metadata. It rejects missing,
private/out-of-tree dependencies; it does not emulate arbitrary generated imports
or runtime resource discovery. It scans imports in all package `*.odin` files,
including `*_test.odin`; copied test-only dependencies make this a conservative
source closure, not proof of minimal compiled imports or linked libraries.
Inspect every transitive closure and retain its source/copied SHA maps. A healthy empty executable baseline must precede consumers;
failed/skipped/unsupported entries must not become passes. The catalog/gate is
not certified merely by being documented: use the exact completed report for
which roots and assertions actually executed.

Evidence levels must stay explicit:

1. **Inventory/source audit:** public owners, imports and provenance are known.
2. **Executable consumer:** physical vendored closure builds, links and runs real
   selected public API assertions; it does not certify every operation.
3. **Semantic/API parity:** shared fixtures compare each declared supported
   contract across owners/adapters, including allocation/lifecycle outcomes.
4. **Native protocol fixture:** actual owned independent peers and recorded wire
   behavior, sanitizer/cleanup and exact source/binary bindings.
5. **Application integration:** a specific Mesa/toolchain/adapter snapshot passed
   its own gate. None of the earlier levels implies a full application build.

## Shared/Mesa semantic and compatibility gate

Run the independent Mesa parity gate (`ci/webtools_mesa_parity.py`) with both
modern and application-pinned toolchains, and put its report outside Mesa:

```sh
python3 ci/webtools_mesa_parity.py \
  --odin /absolute/path/to/modern/odin \
  --core-root /absolute/path/to/modern/Odin \
  --shared-root /absolute/path/to/shared \
  --mesa-root /absolute/path/to/Mesa \
  --pinned-odin /absolute/path/to/cached/pinned/odin \
  --pinned-core-root /absolute/path/to/pinned/Odin \
  --report /tmp/webtools108-mesa-parity.json
```

The four required executions are shared/modern, Mesa/modern, shared/pinned and
Mesa/pinned. Modern profiles assert finite public HTTP, WebSocket, Runtime,
Signal, scoped-offload and callback-adapter contracts. Pinned profiles assert
HTTP/WebSocket/root Runtime behavior plus named typed Unsupported capabilities.
API additions and legacy codec differences need explicit version/reason and
output-asserted declarations; a blanket “different implementation” waiver is not
parity. Modern sanitation defaults to address; `--sanitize-modern thread` or
`none` selects the stated alternative without changing the pinned toolchain.

Use the actual cached pinned binary directly, not a launcher that may materialize
or repair its cache. The gate copies Mesa's actual sibling dependency layout
verbatim, rejects symlink sources and reports inside Mesa, and does no source
rewriting or synchronization. Preserve compiler/Core/source/copied/binary maps
and exact Mesa HEAD, status and tracked-file hashes before/after. Do not stage,
reset or clean unrelated application work as a validation shortcut.

These are declared public semantic/compatibility profiles, not general API
identity, a whole application build, a Mesa upgrade/migration or certification of
untested capabilities. Supported/new APIs must be distinguished from explicitly
unsupported pinned contracts. Require all four real executions and inspect their
assertions and declarations before recording acceptance.

## Compiler and platform matrix

Read `ci/WEBTOOLS_TOOLCHAIN.md` in the parent Odin checkout before execution. Use the
repository's intended compiler and explicit `ODIN_ROOT`/source root, paired with
its standard-library interfaces and LLVM installation. Record compiler version
and SHA, source revision/dirty state, exact Core/standard-library file maps,
`llvm-config --version`, host/architecture and actual linked libraries. A stable
compiler filename or parent Git HEAD alone does not bind nested libraries or a
modified Core tree.

| Pairing/platform | What the recorded local evidence establishes |
| --- | --- |
| Darwin arm64, `dev-2026-11:c826157de`, binary SHA `dac83d6eb5faaf9f62cef37297f34a0e21dbe3976a8b8a52c81f3db3d90f0b9c`, versioned LLVM22.1.8 | Locally executed Webtools consumer and scoped native ASan/TSan suites. Exact per-gate Core/library maps remain required. |
| Historical isolated worktree build with LLVM23.1.5 | A separately recorded local experiment in the toolchain report; not an expansion of Odin's supported LLVM policy or the default reproduction pair. |
| Linux native backends / cross-target semantic checks | Source implementations and some compilation evidence exist; a typecheck is not Linux runtime/interoperability certification. Require actual Linux execution reports for such a claim. |
| Windows/other targets | Do not infer support from shared names or successful imports. Package-specific unsupported paths return typed errors where implemented; no Webtools-wide native runtime certification is recorded here. |

The starting older compiler/LLVM pairing failed an empty executable. Keep that
negative historical evidence separate from rebuilt compiler results. Consumers,
facade linkage, native networking, TLS, signing and application fixtures each need
their own stated scope; no performance, production-provider or all-platform claim
follows from these local runs.

## Provenance, notices and upgrade procedure

Preserve existing source headers, `LICENSE`/`NOTICE` files, embedded code-component
notices, origin records and owning Git history. `shared/async/LICENSE` currently
matches the parent Odin `LICENSE` byte-for-byte; retain the actual notice rather
than replacing it with a guessed license label. The RFC7541 Huffman table carries
its existing IETF Trust BSD-3-Clause code-component notice inline. Core/vendor
components retain their own notices. Absence of a new package-level license file
is not a reason for this task to invent or impose a blanket license on owned code.

`shared/files/README.md` records its owned Mesa file-helper extraction.
`shared/aws/PROVENANCE.md` preserves Saba origin commit
`8960e829cae3774ac907714f2360dbc5e205d3aa`; original Mesa `src/server`/`src/client`
paths are lineage, not current shared imports. Current source origins and existing
licenses must remain attached to the files actually distributed.

For each upgrade:

1. Record each owning repository's revision, dirty status and source hashes;
   record compiler/Core hashes separately. Preserve the old vendor manifest,
   application adaptation list and protected working-tree snapshot.
2. Select explicit roots, copy their physical dependency closure into a new
   temporary project and run the empty baseline plus required executable/API
   consumers. Check every requested result, source/copy map and linked-library
   report; an aggregate boolean alone does not establish parity.
3. Run declared shared/adapter conformance fixtures and relevant owned native
   suites against that copied source. Preserve typed outcomes, ownership, deadlines,
   trust, redirects and uncertain-write/replay policy; do not weaken assertions
   to make a newer copy match.
4. For Mesa, compare documented public semantics and explicit adaptation boundaries.
   Preserve its compiler, local imports, database-free connection layout, split
   runtime/procedure and codec/toolchain constraints. Use isolated mirrors when
   needed. A source diff is not semantic failure; a source overwrite is not a
   migration plan. Never run live service/credential/application actions as fixtures.
5. Keep complete successful and failed logs, commands, literal fixture inputs,
   binary hashes and before/after source/copy/protected-file hashes. Document
   untested/unsupported cases. Only then commit each dependency in its owner before
   consumers, update the distribution record and upgrade guidance, and retain
   independent application decisions. Local commits do not imply a push/deploy.

## OKAMI-108 acceptance mapping

The three original criteria and three agreed refinements are tracked separately;
this table is a verification map, not six automatically completed checkboxes.

| Requirement | Documentation / required verification |
| --- | --- |
| A1: module/dependency map and public owners | The ownership tables above; core versus compatibility aliases; explicit facade/adapter closures in the catalog. |
| A2: standalone vendoring/build and semantic/API parity without Mesa overwrite | Actual catalog executable/API results plus separately declared shared/Mesa conformance checks and protected-source hashes. Import-only or failed full-application results cannot substitute. |
| A3: provenance, compiler/platform and upgrade guidance; existing licenses | This guide/toolchain report, per-owner revisions and whole file hashes, actual notices and protected original lineage. |
| R1: rename/removal/protocol extraction | Surf rename, removed transport, HTTP/1 import migration, implemented v2/HPACK versus docs-only v3, corrected owning READMEs. |
| R2: executable consumers for every supported closure including AWS/Google | Explicit catalog selection and per-root API assertion results, with no private application dependencies; service offline fixtures remain separate. |
| R3: preserve owned history and Mesa adaptations without a new license | No application-source synchronization; current protected-file/status hashes and declared semantic boundaries, original notices/history retained. |

Use the owning issue's reviewed validation record for completion. Existing101/93
native receipts are reusable only at their exact source/scope; distribution work
must bind the actual current source it copies and executes.
