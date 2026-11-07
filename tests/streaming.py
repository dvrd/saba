#!/usr/bin/env python3
"""Owned streaming wire/ownership, timer, slow-reader and SSE example tests."""
import argparse
import contextlib
import hashlib
import http.client
import json
import os
from pathlib import Path
import queue
import socket
import subprocess
import tempfile
import threading
import time
from keep_alive import request, response, exact
from async_server import headers


class Server:
    def __init__(self, binary, example=False, workers=1):
        self.example = example; self.lines = []; self.finished = False
        env=os.environ.copy();env["SABA_STREAM_WORKERS"]=str(workers)
        self.proc = subprocess.Popen([str(binary)], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True)
        self.pending = queue.Queue()
        def read():
            for raw in self.proc.stdout:
                line = raw.strip(); self.lines.append(line); self.pending.put(line)
        self.reader = threading.Thread(target=read, daemon=True); self.reader.start()
        ready = self.pending.get(timeout=8); assert ready.startswith('ready '), ready
        self.port = int(ready.split()[1])
    def connect(self):
        return socket.create_connection(('127.0.0.1', self.port), timeout=5)
    def fast(self, path='/fast'):
        with self.connect() as conn:
            conn.sendall(request(path)); return response(conn)
    def idle(self):
        until = time.monotonic()+3
        while True:
            values = list(map(int, self.fast('/stats')[2].split()))
            active, live, allocated, released, drops = values
            if active == live == 0:
                assert allocated == released, values
                return values
            assert time.monotonic() < until, values
            time.sleep(.005)
    def stop(self):
        if self.finished:
            return
        self.proc.stdin.write('s'); self.proc.stdin.flush()
        self.proc.wait(timeout=8); self.reader.join(timeout=2); self.finished = True
        error = self.proc.stderr.read()
        assert self.proc.returncode == 0, error
        assert 'ERROR: AddressSanitizer' not in error and 'WARNING: ThreadSanitizer' not in error, error
        stopped = next(line for line in self.lines if line.startswith('stopped'))
        if not self.example:
            _, drops, allocated, released = stopped.split()
            assert allocated == released
            records = [line.split() for line in self.lines if line.startswith('drop ')]
            assert len(records) == int(drops) and len({row[1] for row in records}) == int(drops)
            assert all(row[3] == row[4] for row in records), records
    def __enter__(self):
        return self
    def __exit__(self, kind, value, trace):
        try:
            if kind is None:
                self.stop()
        finally:
            if self.proc.poll() is None:
                self.proc.kill(); self.proc.wait(timeout=5)
            for pipe in [self.proc.stdin, self.proc.stdout, self.proc.stderr]:
                pipe.close()


def until_closed(conn):
    result = bytearray()
    while True:
        try:
            chunk = conn.recv(65536)
        except ConnectionResetError:
            break
        if not chunk:
            break
        result.extend(chunk)
        assert len(result) < 1024*1024
    return bytes(result)


def read_chunk(conn):
    line = bytearray()
    while not line.endswith(b'\r\n'):
        line.extend(exact(conn, 1)); assert len(line) < 32
    size = int(line[:-2], 16)
    if size == 0:
        assert exact(conn, 2) == b'\r\n'
        return None
    payload = exact(conn, size); assert exact(conn, 2) == b'\r\n'
    return payload


