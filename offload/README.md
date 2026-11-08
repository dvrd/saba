# Bounded synchronous work

`shared:saba/offload` connects an explicitly created `shared:async/offload.Pool`
to Saba's pre-header deferred response. The core does not import this adapter.
Create lanes at startup with fixed worker and retained-job capacities. Keep the
pools, service dependencies and their thread-safe allocators alive until every
job has retired. Shut down the server before joining/destroying its lanes; joining
non-interruptible work can block and must run outside network callbacks.

`response(lane, &work, build, timeout)` returns a Response and a success flag.
Success immediately transfers Work into the continuation and clears its source;
it does not mean the pool has admitted the job. Failure preserves Work. The first
owner poll submits to the selected lane. Full/stopped/unavailable admission emits
503 and disposes the unsubmitted Work; expired admission emits 408. There is no
unbounded overflow queue, implicit thread, automatic retry or request replay.

Work inputs and results must belong to independent storage. Never capture a
Connection, Request, facade Connection view, request allocator, borrowed headers
or body in Work. Copy inputs before returning from the handler. The host owns
service data and must support concurrent calls on its configured lanes.

Build runs on the connection owner only after successful work. It receives the
job data and live request allocator. Copy every header list, header name/value
and body into that allocator before returning. Build must be bounded and
nonblocking. Do not return another deferred response or continuations borrowing
job data. The job may be freed immediately after Build returns. Failed work emits
500 without exposing its result; failed Build closes without committing a head.

Cancellation prevents delivery; it cannot undo a database mutation, provider call
or other side effect already in progress. The pool retains independent data until
a non-interruptible function returns, even when the connection and its arena have
been freed. Late notifications use an independently retained signal; the server
detaches it before freeing their former target. The adapter never stores raw
runtime/task pointers in Work.

A zero timeout inherits the server response timeout. A positive timeout is a total
pre-header budget, capped by the request's handler deadline. Expiry produces 408
and closes; peer close, shutdown and drain retire the continuation. A deadline
cannot interrupt host IO or crypto. Fixed slots remain a separate local queue bound.
Managed server scopes now also
admit retained jobs and charge declared/managed backing across operation,
connection and global ancestors. See [RESOURCES.md](../RESOURCES.md).
The original response procedure type remains intact; response_with_unmanaged_bytes
adds an explicit charge for host backing not already managed by a Binding.

The owning loopback fixture in `../testdata/offload` demonstrates two blocked job
workers/four slots with one network worker, explicit overload, late cleanup and
an optional one-worker/one-slot filesystem lane blocked in a test-owned FIFO.
See [RESULTS91.md](../RESULTS91.md) for the exact validation scope.
