#!/usr/bin/env python3
"""Owned mixed-resource admission with snapshots outside the HTTP budget."""
import sys; sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent))
import harness_env
import argparse
import contextlib
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time
from offload import Server
from keep_alive import request, response


class ResourceServer(Server):
    def __init__(self, binary, mode):
        previous = os.environ.get('SABA_RESOURCE_MODE')
        os.environ['SABA_RESOURCE_MODE'] = mode
        try:
            super().__init__(binary)
        finally:
            if previous is None:
                os.environ.pop('SABA_RESOURCE_MODE', None)
            else:
                os.environ['SABA_RESOURCE_MODE'] = previous
    def usage(self):
        self.command('p')
        values = tuple(map(int, self.line('usage ').split()[1:]))
        names = ('bytes streams jobs queued running held rejected peak '
                 'nodes capacity growths limit')
        return dict(zip(names.split(), values))
    def wait_usage(self, condition):
        started = time.monotonic()
        while True:
            view = self.usage()
            assert view['bytes'] <= view['limit'], view
            if condition(view):
                return view
            assert time.monotonic() - started < 6, view
            time.sleep(.005)


def reset(conn):
    conn.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
    conn.close()


def partial_upload(conn, size):
    head = b'POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Length: '
    # Storage follows the bytes received, not the declared length: send all but
    # the last byte so the server really holds `size`, yet never dispatches.
    conn.sendall(head + str(size).encode() + b'\r\n\r\n')
    try:
        conn.sendall(b'x' * (size - 1))
    except OSError:
        pass  # rejected mid-upload: the 503 is already on its way



def level_admission(binary, checks):
    for mode in ('operation', 'connection'):
        with ResourceServer(binary, mode) as server:
            with server.connect() as conn:
                partial_upload(conn, 1024 * 1024)
                assert response(conn)[0] == 503
            server.wait_usage(lambda v: v['bytes'] == 0)
            values = tuple(map(int, server.exchange('/scopes')[2].split()))
            op_limit, conn_limit, global_limit, op_used, conn_used, global_used = values
            assert op_limit == (512 * 1024 if mode == 'operation' else 32 * 1024 * 1024)
            assert conn_limit == (512 * 1024 if mode == 'connection' else 64 * 1024 * 1024)
            assert global_limit == 256 * 1024 * 1024
            assert 0 < op_used <= conn_used <= global_used
            assert server.exchange('/cheap')[2] == b'cheap'
    checks.append('operation and connection limits reject independently of ample global headroom')

def byte_admission(binary, checks):
    with ResourceServer(binary, 'bytes') as server:
        clients = [server.connect() for _ in range(2)]
        for conn in clients:
            partial_upload(conn, 1024 * 1024)
        held = server.wait_usage(lambda v: v['bytes'] >= 2 * 1024 * 1024)
        assert held['jobs'] == held['streams'] == 0
        with server.connect() as rejected:
            partial_upload(rejected, 1024 * 1024)
            assert response(rejected)[0] == 503
        assert server.exchange('/cheap')[2] == b'cheap'
        assert server.usage()['rejected'] > held['rejected']
        for conn in clients:
            reset(conn)
        server.wait_usage(lambda v: v['bytes'] == 0)
    checks.append('full upload backing is charged before payload arrives; '
                  'global reject and recovery')
    with ResourceServer(binary, 'bytes') as server:
        code, _, body = server.exchange('/slow')
        assert code == 200 and len(body) == 1024 * 1024
        server.wait_usage(lambda v: v['bytes'] == 0)
        conn = server.connect()
        conn.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
        conn.sendall(request('/slow'))
        server.wait_usage(lambda v: v['bytes'] >= 2 * 1024 * 1024)
        assert server.exchange('/large')[0] == 503
        assert server.exchange('/cheap')[2] == b'cheap'
        reset(conn)
        server.wait_usage(lambda v: v['bytes'] == 0)
    checks.append('slow buffered reader retains both real copies; another large response rejects')


