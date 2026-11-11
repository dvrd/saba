# HTTP/3 server integration

Enable UDP explicitly on the ordinary Saba server. The existing handler, runtime,
worker bound, request budgets, shutdown control and drain deadline are shared:

```odin
config := saba.Server {
    handler = application_handler,
    handler_data = application,
    control = &control,
    http3 = {
        enabled = true,
        endpoint = {net.IP4_Loopback, 8443},
        credentials = credential_store,
    },
}
ok := saba.serve(config)
```

The caller owns the credential store and keeps it alive until `serve` returns.
No certificate or private key is embedded in production code. UDP endpoint and
TCP address/port are independent. With UDP port zero, query
`server_http3_endpoint(&control)` after readiness. A separate HTTP3 handler is
optional; leaving it nil uses the normal server handler and its data.

HTTP3 handlers receive method, path, query, authority as the Host header, ordinary
headers, body, request allocator/resources/cancellation, and a nonnil secure
Connection backed by the current request task. Normal routing and authentication
therefore use the same Request/Response contract. A Connection does not expose a
fake TCP socket: raw TCP writes/reads and HTTP1 upgrades are unavailable. An
upgrade response receives status501 and transferred upgrade state is disposed.

Status, ordinary headers (including repeated Set-Cookie), redirects and bodies
are preserved. Streams use the existing bounded owned-chunk exchange; transport
copies each accepted piece before releasing its source. The accepted chunk is
released before the next producer call and before producer drop. Producer waits
and deferred wake signals execute on the existing asynchronous runtime.
Shutdown and failed requests dispose continuations, queued chunks and producers
before releasing request arenas and before destroying that runtime. Drain stops
new HTTP3 admission while the common server deadline bounds admitted work.

This adapter inherits the transport's finite peer/stream/body admission limits.
It does not turn those limits into unlimited HTTP3 multiplexing or certify a
platform. The owned regression harness lives in `core/http3_test.odin`; run its
wire test with a local HTTP3-capable independent curl. The test's certificate and
key are synthetic fixtures supplied explicitly to the credential store.

`Http3_Config.qpack={table_capacity=4096,blocked_streams=4}` enables the shared
transport's dynamic QPACK table and blocked-section handling. Zero preserves
static-only compression. The transport owns instruction/feedback queues and
reference retention; application response/request ownership does not change.

`Http3_Config.client_auth` is the native TLS client-certificate policy. Nil
inherits `Server.tls.client_auth`; explicitly supply a Disabled policy to choose
a different UDP policy. `tls_peer_identity(conn)` returns the owned validated
leaf SHA256 for both TCP and HTTP3 after successful authentication. Require
never admits anonymous application work. Root certificates/policy and credential
stores remain caller-owned until serve returns. The HTTP3 handshake profile
retains at most64KiB+1024 CRYPTO bytes per encryption level and accepts fragmented
certificate/authentication flights within that limit.

`Http3_Config.ecn` opts into validated ECN marking; accessible receive metadata
is reported independently. New paths and connection IDs use Core's bounded
migration/address-validation state. Pending UDP output keeps its destination
and codepoint until the datagram is written.

`Http3_Config.tickets` borrows a native server ticket policy. A nil policy
inherits `Server.tls.tickets`; `disable_tickets=true` explicitly suppresses that
inheritance. Ticket key owners outlive the server. Issued TLS1.3 tickets travel
on reliable encrypted Application CRYPTO; issuing tickets does not enable 0-RTT.
See Core TLS `SERVER_RESUMPTION.md` for rotation, credential/policy binding and
mTLS identity preservation. Existing connection/stream/body ceilings are
unchanged by these options and remain tracked in OKAMI-392.

HTTP3 handlers receive trailing fields in `Request.trailers`, separately from
`headers`. A response's `trailers` list is emitted after its complete body or
stream producer. Allocate its list/strings with `request.allocator`; ownership
lasts until request release. Framing, routing, authentication and body metadata
cannot be redefined by trailers. Malformed peer trailers terminate only their
exchange, preserving sibling requests and WebSockets.
