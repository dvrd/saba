# HTTP/2 Extended CONNECT and WebSockets

Saba's existing HTTPS listener advertises RFC8441
`SETTINGS_ENABLE_CONNECT_PROTOCOL=1` when it negotiates `h2`. Normal handlers see
CONNECT, `Request.version="HTTP/2"`, and the explicit `Request.protocol` value.
The existing `saba/websocket.upgrade` accepts `protocol="websocket"` and uses the
same origin/subprotocol policy, callbacks, framing, owned queues and close logic
as HTTP1 WebSockets. HTTP2 success is status200 with no HTTP1 Upgrade or
Sec-WebSocket-Key/Accept exchange.

Register a CONNECT route as well as the existing GET route if the application
router matches methods. Do not create an outbound TCP connection to the request
`:authority`; Extended CONNECT targets the registered application protocol.

The normal server runtime drives each upgraded stream serially on its existing
connection task. Each stream owns its request arena, cancellation context and
Upgrade state. Its `Upgrade_IO` uses explicit stream read/write/wait callbacks;
there is no fake TCP descriptor or independent hidden runtime. Raw native
connection I/O is unavailable on that stream. `tls_peer_identity` returns the
validated peer-identity snapshot for mutual-TLS streams.

Configure enough **connection stream budget** to multiplex an idle WebSocket
with ordinary HTTP requests. For example:

```odin
config.resources.connection_limits = budget.Limits{64*mem.Megabyte, 8, 8}
```

The legacy connection default is one stream. Admission is capped by that budget,
the HTTP2 engine allowance (eight), and four upgraded contexts. One buffered
ordinary exchange can progress alongside admitted WebSockets; a producer cannot
block the connection task or retain `Upgrade_IO` beyond callback return. Timers
and native readiness remain owned by that task. Explicit capacity is not a
promise of unlimited ordinary-request or WebSocket concurrency.

DATA transfers use bounded owned chunks and return flow credit on consumption.
Empty/padding-only DATA is not EOF. END_STREAM maps to a half-close and reset to
stream cancellation. Shutdown/drop releases input owners, application state,
request cancellation and arena before the underlying connection/runtime retires.
The existing HTTP1 GET/101 path remains supported.

Reproduce the owned wire gate from shared with a matching Core/compiler:

```sh
ODIN_ROOT=/absolute/matching/Odin \
python3 saba/tests/http2_connect.py --odin /absolute/matching/odin \
  --sanitize address --mutual-tls --report /tmp/http2-websocket.json
```

Use `--sanitize thread` for the race gate. The script uses only loopback and a
Go standard-library peer, with explicit synthetic identities. Coverage includes
SETTINGS permission, CONNECT200, origin/subprotocol, two concurrent WebSockets,
ordinary requests while idle,128KiB incremental echo across transport-window and
queue caps, empty/padding DATA, ping/pong, close, stream-local reset, exact-once
application drops and generation-rotated mTLS identities. No public service is
contacted.
