# Graceful drain

`drain_server(&control)` stops new application admission and lets already
admitted work finish. `server_ready(&control)` becomes false immediately;
`server_state` distinguishes Starting, Ready, Draining, Stopping and Stopped.
`server_endpoint` reports address publication, not readiness: admitted work can
still own that address while draining.

Set `Server.drain_timeout` to a positive duration up to 24 hours; zero selects
five seconds. An explicit second argument to `drain_server` overrides that call's
budget. The first request establishes a monotonic deadline. Repeated calls may
shorten it but never extend it. Invalid durations return false without changing
control state. Requests made before listener publication are remembered, and a
control can be reused after `serve` returns.

The call publishes intent and returns without waiting for completion. The
existing accept task closes its own listener and becomes the deadline monitor;
no monitor thread, task or per-connection stack is added. Admission reserves its
place before the cutoff under a short lock. The same accept task finishes
publishing that reservation before it monitors active work, so queued setup is
included. Allocator and logging callbacks run outside the drain lock.

At zero active connections, drain finishes early. At the deadline, the async
runtime cancels residual readers, writers and established reload WebSockets,
then joins workers and releases sockets/tasks exactly once. `stop_server` retains
its immediate-stop behavior and overrides an active drain. Internal runtime
shutdown also makes readiness false.

Handlers and observers remain cooperative. An arbitrary callback blocking a
worker cannot be preempted. With all workers blocked, even listener closure and
deadline processing wait until a worker returns; `serve` cannot join until those
callbacks finish. Keep handlers bounded or use the planned offload interface.
No claim of preemptive cancellation or HTTP/2/3/streaming support is made.

Run local lifecycle checks with a matching compiler:

```sh
python3 tests/drain_server.py --odin /path/to/odin --sanitize
```

The fixture starts and stops only its own processes. It checks admitted partial
bodies, admission attempts during drain, stalled readers, backpressured writers,
active handlers, established WebSockets, repeated/shorter deadlines, immediate
stop, pre-publication requests and control reuse with one/four workers. Unit
regressions cover invalid budgets and internal-shutdown readiness.
