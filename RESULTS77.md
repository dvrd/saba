# OKAMI-77 — bounded streamed responses and SSE

Implemented 2026-11-07 in shared HTTP and Saba. HTTP adds an explicit streamed
head encoder; the old buffered callable/profile remains unchanged. Saba adds
`Response.stream`, one serial producer callback and one shared exchange/owned
chunk slot. Successful acceptance clears the source owner; rejection preserves
it. Each accepted grant survives all partial writes and releases before the next
poll and producer drop. Headers are snapshotted, lengths enforced, and unknown
length output gets a final chunk only after successful production completion.
HEAD/body-forbidden statuses skip producer polling and dispose ownership.

Core/facade asynchronous serving supports streams alongside existing buffered
responses and upgrades. Timer waits and total lifetime are bounded; each write
has a separate slow-reader budget. Request deadlines shorten stream lifetime.
Errors, cancellation and shutdown dispose chunks and producer exactly once.
The real `examples/sse` server emits finite UTF-8 events/comment heartbeats,
suspends through runtime timers, supports HEAD and cleans up on stop. It adds no
per-stream threads. APIs, limits, ownership and reproduction are in README.md.

Validation: Darwin arm64, Odin dev-2026-11:c826157de.

- HTTP/1: 16 ASan tests pass, including streamed fixed/unknown head framing,
  HEAD/204/304, reserved fields and exact destination bounds; old profile remains
  opt-in safe. Shared exchange: 11 ASan tests pass.
- Saba core: 31 ASan tests pass; facade: 9 ASan tests pass. Stream unit cases
  cover whole-grant admission, source clearing/backpressure preservation, release
  before next poll/drop, protocol/head rejection, unsupported blocking helper,
  request-deadline inheritance and unarmed wait rejection.
- `tests/streaming.py --sanitize address`: 9 owned wire groups pass with one
  worker. `--sanitize thread --workers 4`: same matrix passes. Independent Python
  HTTP decoding, raw chunk framing/final terminator, pipelining, HEAD/no-body,
  known empty output, 8 MiB from owned 16 KiB grants, producer/length/admission/
  wait/head errors, timers, slow readers, disconnect and shutdown are covered.
  Each fixture producer asserts no poll before release, checks whole-storage
  releases, and verifies all allocated owners released before producer drop.
- The harness builds/runs the actual SSE example, checks four events/four
  heartbeats and HEAD, and stops it while a stream is active.
- Existing async_server.py (one/four workers), keep_alive.py, chunked_requests.py
  (ASan) and cancellation.py (ASan) pass.
- Isolated empty executable plus HTTP/1, Saba and Auth consumers build/run pass
  (`/tmp/webtools-stream-consumers.json`).

The initial four-worker TSan run identified fixture statistics passed to fmt
without materializing private snapshot storage. The fixture now copies atomic
counter values into a local array before formatting; the final matrix is clean.
No stream-engine race was reported by that run. These are functional/race tests,
not a throughput, p99 or RSS result.

Reproduction from the Odin root:

```
./odin test shared/http/v1 -warnings-as-errors -sanitize:address -out:/tmp/http-stream-tests
./odin test shared/http/exchange/tests -warnings-as-errors -sanitize:address -out:/tmp/exchange-tests
./odin test shared/saba/core -warnings-as-errors -sanitize:address -out:/tmp/stream-tests
python3 shared/saba/tests/streaming.py --odin ./odin --sanitize address
python3 shared/saba/tests/streaming.py --odin ./odin --sanitize thread --workers 4
python3 ci/webtools_consumer_gate.py --odin ./odin --packages http/v1 saba auth --report /tmp/stream-consumers.json
```

The request arena remains alive while streaming; producer/rejected-owner memory
and kernel buffers are outside the one-slot backing cap. Host jobs still need
bounded offload and independently owned inputs/results. No response trailers,
range/file adapter, global byte admission, event replay, Mesa update, browser
reconnection matrix or non-Darwin runtime certification is claimed.
