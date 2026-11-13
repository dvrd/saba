# OKAMI-420 Saba consumer candidate

Adds opt-in Http3_Phase_Config using resolved Server.timeouts and explicit
CONNECT acceptance/closing durations. Zero/unset remains off. Defaults and
explicit body overrides preserve the existing4096-byte large-body threshold;
QUIC idle, handshake and native request_timeout remain independent. Invalid
CONNECT configuration fails before binding. The public facade exports the
config and forwards it unchanged.

Response_Stream.timeout retains its documented total lifetime: Saba forwards
validated remaining monotonic stream.expires at Ready, including a shorter
inherited request deadline. It never restarts60s SSE as a new ordinary10s budget.
The HTTP4b619c7 dependency isolates explicit handler/producer failure and verifies
Core reset/STOP errors, preserving healthy sibling streams when Saba's precise
producer/deferred deadline precedes the native millisecond check.

25 H3 core cases and4 facade cases pass under both ASan and TSan. The public
facade owned-wire ASan harness reuses HTTP's maintained independent peer. All
three profiles pass: fixed400ms withheld credit with two healthy siblings and
producer/deferred reset258, initial64B auto-credit exact64KiB completion under
separate3s response budget/unchanged5s peer wait, and a600ms producer completing
under its explicit1.5s lifetime beyond ordinary400ms response timing. Isolation
records exactly7 route calls/4 producer-deferred-upgrade drops; the lifetime
profile records one route/one drop. Deterministic tests additionally cover
60s-vs10s remaining budget, inherited2s, precise-expiry and deferred drop-once.

Source/commands/logs and exact physical HTTP dependency binding are retained in
[tests/evidence/http3-phases-20261113/receipt.json](tests/evidence/http3-phases-20261113/receipt.json).
The disposable test closure copies dependencies solely to resolve relative
imports consistently; no canonical source or application manifest is changed.

Mesa application adoption is separate. Its safe explicit policy should use
existing5s header/30s body/10s response and CONNECT accept10s/close1s while
preserving SSE60s. No missing H3 listener, endpoint or certificate is enabled
implicitly. No business/provider startup, pushes, deployment, new native Linux
qualification or throughput SLO is claimed.393 remains open.
