#!/usr/bin/env python3
"""Owned lifetime tests: server cancellation, retained tokens, late disposal."""
import sys; sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent))
import harness_env
import argparse
import contextlib
import os
from pathlib import Path
import queue
import socket
import struct
import subprocess
import tempfile
import threading
import time
from keep_alive import request, response


class Server:
    def __init__(self, binary, budget=0):
        env = os.environ.copy(); env['SABA_CANCEL_BUDGET_MS'] = str(budget)
        self.proc = subprocess.Popen([str(binary)], env=env, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.pending = queue.Queue(); self.stopped = None
        def read():
            for line in self.proc.stdout:
                self.pending.put(line.strip())
        self.reader = threading.Thread(target=read, daemon=True); self.reader.start()
        ready = self.pending.get(timeout=8); assert ready.startswith('ready '), ready
        self.port = int(ready.split()[1])
    def connect(self):
        return socket.create_connection(('127.0.0.1', self.port), timeout=4)
    def exchange(self, path):
        with self.connect() as conn:
            conn.sendall(request(path)); return response(conn)
    def stop(self, mode='s'):
        if self.stopped is None:
            self.proc.stdin.write(mode); self.proc.stdin.flush()
            self.proc.wait(timeout=5); self.reader.join(timeout=2)
            self.stopped = self.pending.get(timeout=2)
            error = self.proc.stderr.read()
            assert self.proc.returncode == 0, error
            assert 'ERROR: AddressSanitizer' not in error and 'WARNING: ThreadSanitizer' not in error, error
            assert self.stopped.startswith('stopped '), self.stopped
        return self.stopped
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


def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--odin', default=harness_env.odin())
    parser.add_argument('--sanitize', choices=['address', 'thread']); args = parser.parse_args()
    checks = []
    with tempfile.TemporaryDirectory(prefix='saba-cancellation-') as work:
        binary = Path(work)/'server'
        source = Path(__file__).resolve().parents[1]/'testdata/cancellation'
        command = [args.odin, 'build', str(source), '-warnings-as-errors', harness_env.collection(), '-out:'+str(binary)]
        if args.sanitize:
            command.append('-sanitize:'+args.sanitize)
        subprocess.run(command, check=True, timeout=60)
        with Server(binary) as instance:
            with instance.connect() as conn:
                conn.sendall(request('/hold')); assert response(conn)[2] == b'0'
                for _ in range(12):
                    conn.sendall(request('/status')); assert response(conn)[2] == b'0 Completed'
            assert instance.stop() == 'stopped 0 Completed'
        checks.append('retained token survives repeated request-arena resets and runtime destruction')
        with Server(binary, budget=25) as instance:
            code, _, body = instance.exchange('/late')
            # A handler that finished late answers 504: 408 would invite a replay.
            assert code == 504 and not body
            assert instance.exchange('/status')[2] == b'1 Deadline'
            assert instance.stop() == 'stopped 1 Deadline'
        checks.append('late handler response rejected and transferred continuation dropped exactly once')
        with Server(binary) as instance:
            with instance.connect() as conn:
                conn.sendall(request('/cooperate'))
                assert instance.pending.get(timeout=3) == 'working'
                started = time.monotonic(); summary = instance.stop()
                assert time.monotonic()-started < 2
                assert summary == 'stopped 1 Shutdown', summary
                try:
                    assert conn.recv(1) == b''
                except ConnectionResetError:
                    pass
        checks.append('shutdown reaches a running cooperative handler with one network worker and disposes its response')
        with Server(binary) as instance:
            with instance.connect() as conn:
                conn.sendall(request('/cooperate'))
                assert instance.pending.get(timeout=3) == 'working'
                started = time.monotonic(); summary = instance.stop('d')
                assert time.monotonic()-started < 2
                assert summary == 'stopped 1 Shutdown', summary
        checks.append('drain deadline reaches a running cooperative handler even with one worker')
        with Server(binary) as instance:
            conn = instance.connect(); conn.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
            conn.sendall(request('/peer')); assert conn.recv(1)
            conn.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0)); conn.close()
            until = time.monotonic()+3
            while True:
                status = instance.exchange('/status')[2]
                if status in [b'0 Peer_Closed', b'0 Failed']:
                    break
                assert time.monotonic() < until, status
                time.sleep(.01)
            assert instance.stop().split()[-1] in ['Peer_Closed', 'Failed']
        checks.append('observable peer failure cancels a retained context without observability enabled')
    print({'valid': True, 'sanitizer': args.sanitize or 'none', 'checks': checks})


if __name__ == '__main__':
    main()
