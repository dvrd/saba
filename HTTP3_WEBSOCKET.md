# WebSockets over HTTP3

Enable `Http3_Config.enable_connect_protocol` to advertise RFC9220 support.
Routes use the ordinary `saba/websocket.upgrade` function and receive
`Request.version="HTTP/3"`, `method="CONNECT"`, and `protocol="websocket"`.
Existing origin/subprotocol policies and application ownership apply. Unsupported
protocols should receive 501; routes can explicitly reject them before upgrade.
HTTP1/TCP Upgrade fields do not appear in a successful 200.

The H3 layer dispatches Extended CONNECT after its initial HEADERS, without
waiting for request FIN. A successful upgrade installs explicit Upgrade_IO stream
callbacks; no TCP descriptor is fabricated or adopted. Callbacks execute serially
on the UDP listener task and never recursively pump HTTP requests. Independent
request contexts and exact drops survive close, peer reset, deadline and server
shutdown. The existing shared WebSocket codec handles all framing.

Finite receive/output queues apply backpressure to a single stream. DATA frames
can be larger than the parser buffer because their payloads are consumed
incrementally. Idle WebSockets permit ordinary requests and other WebSockets to
progress. Orderly close maps to FIN; exceptions use RESET_STREAM/STOP_SENDING with
H3_REQUEST_CANCELLED. A locally finished stream has a finite closing wait using
the existing request-timeout budget. Application/session idle and I/O timeouts
continue to govern accepted active WebSockets.

No capacity defaults are raised. Configure resource admission for the intended
number of concurrent streams; issue392 addresses general configurable capacity.
The wire fixture is tests/http3_connect.py, with native Surf/Saba and independent
aioquic1.3.0/wsproto1.2.0 peers in both directions and ASan/TSan support.