def stream_and_metadata(binary, checks):
    with ResourceServer(binary, 'streams') as server:
        conn = server.connect()
        conn.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
        conn.sendall(request('/stream'))
        server.wait_usage(lambda v: v['streams'] == 1)
        assert server.exchange('/stream')[0] == 503
        assert server.exchange('/cheap')[2] == b'cheap'
        reset(conn)
        server.wait_usage(lambda v: v['streams'] == 0 and v['bytes'] == 0)
    checks.append('one active streaming exchange blocks a second; final disposal recovers its slot')
    with ResourceServer(binary, 'bytes') as server:
        clients = [server.connect() for _ in range(20)]
        view = server.wait_usage(lambda v: v['capacity'] >= 32 and v['nodes'] >= 42)
        assert view['bytes'] == 0 and view['streams'] == view['jobs'] == 0, view
        assert view['limit'] == 3 * 1024 * 1024 and view['growths'] > 0
        for conn in clients:
            reset(conn)
        server.wait_usage(lambda v: v['nodes'] == 2)
    checks.append('metadata grows from two to32 slots while independent payload limits stay fixed')


def mixed(binary, checks):
    with ResourceServer(binary, 'mixed') as server, contextlib.ExitStack() as clients:
        slow = clients.enter_context(server.connect())
        slow.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
        slow.sendall(request('/slow'))
        server.wait_usage(lambda v: v['bytes'] >= 8 * 1024 * 1024)
        upload = clients.enter_context(server.connect())
        partial_upload(upload, 4 * 1024 * 1024)
        server.wait_usage(lambda v: v['bytes'] >= 12 * 1024 * 1024)
        jobs = [clients.enter_context(server.connect()) for _ in range(2)]
        for conn in jobs:
            conn.sendall(request('/work', 'POST', b'j' * (512 * 1024)))
        server.wait_usage(lambda v: v['running'] == v['jobs'] == 2)
        streams = [clients.enter_context(server.connect()) for _ in range(2)]
        for conn in streams:
            conn.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
            conn.sendall(request('/stream'))
        held = server.wait_usage(lambda v: v['streams'] == 2 and v['bytes'] > 14 * 1024 * 1024)
        assert held['queued'] == held['held'] == 0
        assert server.exchange('/work')[0] == 503
        assert server.exchange('/stream')[0] == 503
        assert server.exchange('/large')[0] == 503
        for _ in range(16):
            assert server.exchange('/cheap')[2] == b'cheap'
        pressure = server.usage()
        assert pressure['jobs'] == pressure['running'] == pressure['streams'] == 2, pressure
        assert pressure['rejected'] > held['rejected'] and pressure['peak'] <= pressure['limit']
        server.retire()
        late = server.usage()
        assert late['jobs'] == late['running'] == 2 and late['streams'] == 0, late
        assert late['bytes'] >= 1024 * 1024, late
        # finish releases functions only after the entire server/runtime has retired.
    checks.append('shared global bytes/streams/jobs bound mixed slow readers/'
                  'uploads/work and late jobs')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--odin', default=harness_env.odin())
    parser.add_argument('--shared', default=harness_env.shared())
    parser.add_argument('--sanitize', choices=['address', 'thread'])
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='saba-resources-') as work:
        binary = Path(work) / 'server'
        source = Path(__file__).resolve().parents[1] / 'testdata/offload'
        command = [args.odin, 'build', str(source), '-collection:shared=' + args.shared,
                   '-warnings-as-errors', '-thread-count:1', '-out:' + str(binary)]
        if args.sanitize:
            command.append('-sanitize:' + args.sanitize)
        subprocess.run(command, check=True, timeout=60)
        checks = []
        level_admission(binary, checks)
        byte_admission(binary, checks)
        stream_and_metadata(binary, checks)
        mixed(binary, checks)
    print(json.dumps(dict(valid=True, sanitizer=args.sanitize or 'none', checks=checks)))


if __name__ == '__main__':
    main()
