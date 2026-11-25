#!/usr/bin/env python3
"""Owned offload wire checks with one network worker and two fixed job workers."""
import sys; sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent))
import harness_env
import argparse
import contextlib
import json
import os
from pathlib import Path
import queue
import select
import socket
import subprocess
import tempfile
import threading
import time
from keep_alive import request, response, closed


class Server:
    def __init__(self, binary, budget=0, fifo=""):
        env = dict(os.environ, SABA_OFFLOAD_BUDGET_MS=str(budget), SABA_OFFLOAD_FIFO=str(fifo))
        self.proc = subprocess.Popen([str(binary)], env=env, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.lines = queue.Queue()
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()
        self.port = int(self.line('ready ').split()[1])
        self.retired = None
    def read(self):
        for line in self.proc.stdout:
            self.lines.put(line.strip())
    def line(self, prefix):
        line = self.lines.get(timeout=8)
        assert line.startswith(prefix), line
        return line
    def command(self, value):
        self.proc.stdin.write(value); self.proc.stdin.flush()
    def connect(self):
        return socket.create_connection(('127.0.0.1', self.port), timeout=4)
    def exchange(self, path):
        with self.connect() as conn:
            conn.sendall(request(path)); return response(conn)
    def status(self):
        return tuple(map(int, self.exchange('/status')[2].split()))
    def until(self, condition):
        start = time.monotonic()
        while True:
            state = self.status()
            if condition(state):
                return state
            assert time.monotonic() - start < 3, state
            time.sleep(.005)
    def retire(self, mode='s'):
        self.command(mode)
        self.retired = int(self.line('retired ').split()[1])
        return self.retired
    def finish(self):
        if self.retired is None:
            self.retire()
        self.command('r')
        summary = self.line('stopped ')
        self.proc.wait(timeout=5); self.reader.join(timeout=2)
        error = self.proc.stderr.read()
        assert self.proc.returncode == 0, error
        assert 'Sanitizer' not in error and 'Assertion' not in error, error
        return tuple(map(int, summary.split()[1:]))
    def __enter__(self):
        return self
    def __exit__(self, kind, value, trace):
        try:
            if kind is None:
                self.finish()
        finally:
            if self.proc.poll() is None:
                self.proc.kill(); self.proc.wait(timeout=5)
            for pipe in (self.proc.stdin, self.proc.stdout, self.proc.stderr):
                pipe.close()


def check_admission(binary, checks):
    with Server(binary) as server, contextlib.ExitStack() as sockets:
        clients = [sockets.enter_context(server.connect()) for _ in range(4)]
        for i, conn in enumerate(clients):
            conn.sendall(request('/work', 'POST', str(i).encode()))
        # The pool counts a job as running when a worker takes it, an instant
        # before the job body records its run; wait for both.
        state = server.until(lambda s: s[:4] == (2, 2, 4, 2))
        assert state[4] == 0, state
        assert server.exchange('/work')[0] == 503
        for _ in range(32):
            started = time.monotonic()
            assert server.exchange('/cheap')[2] == b'cheap'
            assert time.monotonic() - started < .5
        server.exchange('/release')
        for i, conn in enumerate(clients):
            code, _, body = response(conn)
            assert (code, body) == (201, str(i).encode()), (code, body)
        assert server.until(lambda s: s[2] == 0)[4] == 5
    checks.append('queue/full overload and cheap-route progress while both job workers block')


def check_pipeline(binary, checks):
    with Server(binary) as server, server.connect() as conn:
        conn.sendall(request('/work', 'POST', b'snapshot') + request('/cheap'))
        server.until(lambda s: s[0] == 1)
        assert not select.select([conn], [], [], .03)[0], 'headers committed before result'
        server.exchange('/release')
        assert response(conn)[::2] == (201, b'snapshot')
        assert response(conn)[::2] == (200, b'cheap')
    checks.append('pre-header result and bounded pipelined bytes survive job disposal')
    with Server(binary) as server, server.connect() as conn:
        conn.sendall(request('/work', 'POST', b'late pipeline'))
        server.until(lambda s: s[0] == 1)
        conn.sendall(request('/cheap', fields=b'X-Large: ' + b'a' * 2048 + b'\r\n'))
        assert not select.select([conn], [], [], .03)[0]
        server.exchange('/release')
        assert response(conn)[::2] == (201, b'late pipeline')
        assert response(conn)[::2] == (200, b'cheap')
    checks.append('pipeline arriving after suspension grows bounded storage without early headers')
    with Server(binary) as server, server.connect() as conn:
        conn.sendall(request('/work', 'POST', b'bounded owner'))
        server.until(lambda s: s[0] == 1)
        conn.sendall(b'x' * 32769)
        closed(conn)
        state = server.until(lambda s: s[5] == 1)
        assert state[:5] == (1, 0, 1, 1, 0), state
        server.exchange('/release')
        assert server.until(lambda s: s[2] == 0)[4] == 1
    checks.append(
        'pipeline overflow closes and retires owner while independent work remains '
        'blocked'
    )


def check_retirement(binary, checks):
    with Server(binary) as server:
        clients = [server.connect() for _ in range(2)]
        for conn in clients:
            conn.sendall(request('/work', 'POST', b'late owner'))
        server.until(lambda s: s[0] == 2)
        for conn in clients:
            conn.close()
        state = server.until(lambda s: s[5] == 2)
        assert state[:5] == (2, 0, 2, 2, 0), state
        server.exchange('/release')
        assert server.until(lambda s: s[2] == 0)[4] == 2
    checks.append('peer close retires owners/arenas before non-interruptible jobs finish')
    with Server(binary, budget=80) as server, server.connect() as conn:
        conn.sendall(request('/work', 'POST', b'expired owner'))
        assert response(conn)[0] == 408
        closed(conn)
        state = server.until(lambda s: s[5] == 1)
        assert state[:5] == (1, 0, 1, 1, 0), state
        server.exchange('/release')
        assert server.until(lambda s: s[2] == 0)[4] == 1
    checks.append('deadline sends 408 and retires arena while blocked work retains its snapshot')
    with Server(binary) as server, contextlib.ExitStack() as sockets:
        clients = [sockets.enter_context(server.connect()) for _ in range(4)]
        for conn in clients:
            conn.sendall(request('/work', 'POST', b'stop owner'))
        server.until(lambda s: s[:3] == (2, 2, 4))
        assert server.retire() == 4
        for conn in clients:
            closed(conn)
        # Runtime and all request arenas are gone before finish releases workers.
    checks.append('shutdown retires all owners before releasing running and queued jobs')
    with Server(binary) as server, server.connect() as conn:
        conn.sendall(request('/work', 'POST', b'drain owner'))
        server.until(lambda s: s[0] == 1)
        assert server.retire('d') == 1
        closed(conn)
    checks.append('drain deadline retires deferred owner before blocked work is released')


def check_failure_and_file(binary, checks):
    with Server(binary) as server, server.connect() as conn:
        conn.sendall(request('/fail', 'POST', b'failed output'))
        server.until(lambda s: s[0] == 1)
        server.exchange('/release')
        code, _, body = response(conn)
        assert code == 500 and body == b''
        assert server.until(lambda s: s[2] == 0)[4] == 1
    checks.append('failed jobs expose no result and release owned storage exactly once')
    with tempfile.TemporaryDirectory(prefix='offload-fifo-') as directory:
        fifo = Path(directory) / 'owned.fifo'
        os.mkfifo(fifo)
        with Server(binary, fifo=fifo) as server, server.connect() as conn:
            conn.sendall(request('/file'))
            # The sole filesystem worker is blocked opening a real named pipe.
            # A second request must reject without opening another descriptor.
            until = time.monotonic() + 3
            while server.exchange('/file-status')[2] != b'1 0 1':
                assert time.monotonic() < until
                time.sleep(.005)
            assert server.exchange('/file')[0] == 503
            assert server.exchange('/cheap')[2] == b'cheap'
            with fifo.open('wb', buffering=0) as writer:
                writer.write(b'owned filesystem bytes')
            assert response(conn)[::2] == (200, b'owned filesystem bytes')
    checks.append(
        'one bounded filesystem lane blocks in owned FIFO open while cheap routes '
        'progress'
    )


def run(binary):
    checks = []
    check_admission(binary, checks)
    check_pipeline(binary, checks)
    check_retirement(binary, checks)
    check_failure_and_file(binary, checks)
    return checks


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--odin', default=harness_env.odin())
    parser.add_argument('--shared', default=harness_env.shared())
    parser.add_argument('--sanitize', choices=['address', 'thread'])
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='saba-offload-') as work:
        binary = Path(work) / 'server'
        source = Path(__file__).resolve().parents[1] / 'testdata/offload'
        command = [args.odin, 'build', str(source), '-collection:shared=' + args.shared,
                   '-warnings-as-errors', '-thread-count:1', '-out:' + str(binary)]
        if args.sanitize:
            command.append('-sanitize:' + args.sanitize)
        subprocess.run(command, check=True, timeout=60)
        checks = run(binary)
    print(json.dumps(dict(valid=True, sanitizer=args.sanitize or 'none', checks=checks)))


if __name__ == '__main__':
    main()
