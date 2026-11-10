# Native HTTPS

`Server.tls == nil` retains the existing HTTP listener. Set it to a caller-owned
`TLS_Config` to serve HTTP/1.1 over native Core TLS 1.3 on that server's port:

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

The listener advertises only `http/1.1`, accepts clients without ALPN, and rejects
incompatible ALPN offers. HTTP/2 serving remains separate work. Routing, chunked
requests, streams, deferred responses, assets, pages and development reload all
use the same plaintext transport operations after TLS authentication.

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
resumption, client-certificate authentication or HTTP/2 serving claim.
