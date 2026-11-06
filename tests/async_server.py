#!/usr/bin/env python3
"""Exercise the public Saba interface over owned loopback sockets."""
import argparse
import concurrent.futures
import contextlib
import json
import os
from pathlib import Path
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time

SABA = Path(__file__).resolve().parents[1]
CHECKS = []
OBSERVATIONS = []


def exact(conn, count):
    result = bytearray()
    while len(result) < count:
        part = conn.recv(count - len(result))
        assert part, 'unexpected EOF'
        result.extend(part)
    return bytes(result)


def headers(conn):
    result = bytearray()
    while not result.endswith(b'\r\n\r\n'):
        result.extend(exact(conn, 1))
        assert len(result) <= 8192
    return bytes(result)


def response(conn):
    head = headers(conn)
    status = int(head.split(b' ', 2)[1])
    length = next((int(line.split(b':', 1)[1]) for line in head.split(b'\r\n')
                   if line.lower().startswith(b'content-length:')), 0)
    body = exact(conn, length)
    return status, head, body


def frame(opcode, payload=b'', masked=True):
    assert len(payload) <= 125
    mask = b'\x01\x03\x05\x07'
    if not masked:
        return bytes([0x80 | opcode, len(payload)]) + payload
    return bytes([0x80 | opcode, 0x80 | len(payload)]) + mask + bytes(
        b ^ mask[i % 4] for i, b in enumerate(payload))


def received_frame(conn):
    head = exact(conn, 2)
    assert head[0] & 0x80 and not head[1] & 0x80
    return head[0] & 15, exact(conn, head[1] & 127)


class Server:
    def __init__(self, binary, web, workers=1, capacity=64, development=False):
        env = os.environ.copy()
        env.update(SABA_TEST_WEB=str(web), SABA_TEST_WORKERS=str(workers),
                   SABA_TEST_CAPACITY=str(capacity), SABA_TEST_DEVELOPMENT=str(int(development)))
        self.on_stopped = None
        self.proc = subprocess.Popen([str(binary)], env=env, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     start_new_session=True)
        deadline = time.monotonic() + 8
        try:
            while time.monotonic() < deadline:
                assert self.proc.poll() is None, 'server exited during startup'
                if select.select([self.proc.stdout], [], [], .1)[0]:
                    line = self.proc.stdout.readline().decode()
                    if line.startswith('ready '):
                        self.port = int(line.split()[1])
                        return
            raise AssertionError('server readiness timeout')
        except BaseException:
            self.close(force=True)
            raise

    def connect(self):
        return socket.create_connection(('127.0.0.1', self.port), timeout=8)

    def request(self, path='/ok', body=b'', fragments=False, extra=b''):
        wire = (b'POST ' if body else b'GET ') + path.encode() + b' HTTP/1.1\r\nHost: localhost\r\n'
        wire += b'Content-Length: ' + str(len(body)).encode() + b'\r\n' + extra + b'\r\n' + body
        with self.connect() as conn:
            if fragments:
                for at in range(0, len(wire), 31):
                    conn.sendall(wire[at:at+31])
            else:
                conn.sendall(wire)
            reply = response(conn)
            try:
                assert conn.recv(1) == b'', 'ordinary responses must close the connection'
            except ConnectionResetError:
                assert reply[0] == 503, 'only best-effort rejection may reset after its response'
            return reply

    def websocket(self, following=b'', extra=b''):
        conn = self.connect()
        conn.sendall(b'GET /__reload HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n'
                     b'Connection: keep-alive, Upgrade\r\nSec-WebSocket-Version: 13\r\n'
                     b'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n' + extra + b'\r\n' + following)
        head = headers(conn)
        assert head.startswith(b'HTTP/1.1 101 '), head
        assert b'Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=' in head
        return conn

    def close(self, force=False):
        if self.proc.poll() is None and force:
            os.killpg(self.proc.pid, signal.SIGTERM)
        try:
            if not force:
                self.proc.stdin.write(b'\n'); self.proc.stdin.flush()
                assert select.select([self.proc.stdout], [], [], 5)[0], 'server stop timeout'
                line = self.proc.stdout.readline()
                assert line == b'stopped\n', line
                assert self.proc.poll() is None, 'fixture must stay alive for cleanup verification'
                if self.on_stopped is not None:
                    self.on_stopped()
            output, errors = self.proc.communicate(input=None if force else b'\n', timeout=5)
        except BaseException:
            if self.proc.poll() is None:
                os.killpg(self.proc.pid, signal.SIGKILL)
            output, errors = self.proc.communicate(timeout=3)
            if errors:
                sys.stderr.buffer.write(errors)
            raise
        if force and errors:
            sys.stderr.buffer.write(errors)
        if not force:
            assert self.proc.returncode == 0, (output.decode(), errors.decode())
            assert b'WARNING: ThreadSanitizer' not in errors, errors.decode()
            assert b'ERROR: AddressSanitizer' not in errors, errors.decode()


