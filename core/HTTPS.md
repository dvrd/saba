# Native HTTPS

`Server.tls == nil` retains the existing HTTP listener. Set it to a caller-owned
`TLS_Config` to serve native Core TLS 1.3 on that server's port. The listener
offers `h2` and then `http/1.1`. Negotiated ALPN `h2` maps each HTTP/2 stream
onto the existing request and response queue. Absent ALPN and `http/1.1` stay
on the HTTP/1 server. `h3` is not a token on this TCP listener:

```odin
import saba "shared:saba/core"

// Publish a validated Core credential into credential_store before serving.
// Keep the store, configuration and callback data alive until serve returns.
secure := saba.TLS_Config{store = credential_store}
saba.serve({address = "127.0.0.1", port = 8443, tls = &secure, handler = handler})
```

Load/parse certificate chains and keys with `core:crypto/tls/credentials`, create
a bounded `credentials/store.Store`, and publish with `store.replace`. Credential
errors remain typed in those owning packages. Saba rejects an absent, empty or
closed store before opening a listener. The caller owns and eventually destroys
the store. Rotation uses `store.replace`; Core leases keep previously admitted
handshakes' generations alive. Saba never logs certificates or private keys.

`application.Config.server.tls` and the historical facade's `Server.tls` pass
this same configuration to the lean server. No application-specific adapter is
required. Configuration and callback data are immutable until `serve` returns;
credential publication uses the store's thread-safe API.

## Bounds and lifetime

Zero handshake/close timeouts select 10 seconds and 1 second. Positive durations
must not exceed `MAX_SERVER_TIMEOUT`. Handshake record count defaults to 4,096
and accepts 1..65,536. Core's per-connection owned-byte cap defaults to 256 KiB
and accepts 1,024..262,144 bytes. Saba's existing hierarchical connection/global
resource limits additionally charge the TLS owner, 16 KiB plaintext staging and
Core's actual grants. Shared credential storage is owned/capped separately.

TLS handshakes run on the existing fixed worker pool using the native async
transport. Each owner has a stable address and pinned task. The handshake has a
retained monotonic deadline; HTTP header/idle budgets begin only after verified
client Finished. Each application operation retains its own phase deadline.
Moving between deferred response, write and keep-alive phases cancels/reaps an
obsolete read budget while preserving authenticated bytes in connection-owned
staging. Request arena retirement cannot invalidate an accepted TLS read.

Normal completion attempts bounded close_notify. Shutdown cancels/drains accepted
TLS operations and the raw transport, keeps driving deferred callbacks, and frees
storage only after explicit TLS close and executor quiescence. The existing drain
cutoff still limits active requests and upgrades. No blocking network thread or
per-connection thread is introduced. Cryptographic CPU work is bounded but is not
preemptible inside an individual signature operation.

## HTTP behavior and upgrades

The listener offers `h2` before `http/1.1`, accepts clients without ALPN, and
rejects incompatible ALPN offers. Exact negotiated `h2` uses `shared:http/v2`:
frame payload 16 KiB, header block/list 8 KiB, 128 fields and 4 KiB HPACK table.
`Server.http2.max_concurrent_streams` selects 1–256 concurrent protocol streams;
zero selects32, capped by the connection resource stream budget. Metadata starts
at eight slots and grows within the policy ceiling, with bounded spare slots for
closed-stream grace. Request arenas and operation contexts are allocated lazily.

Ordinary uploads, buffered responses, response producers, deferred/offload
continuations and RFC8441 WebSockets have independent lifetimes under one socket
owner. Each protocol stream has an engine lease; a response producer additionally
owns its operation-scoped exchange lease. Flow-control-blocked streams retain
bounded output and do not prevent another request from progressing. A body or
response deadline cancels only its stream; allocation rejection emits a local503
before headers or resets that stream after headers. Gzip policy remains in the
ordinary response queue. HTTP/1-style101 upgrades are rejected on ordinary H2
requests; WebSockets use negotiated Extended CONNECT and explicit stream I/O.

Connection errors close that connection. Graceful H2 shutdown sends the initial
GOAWAY, waits for the peer checkpoint, then publishes the final admitted boundary.
Peer GOAWAY retains admitted WebSockets; global server drain keeps their existing
close1001 policy. Clients negotiating HTTP/1 retain the existing TLS HTTP/1 path.
The independent loopback gates do not certify every public deployment or peer.

Upgrade continuations use `upgrade_read` and `upgrade_write`. A write buffer must
remain unchanged after Pending until its terminal return. `Upgrade_IO.socket`
is zero for secure connections so legacy raw-socket adapters fail closed. Use
its existing runtime and the transport helpers; do not adopt/close the descriptor.
The built-in reload WebSocket uses these helpers for encrypted reads and writes.

Historical synchronous `read_connection` can consume already buffered bytes but
fails closed when a secure connection would require additional I/O.
`write_connection` and synchronous send helpers fail closed on secure connections.
Return a `Response` from the handler, use streams/deferred responses, or use the
upgrade continuation interface instead. HTTP behavior is unchanged. The native
`Connection.socket` is retained for metadata/socket options; direct raw network
I/O on it bypasses the server's ownership contract and is unsupported.

## Events

`TLS_Config.on_event` receives exactly one Handshake event and one Closed event
for each initialized TLS owner. It runs on that connection's worker, outside
server locks. Events expose typed network/Core TLS failures, negotiated ALPN,
Core allocation/record statistics, deferred callback counts, write waits and
actual partial native transport writes (`transport_partial_writes`). Closed
occurs after TLS storage grants are erased/released; `stats.live_bytes` is zero.
Copy retained values/strings before returning. Observers must be bounded and
nonblocking; callback data must survive `serve`. Existing request observations
retain their independent request-level semantics. Failed configuration or owner
allocation before Core initialization has no initialized TLS-owner event.

Only the restricted Core TLS 1.3 profile is supported: AES128-GCM/SHA256,
X25519/P-256 and RSA-PSS/P-256 credentials. There is no automatic TLS 1.2 fallback,
resumption or client-certificate authentication. HTTP/2 here is the local
ALPN `h2` adapter above, not HTTP/3 and not a public interoperability claim.
