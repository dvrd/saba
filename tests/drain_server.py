#!/usr/bin/env python3
"""Exercise drain using only child-owned loopback servers and synthetic requests."""
import sys; sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent))
import harness_env
import argparse
import os
from pathlib import Path
import select
import socket
import subprocess
import tempfile
import time
import json

SABA = Path(__file__).resolve().parents[1]


class Server:
    def __init__(self, binary, workers, milliseconds, web=None):
        env = dict(os.environ, DRAIN_WORKERS=str(workers), DRAIN_MS=str(milliseconds))
        if web is not None:
            env['DRAIN_WEB'] = str(web)
        self.proc = subprocess.Popen([str(binary)], env=env, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.buffer = b''
        self.lines = []
        self.joined = False
        try:
            self.port = int(self.wait(b'ready ').split()[1])
        except BaseException:
            if self.proc.poll() is None:
                self.proc.kill()
            self.proc.wait()
            self.proc.stdin.close()
            self.proc.stdout.close()
            self.proc.stderr.close()
            raise

    def wait(self, prefix, timeout=6):
        until = time.monotonic() + timeout
        while True:
            for index, line in enumerate(self.lines):
                if line.startswith(prefix):
                    return self.lines.pop(index)
            remaining = until - time.monotonic()
            assert remaining > 0, (prefix, self.lines, self.proc.poll())
            assert select.select([self.proc.stdout], [], [], remaining)[0], ('timeout', prefix)
            part = os.read(self.proc.stdout.fileno(), 4096)
            assert part, ('server exited', self.proc.poll(), self.proc.stderr.read().decode())
            self.buffer += part
            while b'\n' in self.buffer:
                line, self.buffer = self.buffer.split(b'\n', 1)
                self.lines.append(line)

    def command(self, value):
        self.proc.stdin.write(value)
        self.proc.stdin.flush()

    def connect(self):
        return socket.create_connection(('127.0.0.1', self.port), timeout=5)

    def admitted(self):
        until = time.monotonic() + 3
        while time.monotonic() < until:
            self.command(b'c')
            if int(self.wait(b'capacity ').split()[1]) > 0:
                return
            time.sleep(.005)
        raise AssertionError('connection not admitted')

    def drain(self):
        self.command(b'd')
        line = self.wait(b'drain ')
        assert line.split()[-1] == b'false', line

    def join(self):
        assert self.wait(b'finished ').split()[-1] == b'true'
        self.command(b'j')
        self.wait(b'joined')
        self.joined = True
        assert self.proc.poll() is None, 'process exit must not conceal leaked sockets'

    def close(self):
        try:
            if self.proc.poll() is None:
                if not self.joined:
                    self.command(b'rs')
                    self.join()
                self.command(b'q')
                self.proc.wait(timeout=5)
            assert self.proc.returncode == 0, self.proc.stderr.read().decode()
        finally:
            if self.proc.poll() is None:
                self.proc.kill()
                self.proc.wait()
            self.proc.stdin.close()
            self.proc.stdout.close()
            self.proc.stderr.close()


def headers(conn):
    result = bytearray()
    while not result.endswith(b'\r\n\r\n'):
        part = conn.recv(1)
        assert part, bytes(result)
        result.extend(part)
    return bytes(result)


def closed(conn):
    conn.settimeout(4)
    try:
        while conn.recv(65536):
            pass
    except (ConnectionResetError, BrokenPipeError):
        pass


def reject_new_work(server):
    try:
        extra = server.connect()
    except (ConnectionRefusedError, ConnectionResetError):
        return
    try:
        extra.settimeout(.7)
        extra.sendall(b'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n')
        reply = extra.recv(256)
        assert not reply or reply.startswith(b'HTTP/1.1 503 '), reply
    except (ConnectionResetError, BrokenPipeError):
        pass
    finally:
        extra.close()


def completed_body(binary, workers):
    server = Server(binary, workers, 1500)
    conn = server.connect()
    try:
        conn.sendall(b'POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\n\r\nab')
        server.admitted()
        server.drain()
        reject_new_work(server)
        conn.sendall(b'cd')
        assert headers(conn).startswith(b'HTTP/1.1 200 ')
        body = b''
        while len(body) < 4:
            part = conn.recv(4-len(body))
            assert part, 'response body ended before admitted work completed'
            body += part
        assert body == b'abcd'
        server.join()
        closed(conn)
        try:
            extra = server.connect()
        except (ConnectionRefusedError, ConnectionResetError):
            pass
        else:
            try:
                extra.sendall(b'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n')
                assert not extra.recv(1), 'new work served after drain completed'
            except (ConnectionResetError, BrokenPipeError):
                pass
            finally:
                extra.close()
    finally:
        conn.close()
        server.close()


def stalled_reader(binary, workers):
    server = Server(binary, workers, 250)
    conn = server.connect()
    try:
        conn.sendall(b'GET /')
        server.admitted()
        started = time.monotonic()
        server.drain()
        time.sleep(.12)
        server.drain()  # A second request must not reset the first deadline.
        server.join()
        elapsed = time.monotonic()-started
        assert .15 <= elapsed < .9, elapsed
        closed(conn)
    finally:
        conn.close()
        server.close()


def shorter_deadline(binary, workers):
    server = Server(binary, workers, 1500)
    conn = server.connect()
    try:
        conn.sendall(b'GET /')
        server.admitted()
        started = time.monotonic()
        server.drain()
        server.command(b'f')
        assert server.wait(b'drain ').split()[-1] == b'false'
        server.join()
        assert time.monotonic()-started < .8
        closed(conn)
    finally:
        conn.close()
        server.close()


def active_handler(binary, workers):
    server = Server(binary, workers, 1500)
    conn = server.connect()
    try:
        conn.sendall(b'GET /hold HTTP/1.1\r\nHost: localhost\r\n\r\n')
        server.wait(b'holding')
        server.drain()
        server.command(b'r')
        assert headers(conn).startswith(b'HTTP/1.1 200 ')
        server.join()
        closed(conn)
    finally:
        conn.close()
        server.close()


def backpressured_writer(binary, workers):
    server = Server(binary, workers, 200)
    conn = server.connect()
    conn.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
    try:
        conn.sendall(b'GET /large HTTP/1.1\r\nHost: localhost\r\n\r\n')
        assert headers(conn).startswith(b'HTTP/1.1 200 ')
        server.drain()
        server.join()
        closed(conn)
    finally:
        conn.close()
        server.close()


def parked_websocket(binary, workers):
    with tempfile.TemporaryDirectory(prefix='saba-drain-web-') as web:
        server = Server(binary, workers, 200, web=web)
        conn = server.connect()
        try:
            conn.sendall(b'GET /__reload HTTP/1.1\r\nHost: localhost\r\n'
                         b'Upgrade: websocket\r\nConnection: Upgrade\r\n'
                         b'Sec-WebSocket-Version: 13\r\n'
                         b'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n')
            assert headers(conn).startswith(b'HTTP/1.1 101 ')
            server.drain()
            server.join()
            closed(conn)
        finally:
            conn.close()
            server.close()


def immediate_override(binary, workers):
    server = Server(binary, workers, 5000)
    conn = server.connect()
    try:
        conn.sendall(b'GET /')
        server.admitted()
        server.drain()
        started = time.monotonic()
        server.command(b'ss')
        server.join()
        assert time.monotonic()-started < 1.5
        closed(conn)
    finally:
        conn.close()
        server.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--odin', default=harness_env.odin())
    parser.add_argument('--sanitize', action='store_true')
    args = parser.parse_args()
    checks = []
    with tempfile.TemporaryDirectory(prefix='saba-drain-') as directory:
        binary = Path(directory) / 'server'
        command = [args.odin, 'build', str(SABA/'testdata/drain'), '-thread-count:1',
                   '-warnings-as-errors', harness_env.collection(), '-out:'+str(binary)]
        if args.sanitize:
            command.append('-sanitize:address')
        subprocess.run(command, check=True)
        for workers in (1, 4):
            for test in (completed_body, stalled_reader, shorter_deadline, active_handler, backpressured_writer, parked_websocket, immediate_override):
                test(binary, workers)
                checks.append(f'workers={workers}: {test.__name__}')
        pre = subprocess.run([str(binary)], env=dict(os.environ, DRAIN_PRESTART='1', DRAIN_WORKERS='1'),
                             text=True, capture_output=True, timeout=5)
        assert pre.returncode == 0 and 'prestart drained' in pre.stdout, pre.stderr
        checks.append('pre-publication drain honored and control reused across two serves')
    print(json.dumps({'valid': True, 'sanitizer': args.sanitize, 'checks': checks}, indent=2))


if __name__ == '__main__':
    main()