@contextlib.contextmanager
def server(*args, **kwargs):
    instance = Server(*args, **kwargs)
    try:
        yield instance
    finally:
        instance.close(force=sys.exc_info()[0] is not None)


def closed(conn, allow_rejection=False):
    try:
        first = conn.recv(1)
        if first:
            assert allow_rejection, 'suspended connection survived shutdown'
            data = bytearray(first)
            try:
                while part := conn.recv(1024):
                    data.extend(part)
            except ConnectionResetError:
                pass
            expected = b'HTTP/1.1 503 '
            assert data.startswith(expected) if len(data) >= len(expected) else expected.startswith(data), bytes(data)
    except ConnectionResetError:
        pass
    finally:
        conn.close()


def thread_count(pid):
    if sys.platform.startswith('linux'):
        return len(list(Path(f'/proc/{pid}/task').iterdir()))
    if sys.platform != 'darwin':
        return None
    value = subprocess.check_output(['ps', '-M', '-p', str(pid), '-o', 'pid='], text=True)
    return sum(bool(line.strip()) for line in value.splitlines()) - 1


def production(binary, web, workers):
    first_check = len(CHECKS)
    held = []
    pending_readers = []
    with server(binary, web, workers=workers) as s:
        assert s.request()[2] == b'ok'
        with s.connect() as conn:
            conn.sendall(b'HEAD /ok HTTP/1.1\r\nHost: localhost\r\n\r\n')
            head = headers(conn)
            assert head.startswith(b'HTTP/1.1 200 ')
            assert b'Content-Length: 2\r\n' in head
            assert conn.recv(1) == b'', 'HEAD must not transmit the representation body'
        for fields in [b'', b'Host: localhost\r\nHost: other\r\n', b'Host: user@localhost\r\n']:
            with s.connect() as conn:
                conn.sendall(b'GET /ok HTTP/1.1\r\n' + fields + b'\r\n')
                assert response(conn)[0] == 400
        for method in [b'PUT', b'DELETE']:
            with s.connect() as conn:
                conn.sendall(method + b' /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3\r\n\r\nabc')
                assert response(conn)[2] == b'abc'
        CHECKS.append('shared Host policy rejects missing/duplicate/userinfo authorities; HEAD sends headers only; PUT/DELETE retain exact body framing')
        baseline_threads = thread_count(s.proc.pid)
        for _ in range(24):
            conn = s.connect()
            conn.sendall(b'GET /ok HTTP/1.1\r\nHo')
            held.append(conn)
        assert s.request()[2] == b'ok'
        after_threads = thread_count(s.proc.pid)
        if baseline_threads is not None:
            assert after_threads == baseline_threads
        OBSERVATIONS.append(dict(workers=workers, suspended_clients=24, threads_before=baseline_threads, threads_after=after_threads))
        CHECKS.append('24 suspended clients allow unrelated requests' + (' without increasing the thread count' if baseline_threads is not None else ''))
        def echo(i):
            body = bytes(j % 251 for j in range([1, 64, 4096, 12000][i % 4]))
            status, _, actual = s.request('/echo', body, fragments=True)
            assert status == 200 and actual == body
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
            list(executor.map(echo, range(32)))
        CHECKS.append('32 concurrent fragmented uploads, including bodies above 4 KiB, return exact bytes')
        assert s.request(extra=b'X-Test: ' + b'x'*6000 + b'\r\n')[0] == 200
        with s.connect() as conn:
            conn.sendall(b'GET /ok HTTP/1.1\r\nX-Test: ' + b'x'*8192 + b'\r\n\r\n')
            assert response(conn)[0] == 431
        for bad, expected in [
            (b'Content-Length: 1\r\nContent-Length: 1\r\n', 400),
            (b'Transfer-Encoding: chunked\r\n', 501),
            (b'Expect: 100-continue\r\n', 417),
            (b'Content-Length: 16385\r\n', 413),
        ]:
            with s.connect() as conn:
                conn.sendall(b'POST /echo HTTP/1.1\r\nHost: localhost\r\n' + bad + b'\r\n')
                assert response(conn)[0] == expected
        with s.connect() as conn:
            conn.sendall(b'POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\n\r\nx')
            conn.shutdown(socket.SHUT_WR)
            assert response(conn)[0] == 400
        CHECKS.append('header growth/limits, duplicate length, unsupported framing/expectations, body limits and truncated bodies retain their statuses')
        slow = s.connect()
        slow.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16384)
        slow.sendall(b'GET /large HTTP/1.1\r\nHost: localhost\r\n\r\n')
        time.sleep(.1)
        assert s.request()[2] == b'ok'
        status, _, body = response(slow)
        assert status == 200 and body == bytes(i % 251 for i in range(2*1024*1024))
        slow.close()
        CHECKS.append('2 MiB response resumes exactly under backpressure while an unrelated request progresses')
        original = bytes(range(256))
        assert s.request('/assets/blob.bin')[2] == original
        (web/'assets/blob.bin').write_bytes(b'changed')
        assert s.request('/assets/blob.bin')[2] == original
        assert b'/__saba/dom.js' in s.request('/view.js')[2]
        assert b'/__saba/page-entry.js' in s.request('/')[2]
        CHECKS.append('production assets remain cached; JSX modules and file-based pages still dispatch before the handler')
        def timeout(body):
            with s.connect() as conn:
                conn.sendall(b'POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\n\r\nx' if body else b'G')
                assert response(conn)[0] == 408
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
            list(executor.map(timeout, [False, True]))
        CHECKS.append('header and body deadlines return 408 without blocking the worker')
        for wire in [b'GET /ok HTTP/1.1\r\nHo', b'POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\n\r\nx']:
            conn = s.connect(); conn.sendall(wire)
            held.append(conn); pending_readers.append(conn)
        assert s.request()[2] == b'ok'  # Earlier accepted readers can park first.
        pending = s.connect()
        pending.sendall(b'GET /large HTTP/1.1\r\nHost: localhost\r\n\r\n')
        held.append(pending)
        def stopped():
            assert s.proc.poll() is None
            for conn in pending_readers:
                closed(conn, allow_rejection=True)
            while True:
                try:
                    if not pending.recv(65536):
                        break
                except ConnectionResetError:
                    break
            pending.close()
        s.on_stopped = stopped
    for conn in held:
        if conn in pending_readers or conn is pending:
            continue
        # A queued response may precede EOF on the writer; drain it first.
        try:
            while conn.recv(65536):
                pass
        except ConnectionResetError:
            pass
        finally:
            conn.close()
    CHECKS.append('shutdown closes parked readers and a blocked writer before process exit, joins workers and releases the published runtime')
    CHECKS[first_check:] = [f'workers={workers}: '+item for item in CHECKS[first_check:]]


