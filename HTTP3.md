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
