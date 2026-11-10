# Application WebSocket sessions

Import `shared:saba/websocket` (package `saba_websocket`) from an explicit Saba
route. The adapter uses `shared:websocket` for upgrade, frame, message, masking,
close-code and UTF-8 validation. It adds a resumable application lifecycle on the
existing Saba connection task; it creates no thread, socket owner or mailbox.
Both HTTP and native HTTPS use `core.upgrade_read` / `core.upgrade_write`.

```odin
response, error := sockets.upgrade(request, config, application)
if error.kind != .None {
    // The caller still owns application.data on rejection.
    destroy_application(application.data)
}
return response
```

The returned ordinary HTTP response carries the error's status on rejection.
The application chooses the route and performs authentication before calling
`upgrade`. The factory requires a bodyless HTTP/1.1 GET, valid Host and WebSocket
fields, and a real Saba request connection resource context. Repeated singleton
fields and malformed/duplicate subprotocol offers are rejected. Unsupported
extensions are not negotiated; frames with RSV bits set are rejected.

## Policy hooks

`Config.check_origin` receives the call-scoped request, Origin value and a
presence flag. Without a hook, requests without Origin are accepted and requests
with Origin are rejected. An explicit hook owns the application's origin policy;
syntax validation precedes it. `select_subprotocol` receives bounded validated
offers and returns a selection plus an acceptance flag. False rejects the
upgrade. A nonempty selection must exactly match an offered token. Nil selects
no protocol. Hook data and borrowed request fields are never retained.

The selected protocol is copied into session-owned storage. `subprotocol(io)`
borrows that copy during a callback. No request header or arena storage remains
borrowed after the HTTP upgrade completes.

## Application ownership

Application has `data`, optional `on_open`, `on_message`, `on_writable`, `on_close`,
and `drop` callbacks. Ownership transfers only when `upgrade` succeeds. Dispose
an unused successful response with `core.discard_response`; its application still
closes/drops exactly once, including when the 101 write fails.

on_open, on_message and on_writable are serial on the existing task and must be
bounded and nonblocking.
IO and incoming payload slices borrow only until callback return. Do not retain
IO, call it from another thread, adopt/close a socket, or retain an incoming slice
without making an independently owned copy. Application data must survive until
drop and must not borrow the HTTP request arena.

`on_open` runs only after the complete 101 response is written. `on_message`
receives complete Text/Binary messages after fragmentation and UTF-8 validation.
Ping/Pong/Close are handled by the adapter and do not enter message assembly.
`on_close` runs after transport quiescence and session storage cleanup, without
an IO capability; it receives a value snapshot. Application.drop follows once.
These terminal notifications can also run during ordinary response disposal,
including outside a current task when an upgrade never opens. They must not
assume task affinity or perform I/O.
A session that never opened reports Not_Opened; an otherwise unclassified owner
termination can report Shutdown using retained server cancellation metadata.
No retained cancellation context owns the old request arena or Runtime.

## Sending and backpressure

`send(io, opcode, payload)` accepts Text or Binary and copies bytes before
returning Accepted. The caller can immediately reuse or destroy its input.
Messages are automatically fragmented at `max_frame_bytes`; frame bytes remain
stable through partial writes. Accepted means local queue ownership, not peer
receipt or acknowledgment.

The output queue has independent message-count and retained-payload byte limits.
A message larger than the message or output limit returns Limit_Exceeded.
Temporary capacity exhaustion returns Backpressure and requests one
`on_writable` callback after an actual output credit transition. The wanted flag
is cleared before that callback; a retry that still cannot fit can request a
later transition. Applications retain their own bounded pending data for retry;
the adapter does not retain a rejected payload. There is no cross-thread send API.

Automatic Pong and Close have reserved fixed storage and can progress while the
application queue is full. They take priority at frame boundaries, never inside
a partially written frame. Only one control reply is pending; input backpressure
prevents overwriting it.

## Limits and close

Zero config fields select these finite defaults:

- 64 KiB frame payload, 1 MiB assembled message, 1 MiB queued output payload.
- Four queued messages and 1,024 fragments per incoming message.
- 60-second idle wait, five-second total frame read, 30-second fragmented message,
  five-second total message write, and one-second close budget.

Size limits may be configured up to 64 MiB; output capacity up to 1,024 and
fragment count up to 65,536. Durations must be positive after normalization and
no larger than 24 hours. Frame/message bounds limit payload; actual dynamic-array
capacity, bounded frame workspace, fixed controls and queue metadata are
separately charged to the connection's resource hierarchy. A tight parent budget
can reject allocations below a configured payload ceiling. No allocation falls
back to an unbounded heap when admission fails.

Input is serviced while output is blocked. An independent earliest-deadline
watchdog covers frame, message, control, output and close budgets even when a
reserved control response prevents another read. An inbound cutoff can retire
an unfinished outbound frame uncleanly; it does not wait for the longer write
budget or splice a Close frame into that frame. Plain TCP restores both pending
read/write interests after attempting them; TLS retains its existing driver.

Read and write progress never extend their phase deadlines. The fragmented
message deadline and fragment count also bound empty continuation sequences.
Each resume performs bounded steps and yields back to Saba's fixed worker pool.
Callbacks and bounded message validation/copies are synchronous CPU work; they
are not preemptible.

`close(io, code, reason)` validates code and UTF-8, prevents new sends and starts
one finite cutoff. Application close drains already accepted messages within
that cutoff before sending Close. Peer, protocol and shutdown termination
prioritize Close after any active frame and discard unsent application data.
Expiry may terminate a peer that cannot drain or complete the close handshake.
Core's drain/stop remains authoritative. Never infer delivery from a queue drop.

`Close_Event.clean` is true only after both Close frames were exchanged without
protocol or transport failure. An empty valid peer Close has peer_code zero;
clean distinguishes that case from missing closure. An incomplete close cutoff
records a typed Timeout while preserving the initiating reason.

`Close_Event` preserves the first meaningful close reason and peer code plus
available transport/frame/message diagnostics. A generic owner termination is
reported without inventing a specific network error. Its final stats have zero
queued bytes/messages. `stats(io)` provides callback-local queue and message
counters; no global observer or cross-thread snapshot owner is introduced.

The session and all later payload storage use a connection-scoped managed
allocator, independently of the request operation scope. Cleanup releases
message assembly, queue payloads, frame workspace, selected protocol, cancellation
references and allocator ownership after the last I/O borrow. Existing development
reload continues to use its original control-only adapter; this package does not
change its routes or policy.
