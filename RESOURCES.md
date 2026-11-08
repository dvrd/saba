# Separate serving resource budgets

The server admits variable retained backing, streaming exchanges and blocking jobs
through `core:sync/budget`. Connection/task/socket metadata capacity still has its
own initial/maximum/growth policy. Increasing metadata capacity cannot raise any
resource limit. Counters describe requested managed backing, not RSS, kernel socket
buffers, allocator-internal rounding or arbitrary host caches.

| Limit | Operation | Connection | Server |
| --- | ---: | ---: | ---: |
| Managed backing bytes | 32 MiB | 64 MiB | 256 MiB |
| Active streaming exchanges | 1 | 1 | 128 |
| Retained blocking jobs | 1 | 4 | 128 |

`Server.resources` is `Resource_Config`. Nil `operation_limits`, `connection_limits`
and `global_limits` select these finite defaults; an explicit `budget.Limits{}`
admits nothing. The primitive kernel itself has no implicit defaults. An optional
caller-owned `parent` Scope joins servers, Surf requests and job lanes under one
application-wide ceiling. The server creates/retains its own child and never closes
the caller's parent when stopping. Keep the parent alive through server startup;
its children and leases then keep the hierarchy alive independently.

`server_resources(control)` returns the server Scope snapshot: configured limits,
current/peak usage, combined jobs plus queued/running/held breakdown and rejection
count. `retain_server_resources` returns an owner for snapshots after serve ends;
release that Scope explicitly. For per-operation and per-connection snapshots,
use `budget.snapshot(request.resources)` and
`budget.snapshot(request_connection_resources(request.cancellation))`. The latter
borrows the real connection ancestor through the retained operation, never a raw
connection pointer. Its Scope closes when the connection retires while retained
contexts/leases keep safe snapshots and physical backing accounting alive.
`server_capacity` reports metadata separately.
Scope-node count/metadata bytes are control metadata, rather than payload allowance.
Charged allocator Binding metadata has its own allocator statistics; these counters
do not claim all process/control memory is included in the byte allowance.

Each connection and operation has a standalone retained scope. Operation storage
starts before header/body allocation and is replaced on keep-alive. Header growth,
parsed tables, body capacity, response copies/encoded heads and deferred pipeline
backing use charged Dynamic_Arena block and pointer-table allocators. Even one
received upload byte can retain the full admitted Content-Length backing. The
fixed initial header buffer and emergency response buffer are task metadata.
Unknown ordinary response borrows are copied into managed owner storage before
suspension; HEAD retains no unsent host body and preserves its representation
length while encoding headers; applications should account for the real overlap of those copies.
Host-owned preloaded caches retain their separate host ownership and limits.

A refused allocation produces a fixed-storage503+close before a head is committed;
no successful allocation is needed to emit that rejection. Known408 timeout and
413 body-policy statuses keep their status through the same fixed-buffer encoder.
A deferred Build copy failure under byte pressure also emits503 before any head. Existing request body
policy still rejects oversized declared bodies with413. Once a streaming head is
sent, failure closes the stream without a false successful completion. There is
no unbounded waiter queue, implicit retry or automatic replay. Credits recover
only when backing is physically freed or its admitted resource retires.

## Streaming ownership

Only streaming HTTP exchanges consume the server stream allowance; ordinary
buffered HTTP/1 responses consume bytes/jobs as applicable. HTTP Exchange owns the
single stream lease from initialization through complete/cancel/destroy terminal
cleanup. Producer drop is bounded cleanup after chunk release, outside locks; its
physical managed backing remains byte-charged until actual free even after the
exchange becomes terminal. A second Saba stream lease is never acquired.

`Stream_IO.resources` and `backing_allocator` are borrowed during next. Allocate
individually owned chunks with that backing allocator to make provenance explicit.
`stream_submit` keeps its original two-argument procedure type. The additive
`stream_submit_backing(io, &chunk, Backing)` identifies custom backing:

- `{allocator = backing_allocator}` identifies an entire managed allocation.
  Allocation base/size and current scope must be valid. Reusable file buffers use
  this path, so exchange release does not refund backing still held by the producer.
- `{allocator_scope = io.resources}` is a trusted annotation for storage already
  covered by that scope, such as a managed request arena. Actual blocks and tables
  must already be charged, and the caller must preserve the arena lifetime. The
  annotation is not proof from an arbitrary raw pointer or an owner lifetime token.
- `{release_frees_storage = true}` asserts a custom callback physically frees the
  entire uncharged backing. Return-to-pool callbacks do not satisfy this assertion.
- Unknown custom backing is rejected by a managed exchange with source ownership
  preserved. Normal allocator-owned chunks carry their allocator automatically.

Same-root managed transfers rebind exclusive ancestor charges without charging
shared ancestors twice. Foreign/incompatible provenance rejects without taking
the source. Backing provenance modes are mutually exclusive. File streaming wraps
explicit plain host allocators in an owned charged Binding; configured managed
allocators must already cover the operation. Backing allocators must accommodate
the known accounting header/alignment in addition to the configured payload chunk.

## Offload and late work

Request and Deferred_IO expose borrowed `resources` and an individually-free
`backing_allocator`, separately from the ephemeral request arena allocator. Retain
an independent Scope or owned charged Binding before publishing work. A retained
Request_Context keeps its resource Scope; `request_resources(ctx)` is borrowed
while that context lives. Never retain raw request/task/runtime/connection pointers.

`shared:saba/offload.response` preserves its original procedure type and passes
the operation Scope to `pool.submit_scoped`. Jobs are charged once through queued,
running and held phases; a phase change needs no new admission. Managed input and
result allocations carry their own charge. For explicitly uncharged host-owned
input, `response_with_unmanaged_bytes` declares the full retained backing charge;
zero is not an automatic inference of transitive host memory. Do not declare bytes
already charged by a managed allocator. Host callbacks must use the managed job
allocator or explicitly declare unmanaged storage to obtain budget coverage.

Cancellation/Scope closure prevents new growth but cannot refund live allocations,
interrupt host IO/crypto, roll back a mutation or replay a request. Existing bytes
and job tickets remain charged after arena/runtime retirement until late work and
its cleanup actually finish. Closed scopes still permit refunds and phase changes.
Allocator views cannot be used after their owners/last allocations retire; retain
an owned Binding for independent calls.

## Source migration

Handler procedure types and legacy `stream_submit`/offload `response` procedure
values are preserved. New scoped/backing entry points have separate names so
existing callback tables continue compiling. Server, Request, IO and internal
connection layouts gained resource fields; use named aggregates and the matching
package types rather than positional literals or layout casts. The facade forwards
the same resource configuration and aliases the new helpers/constants.

The owned `tests/resources.py` gate checks independent operation/connection
allowances with ample global headroom, then combines partial uploads, slow readers,
streaming and blocked work under one global Scope. It samples outside HTTP, checks
metadata growth independently, retires the real server before releasing late jobs,
and requires zero final byte/stream/job usage and tracked job backing. This is
functional/lifetime evidence, not a throughput or total-process-memory claim.