def capacity(binary, web):
    held = []
    with server(binary, web, workers=4, capacity=2) as s:
        for _ in range(2):
            conn = s.connect(); conn.sendall(b'G'); held.append(conn)
        assert s.request()[0] == 503
        held.pop().close()
        deadline = time.monotonic() + 3
        while s.request()[0] == 503:
            assert time.monotonic() < deadline
            time.sleep(.01)
    for conn in held:
        closed(conn)
    CHECKS.append('capacity rejection returns best-effort 503 and admission recovers after connection cleanup')


def development(binary, web):
    held = []
    with server(binary, web, development=True) as s:
        body = s.request('/html')[2]
        assert body.count(b'/__reload/client.js') == 1
        assert s.request('/assets/blob.bin')[2] == b'changed'
        conn = s.websocket(frame(9, b'coalesced'), extra=b'X-Pad: '+b'x'*2000+b'\r\n')
        assert received_frame(conn) == (10, b'coalesced')
        for value in frame(9, b'fragmented'):
            conn.sendall(bytes([value]))
        assert received_frame(conn) == (10, b'fragmented')
        conn.sendall(frame(8, struct.pack('>H', 1000)+b'bye'))
        assert received_frame(conn) == (8, struct.pack('>H', 1000)+b'bye')
        closed(conn)
        CHECKS.append('reload WebSocket upgrades, coalesced/fragmented masked pings and close echoes work')
        for invalid, expected in [(frame(9, b'x', masked=False), 1002), (b'\x89\xfe', 1002),
                                  (frame(8, b'\x03\xe8\xff'), 1007), (frame(1, b'x'), 1003)]:
            conn = s.websocket()
            conn.sendall(invalid)
            opcode, payload = received_frame(conn)
            assert opcode == 8 and struct.unpack('>H', payload[:2])[0] == expected
            closed(conn)
        CHECKS.append('unmasked/oversized control frames, invalid close UTF-8 and unsupported data frames receive the existing close codes')
        held = [s.websocket() for _ in range(16)]
        assert s.request()[2] == b'ok'
        (web/'view.jsx').write_text('export default function View(){ return <p>updated</p>; }')
        for conn in held:
            assert received_frame(conn) == (1, b'reload')
            opcode, payload = received_frame(conn)
            assert opcode == 8 and struct.unpack('>H', payload[:2])[0] == 1000
            closed(conn)
        held = [s.websocket(), s.websocket()]
        held[1].sendall(b'\x89\x83\x01')
        assert s.request()[2] == b'ok'
        def stopped():
            assert s.proc.poll() is None
            for conn in held:
                closed(conn)
            held.clear()
        s.on_stopped = stopped
    for conn in held:
        closed(conn)
    CHECKS.append('idle WebSockets do not occupy the sole worker; watcher changes send reload+close and shutdown cancels partial frames')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--sanitize', choices=['thread', 'address'])
    args = parser.parse_args()
    compiler = os.environ.get('ODIN') or shutil.which('odin') or str(SABA.parents[1]/'odin')
    with tempfile.TemporaryDirectory(prefix='saba-async-test-') as work:
        root = Path(work); web = root/'web'
        (web/'assets').mkdir(parents=True); (web/'pages').mkdir()
        (web/'assets/blob.bin').write_bytes(bytes(range(256)))
        (web/'view.jsx').write_text('export default function View(){ return <div>hello</div>; }')
        (web/'pages/index.jsx').write_text('export const title="Home"; export default function Home(){ return <h1>Home</h1>; }')
        (web/'index.html').write_text('<html><head></head><body><!--saba:page--></body></html>')
        binary = root/'server'
        command = [compiler, 'build', str(SABA/'testdata/async'), '-warnings-as-errors', '-out:'+str(binary)]
        if args.sanitize:
            command.append('-sanitize:'+args.sanitize)
        compiled = subprocess.run(command, capture_output=True, text=True, timeout=60)
        assert compiled.returncode == 0, compiled.stdout+compiled.stderr
        for workers in [1, 4]:
            (web/'assets/blob.bin').write_bytes(bytes(range(256)))
            production(binary, web, workers)
        capacity(binary, web)
        development(binary, web)
        env = os.environ.copy(); env.update(SABA_TEST_WEB=str(web), SABA_TEST_PRESTOP='1')
        p = subprocess.run([str(binary)], env=env, capture_output=True, timeout=8)
        assert p.returncode == 0, (p.stdout, p.stderr)
        CHECKS.append('a shutdown request made before listener publication is honored')
    print(json.dumps(dict(valid=True, sanitizer=args.sanitize or 'none', checks=CHECKS, observations=OBSERVATIONS), indent=2))


if __name__ == '__main__':
    main()
