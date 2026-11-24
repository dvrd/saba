#!/usr/bin/env python3
"""Owned HTTP/1 chunked upload, framing, deadline and persistence regressions."""
import sys; sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent))
import harness_env
import argparse
import contextlib
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

from keep_alive import Server, closed, request, response


def head(path='/echo', extra=b''):
    return b'POST '+path.encode()+b' HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n'+extra+b'\r\n'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--odin', default=harness_env.odin())
    parser.add_argument('--sanitize', choices=['address'])
    args = parser.parse_args()
    checks = []
    source = Path(__file__).resolve().parents[1]/'testdata/keepalive'
    with tempfile.TemporaryDirectory(prefix='saba-chunked-') as work:
        binary = Path(work)/'server'
        command = [args.odin, 'build', str(source), '-warnings-as-errors', harness_env.collection(), '-out:'+str(binary)]
        if args.sanitize:
            command.append('-sanitize:'+args.sanitize)
        subprocess.run(command, check=True, timeout=60)
        expected_received = []
        with Server(binary) as instance:
            body = b'3;name="a,b"\r\nabc\r\n2\r\nde\r\n0\r\nX-Check: ok\r\n\r\n'
            upload = head()+body
            following = request('/id')
            for split in range(len(body)+1):
                with instance.connect() as conn:
                    conn.sendall(head()+body[:split])
                    if split:
                        time.sleep(.001)
                    conn.sendall(body[split:]+following)
                    code, fields, data = response(conn)
                    assert code == 200 and data == b'abcde', (split, code, data)
                    assert b'Connection: keep-alive' in fields
                    assert response(conn)[0] == 200
                expected_received.extend([len(upload), len(following)])
            checks.append('every framing/body/trailer split and coalesced next request preserve byte ownership')
            with instance.connect() as conn:
                conn.sendall(head())
                for byte in b'1\r\nx\r\n0\r\n\r\n':
                    conn.sendall(bytes([byte]));time.sleep(.001)
                assert response(conn)[2] == b'x'
            expected_received.append(len(head())+len(b'1\r\nx\r\n0\r\n\r\n'))
            checks.append('one-byte framing/data fragmentation')
            # Force reads past both the initial head buffer and async input scratch.
            with instance.connect() as conn:
                content = b'ab'*1500
                large = head()+b'bb8\r\n'+content+b'\r\n0\r\n\r\n'
                conn.sendall(large+following)
                assert response(conn)[2] == content
                assert response(conn)[0] == 200
            expected_received.extend([len(large), len(following)])
            # Independent standard-library encoder, including binary body bytes.
            with contextlib.closing(http.client.HTTPConnection('127.0.0.1', instance.port, timeout=3)) as conn:
                content = [b'one', bytes(range(256)), b'three']
                conn.request('POST', '/echo', body=iter(content), encode_chunked=True)
                reply = conn.getresponse()
                assert reply.status == 200 and reply.read() == b''.join(content)
            checks.append('independent Python http.client chunk encoder and binary data')
            for path, wire, wanted in [
                ('/limited', b'4\r\nabcd\r\n0\r\n\r\n', 200),
                ('/limited', b'0\r\n\r\n', 200),
                ('/limited', b'5\r\n', 413),
                ('/limited', b'3\r\nabc\r\n2\r\n', 413),
                ('/echo', b'1001\r\n', 413),
                ('/echo', b'1\r\naXX', 400),
                ('/echo', b'1\na', 400),
                ('/echo', b'0\r\nContent-Length: 0\r\n\r\n', 400),
                ('/echo', b'0\r\nCookie: spoof\r\n\r\n', 400),
                ('/echo', b'1;x='+b'x'*1024+b'\r\n', 413),
                ('/echo', b'0\r\n'+b'X: y\r\n'*33+b'\r\n', 413),
            ]:
                with instance.connect() as conn:
                    conn.sendall(head(path)+wire)
                    status, fields, _ = response(conn)
                    assert status == wanted, (path, wire[:40], status)
                    if wanted != 200:
                        assert b'Connection: close' in fields
                        closed(conn)
            checks.append('decoded-size exact/cumulative caps, oversized declaration, line/trailer caps and malformed framing fail closed')
            for fields, wanted in [(b'Content-Length: 0\r\n',400),
                                   (b'Transfer-Encoding: chunked\r\n',400),
                                   (b'Expect: 200-ok\r\n',417)]:
                with instance.connect() as conn:
                    conn.sendall(head(extra=fields))
                    assert response(conn)[0] == wanted
                    closed(conn)
            checks.append('CL/TE ambiguity, duplicate transfer coding and unsupported expectations rejected')
            for partial in [b'1',b'1\r\n',b'2\r\na',b'1\r\na\r',b'0\r\nX: y\r\n']:
                with instance.connect() as conn:
                    conn.sendall(head()+partial);conn.shutdown(socket.SHUT_WR)
                    assert response(conn)[0] == 400
                    closed(conn)
            checks.append('premature EOF at size/data/delimiter/trailer phases')
            with instance.connect() as conn:
                conn.sendall(head()+b'1;')
                time.sleep(.1);conn.sendall(b'x')
                time.sleep(.1);conn.sendall(b'=')
                assert response(conn)[0] == 408
                closed(conn)
            checks.append('progress does not extend the total body deadline')
            abandoned = instance.connect();abandoned.sendall(head()+b'4\r\na');abandoned.close()
            with instance.connect() as conn:
                conn.sendall(request('/id'));assert response(conn)[0] == 200
            held = instance.connect();held.sendall(head()+b'4\r\na')
            time.sleep(.02)
            with instance.connect() as conn:
                conn.sendall(request('/id'));assert response(conn)[0] == 200
            instance.finish()
            closed(held);held.close()
            events = instance.events()
            assert [e['received'] for e in events[:len(expected_received)]] == expected_received
            assert all(e['outcome'] == 'Completed' for e in events[:len(expected_received)])
            checks.append('exact wire-byte metrics before pipeline handoff; disconnect/shutdown release parked readers')
    print(json.dumps({'valid': True, 'sanitizer': args.sanitize or 'none', 'checks': checks}, indent=2))


if __name__ == '__main__':
    main()
