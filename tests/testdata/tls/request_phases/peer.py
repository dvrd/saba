#!/usr/bin/env python3
"""Owned loopback only. Fixed synthetic requests and genuinely withheld credit."""
import argparse
import asyncio
import json
import time
import hashlib
import ssl
from aioquic.asyncio import connect, QuicConnectionProtocol
from aioquic.h3.connection import H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import StreamReset, ConnectionTerminated, StreamDataReceived


class Peer(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.http = H3Connection(self._quic)
        self.items = {}
        self.blocked = None
        self.credit_passes = 0
        self.raw_chunks = []
        original = self._quic._write_stream_limits

        def limited(builder, space, stream):
            if stream.stream_id == self.blocked:
                # Preserve the actual advertised receive limit. Other streams
                # keep aioquic's usual automatic credit and remain responsive.
                self.constrained_stream = stream
                self.credit_passes += 1
                assert stream.max_stream_data_local == 256
                return
            return original(builder, space, stream)
        self._quic._write_stream_limits = limited

    def item(self, stream):
        return self.items.setdefault(stream, dict(body=bytearray(), reset=None,
                                                 headers=False, ended=False))

    def quic_event_received(self, event):
        if isinstance(event, StreamDataReceived) and event.stream_id == 0 and len(self.raw_chunks) < 16:
            self.raw_chunks.append(len(event.data))
        if isinstance(event, StreamReset):
            self.item(event.stream_id)['reset'] = event.error_code
        if isinstance(event, ConnectionTerminated):
            self.termination = event.error_code
        for item in self.http.handle_event(event):
            record = self.item(item.stream_id)
            if isinstance(item, HeadersReceived):
                record['headers'] = True
            if isinstance(item, DataReceived):
                record['body'].extend(item.data)
                assert len(record['body']) <= 65536
            record['ended'] |= item.stream_ended

    def request(self, path, *, end=True, protocol=None):
        stream = self._quic.get_next_available_stream_id()
        headers = [(b':method', b'CONNECT' if protocol else b'POST'),
                   (b':scheme', b'https'), (b':authority', b'fixture.invalid'),
                   (b':path', path.encode())]
        if protocol:
            headers.append((b':protocol', protocol.encode()))
        self.http.send_headers(stream, headers, end_stream=end)
        self.item(stream)
        return stream

    async def until(self, predicate):
        async def poll():
            while not predicate():
                assert not getattr(self, 'termination', None)
                await asyncio.sleep(.005)
        try:
            await asyncio.wait_for(poll(), 5)
        except TimeoutError:
            print(json.dumps({'streams': {str(k): dict(bytes=len(v['body']), reset=v['reset'], headers=v['headers'], ended=v['ended']) for k,v in self.items.items()}, 'credit_passes': self.credit_passes}), flush=True)
            raise


async def exercise(port):
    config = QuicConfiguration(is_client=True, alpn_protocols=['h3'],
                               max_stream_data=256, max_data=1048576)
    config.verify_mode = ssl.CERT_NONE
    async with connect('127.0.0.1', port, configuration=config,
                       create_protocol=Peer) as peer:
        large = peer.request('/large')
        peer.blocked = large
        partial = peer._quic.get_next_available_stream_id()
        peer._quic.send_stream_data(partial, b'\x01', end_stream=False)
        peer.item(partial)
        body = peer.request('/body', end=False)
        producer = peer.request('/producer-failure')
        handler = peer.request('/handler-failure')
        healthy = peer.request('/healthy')
        peer.transmit()
        await peer.until(lambda: peer.item(healthy)['ended'])
        assert bytes(peer.item(healthy)['body']) == b'healthy'
        await peer.until(lambda: all(peer.item(s)['reset'] is not None
                                    for s in (large, partial, body, producer, handler)))
        assert all(peer.item(s)['reset'] == 0x10c for s in (large, partial, body))
        assert peer.item(producer)['reset'] == 0x102
        assert peer.item(handler)['reset'] == 0x102
        assert not peer.item(large)['ended'] and len(peer.item(large)['body']) < 65536
        constrained = peer.constrained_stream
        assert constrained.max_stream_data_local == 256
        assert constrained.receiver.highest_offset <= 256 and peer.credit_passes > 0
        after = peer.request('/healthy')
        accept = peer.request('/accept-pending', end=False, protocol='websocket')
        tunnel = peer.request('/tunnel', end=False, protocol='websocket')
        peer.transmit()
        await peer.until(lambda: peer.item(after)['ended'] and peer.item(tunnel)['headers'])
        assert bytes(peer.item(after)['body']) == b'healthy'
        await peer.until(lambda: peer.item(accept)['reset'] is not None)
        assert peer.item(accept)['reset'] == 0x10c
        await asyncio.sleep(.3)  # Deliberately cross ordinary phase budgets.
        assert peer.item(tunnel)['reset'] is None and not peer.item(tunnel)['ended']
        peer._quic.reset_stream(tunnel, 0x10c)
        peer.transmit()
        return dict(partial_header_reset=peer.item(partial)['reset'],
                    partial_body_reset=peer.item(body)['reset'],
                    producer_failure_reset=peer.item(producer)['reset'],
                    handler_failure_reset=peer.item(handler)['reset'],
                    constrained_response_reset=peer.item(large)['reset'],
                    response_credit=constrained.max_stream_data_local,
                    response_highest_offset=constrained.receiver.highest_offset,
                    credit_suppression_calls=peer.credit_passes,
                    healthy_responses=2, connect_accept_reset=peer.item(accept)['reset'],
                    tunnel_survived_ordinary_budgets=True)


async def progressive(port):
    config = QuicConfiguration(is_client=True, alpn_protocols=['h3'],
                               max_stream_data=64, max_data=1048576)
    config.verify_mode = ssl.CERT_NONE
    async with connect('127.0.0.1', port, configuration=config,
                       create_protocol=Peer) as peer:
        started = time.monotonic()
        stream = peer.request('/large')
        peer.transmit()
        await peer.until(lambda: peer.item(stream)['ended'] or peer.item(stream)['reset'] is not None)
        record = peer.item(stream)
        assert record['reset'] is None and record['ended'], dict(bytes=len(record['body']), reset=record['reset'], seconds=time.monotonic()-started)
        assert bytes(record['body']) == bytes(65536)
        assert any(5 < count < 64 for count in peer.raw_chunks)
        return dict(initial_stream_credit=64, response_bytes=len(record['body']),
                    response_sha256=hashlib.sha256(record['body']).hexdigest(),
                    complete=True, elapsed_seconds=time.monotonic()-started, first_raw_chunks=peer.raw_chunks)


async def stream_budget(port):
    config = QuicConfiguration(is_client=True, alpn_protocols=['h3'])
    config.verify_mode = ssl.CERT_NONE
    async with connect('127.0.0.1', port, configuration=config,
                       create_protocol=Peer) as peer:
        started = time.monotonic()
        stream = peer.request('/stream-budget')
        peer.transmit()
        await peer.until(lambda: peer.item(stream)['ended'] or peer.item(stream)['reset'] is not None)
        record = peer.item(stream)
        elapsed = time.monotonic()-started
        assert record['reset'] is None and record['ended']
        assert bytes(record['body']) == b'stream-ok' and elapsed >= .55
        return dict(ordinary_response_budget_ms=400, stream_budget_ms=1500,
                    producer_delay_ms=600, response_bytes=len(record['body']),
                    elapsed_seconds=elapsed, complete=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, required=True)
    parser.add_argument('--profile', choices=('isolation', 'progress', 'stream-budget'), required=True)
    args = parser.parse_args()
    assert 0 < args.port < 65536
    selected = {'isolation': exercise, 'progress': progressive, 'stream-budget': stream_budget}[args.profile]
    print(json.dumps(asyncio.run(selected(args.port)), sort_keys=True))