def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--odin', required=True)
    parser.add_argument('--sanitize', choices=['address', 'thread'])
    parser.add_argument('--workers',type=int,choices=[1,4],default=1);args = parser.parse_args()
    saba = Path(__file__).resolve().parents[1]; checks = []
    with tempfile.TemporaryDirectory(prefix='saba-streaming-') as work:
        binary = Path(work)/'server'; example = Path(work)/'sse'
        for source, output in [(saba/'testdata/stream', binary), (saba/'examples/sse', example)]:
            command = [args.odin, 'build', str(source), '-warnings-as-errors', '-out:'+str(output)]
            if args.sanitize:
                command.append('-sanitize:'+args.sanitize)
            subprocess.run(command, check=True, timeout=60)
        with Server(binary,workers=args.workers) as instance:
            expected = bytes(i % 251 for i in range(6144))
            for path in ['/known', '/chunked']:
                with contextlib.closing(http.client.HTTPConnection('127.0.0.1', instance.port, timeout=4)) as conn:
                    conn.request('GET', path); reply = conn.getresponse()
                    assert reply.status == 200 and reply.read() == expected
                    assert reply.getheader('Content-Length') == ('6144' if path == '/known' else None)
                    assert reply.getheader('Transfer-Encoding') == (None if path == '/known' else 'chunked')
                    conn.request('GET', '/fast'); reply = conn.getresponse()
                    assert reply.read() == b'ok'
            instance.idle(); checks.append('independent HTTP client reads fixed/chunked streams and reuses the connection')
            with instance.connect() as conn:
                conn.sendall(request('/chunked')+request('/fast'))
                head = headers(conn); assert b'Transfer-Encoding: chunked\r\n' in head
                chunks = []
                while (chunk := read_chunk(conn)) is not None:
                    chunks.append(chunk)
                assert len(chunks) == 3 and b''.join(chunks) == expected
                assert response(conn)[2] == b'ok'
            checks.append('exact chunk framing/final terminator and serialized pipelined next request')
            before = len([line for line in instance.lines if line.startswith('drop ')])
            for method, path in [('HEAD', '/known'), ('HEAD', '/chunked'), ('GET', '/nobody'), ('GET', '/empty')]:
                with contextlib.closing(http.client.HTTPConnection('127.0.0.1', instance.port, timeout=4)) as conn:
                    conn.request(method, path); reply = conn.getresponse(); assert reply.read() == b''
                    if method == 'HEAD':
                        assert reply.getheader('Transfer-Encoding') is None
                        assert reply.getheader('Content-Length') == ('6144' if path == '/known' else None)
            instance.idle()
            last = [line.split() for line in instance.lines if line.startswith('drop ')][before:]
            assert len(last) == 4 and all(int(row[2]) == 0 for row in last[:3]), last
            checks.append('HEAD/body-forbidden responses never poll producer; known empty representation completes')
            digest = hashlib.sha256()
            for at in range(0, 8*1024*1024, 65536):
                digest.update(bytes((at+i) % 251 for i in range(65536)))
            with contextlib.closing(http.client.HTTPConnection('127.0.0.1', instance.port, timeout=5)) as conn:
                conn.request('GET', '/large'); reply = conn.getresponse(); actual = hashlib.sha256(); count = 0
                while (data := reply.read(32768)):
                    actual.update(data); count += len(data); time.sleep(.0005)
                assert count == 8*1024*1024 and actual.digest() == digest.digest()
            instance.idle(); checks.append('8 MiB response uses sequential owned 16 KiB chunks with exact content after partial writes')
            for path in ['/error', '/short', '/long', '/overlimit', '/backpressure', '/badwait']:
                with instance.connect() as conn:
                    conn.sendall(request(path)); head = headers(conn); assert head.startswith(b'HTTP/1.1 200 ')
                    partial = until_closed(conn)
                    if path in ['/error', '/overlimit']:
                        assert partial == b'3\r\n\x00\x01\x02\r\n', (path, partial)
                    elif path == '/short':
                        assert partial == b'\x00\x01\x02'
                    else:
                        assert partial == b'', (path, partial)
                instance.idle()
            for path in ['/badhead', '/mix']:
                with instance.connect() as conn:
                    conn.sendall(request(path)); assert until_closed(conn) == b''
                instance.idle()
            checks.append('producer/length/admission/wait/metadata failures close without false completion and release all owners')
            with instance.connect() as conn:
                conn.sendall(request('/wait')); headers(conn)
                started = time.monotonic(); assert instance.fast()[2] == b'ok'
                assert time.monotonic()-started < .5
                chunks = []
                while (chunk := read_chunk(conn)) is not None:
                    chunks.append(chunk)
                assert b''.join(chunks) == bytes(range(12))
            with instance.connect() as conn:
                conn.sendall(request('/stall')); headers(conn)
                started = time.monotonic(); assert until_closed(conn) == b''
                assert time.monotonic()-started < 1
            instance.idle(); checks.append('timer-suspended producers free the sole worker; waits clamp to the total stream deadline')
            slow = instance.connect(); slow.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
            slow.sendall(request('/slow')); headers(slow)
            assert instance.fast()[2] == b'ok'
            instance.idle(); slow.close()
            checks.append('non-reading consumer reaches write timeout and releases pending chunk/producer while cheap routes progress')
            peer = instance.connect(); peer.sendall(request('/slow')); headers(peer); peer.close(); instance.idle()
            held = instance.connect(); held.sendall(request('/wait')); headers(held)
            blocked = instance.connect(); blocked.sendall(request('/slow')); headers(blocked)
            instance.stop(); held.close(); blocked.close()
            checks.append('disconnect and shutdown destroy every accepted chunk, rejected owner and producer exactly once')
        with Server(example, example=True) as instance:
            with contextlib.closing(http.client.HTTPConnection('127.0.0.1', instance.port, timeout=5)) as conn:
                conn.request('GET', '/events'); reply = conn.getresponse(); body = reply.read()
                assert reply.getheader('Content-Type') == 'text/event-stream'
                assert body.count(b'event: tick\n') == 4 and body.count(b': heartbeat\n\n') == 4, body
                assert reply.getheader('Transfer-Encoding') == 'chunked'
            with contextlib.closing(http.client.HTTPConnection('127.0.0.1', instance.port, timeout=3)) as conn:
                conn.request('HEAD', '/events'); reply = conn.getresponse(); assert reply.read() == b''
            with instance.connect() as held:
                held.sendall(request('/events'));headers(held);assert read_chunk(held)
                instance.stop();until_closed(held)
        checks.append('actual SSE example emits bounded events/heartbeats through timer waits and supports HEAD')
    print(json.dumps({'valid': True, 'sanitizer': args.sanitize or 'none', 'workers':args.workers, 'checks': checks}, indent=2))


if __name__ == '__main__':
    main()
