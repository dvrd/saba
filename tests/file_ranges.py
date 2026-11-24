#!/usr/bin/env python3
"""Owned file range wire matrix; no public endpoints or live credentials."""
import sys; sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent))
import harness_env
import argparse
import concurrent.futures
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
from async_server import headers
from keep_alive import request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--odin', default=harness_env.odin())
    parser.add_argument('--sanitize', choices=['address', 'thread'])
    parser.add_argument('--workers', type=int, choices=[1, 4], default=1)
    args = parser.parse_args()
    checks = []
    with tempfile.TemporaryDirectory(prefix='saba-file-ranges-') as work:
        work = Path(work); root = work/'files'; root.mkdir()
        normal = bytes(i % 251 for i in range(131077))
        (root/'normal.bin').write_bytes(normal); (root/'empty.txt').write_bytes(b'')
        large = bytes(range(256))*65536
        (root/'large.bin').write_bytes(large)
        with (root/'slow.bin').open('wb') as stream:
            stream.truncate(256*1024*1024)
        (root/'private.jsx').write_text('private')
        (work/'outside.txt').write_text('secret')
        (root/'escape.txt').symlink_to(work/'outside.txt')
        (root/'outside').symlink_to(work, target_is_directory=True)
        binary = work/'server'
        command = [args.odin, 'build', str(Path(__file__).resolve().parents[1]/'testdata/file_range'),
                   '-warnings-as-errors', harness_env.collection(), '-out:'+str(binary)]
        if args.sanitize:
            command.append('-sanitize:'+args.sanitize)
        subprocess.run(command, check=True, timeout=60)
        env = dict(os.environ, SABA_FILE_ROOT=str(root), SABA_FILE_WORKERS=str(args.workers))
        proc = subprocess.Popen([str(binary)], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True)
        output = queue.Queue()
        reader = threading.Thread(target=lambda: [output.put(line.strip()) for line in proc.stdout], daemon=True)
        reader.start()
        try:
            ready = output.get(timeout=8); assert ready.startswith('ready '), ready
            port = int(ready.split()[1])

            def fetch(path='/normal.bin', fields=(), method='GET'):
                with contextlib.closing(http.client.HTTPConnection('127.0.0.1', port, timeout=5)) as conn:
                    conn.putrequest(method, path)
                    for name, value in fields:
                        conn.putheader(name, value)
                    conn.endheaders(); reply = conn.getresponse()
                    return reply.status, dict(reply.getheaders()), reply.read()

            def idle():
                until = time.monotonic()+5
                while True:
                    status, _, body = fetch('/stats')
                    live, allocated, released, fds = map(int, body.split())
                    if live == 0 and allocated == released:
                        return fds
                    assert time.monotonic() < until, (live, allocated, released)
                    time.sleep(.01)

            baseline = idle()
            status, fields, body = fetch()
            assert status == 200 and body == normal and fields['Content-Length'] == str(len(normal))
            assert fields['ETag'] == '"fixture-v1"' and fields['Accept-Ranges'] == 'bytes'
            assert 'Transfer-Encoding' not in fields
            cases = [('bytes=0-0', 0, 1), ('bytes=31-127', 31, 128), ('bytes=131070-', 131070, len(normal)),
                     ('bytes=-17', len(normal)-17, len(normal)), ('bytes=-999999999999999999999999', 0, len(normal)),
                     ('bytes=0-999999999999999999999999', 0, len(normal))]
            for value, first, end in cases:
                status, fields, body = fetch(fields=[('Range', value)])
                assert status == 206 and body == normal[first:end], value
                assert fields['Content-Range'] == f'bytes {first}-{end-1}/{len(normal)}'
                assert fields['Content-Length'] == str(end-first) and 'Transfer-Encoding' not in fields
            checks.append('full/fixed/open/suffix/overflow ranges have independently decoded exact bytes and metadata')
            for value in ['bytes=999999-', 'bytes=-0', 'bytes=99999999999999999999999-']:
                status, fields, body = fetch(fields=[('Range', value)])
                assert status == 416 and body == b'' and fields['Content-Range'] == f'bytes */{len(normal)}'
            status, fields, body = fetch('/empty.txt', [('Range', 'bytes=0-')])
            assert status == 416 and body == b'' and fields['Content-Range'] == 'bytes */0'
            status, fields, body = fetch('/empty.txt')
            assert status == 200 and body == b'' and fields['Content-Length'] == '0'
            checks.append('unsatisfiable and empty file responses use exact 416/200 framing')
            for value in ['bytes=0-1,5-7', 'items=0-1', 'bytes=8-3', 'bytes=0 -1', 'bytes=0-xx']:
                status, _, body = fetch(fields=[('Range', value)])
                assert status == 200 and body == normal, value
            status, _, body = fetch(fields=[('Range', 'bytes=0-1'), ('Range', 'bytes=4-5')])
            assert status == 200 and body == normal
            for condition, expected in [('"fixture-v1"', 206), ('W/"fixture-v1"', 200), ('"old"', 200),
                                        ('Sat, 01 Jan 2000 00:00:00 GMT', 200)]:
                status, _, body = fetch(fields=[('Range', 'bytes=4-7'), ('If-Range', condition)])
                assert status == expected and body == (normal[4:8] if status == 206 else normal)
            status, fields, body = fetch(fields=[('Range', 'bytes=4-7'), ('If-None-Match', 'W/"fixture-v1"')])
            assert status == 304 and body == b'' and 'Content-Length' not in fields
            status, fields, body = fetch('/untagged/normal.bin', [('Range', 'bytes=4-7'), ('If-Range', '"fixture-v1"')])
            assert status == 200 and body == normal and fields['Cache-Control'] == 'no-store' and 'ETag' not in fields
            checks.append('bounded unsupported policy and conditional precedence/strong If-Range fallback')
            for value in ['bytes=4-7', 'bytes=999999-']:
                status, fields, body = fetch(fields=[('Range', value)], method='HEAD')
                assert status == 200 and body == b'' and fields['Content-Length'] == str(len(normal))
                assert 'Content-Range' not in fields
            for path in ['/../outside.txt', '/%2e%2e/outside.txt', '/%2fetc/passwd', '/private.jsx', '/escape.txt', '/outside/outside.txt']:
                status, _, _ = fetch(path); assert status == 404, path
            assert fetch('/reject')[0] == 500
            assert fetch(method='POST')[0] == 405
            checks.append('HEAD ignores Range and rooted traversal/private/symlink/file-size/method policies hold')
            with contextlib.closing(http.client.HTTPConnection('127.0.0.1', port, timeout=5)) as conn:
                conn.request('GET', '/large.bin', headers={'Range': 'bytes=12345-15000000'})
                reply = conn.getresponse(); digest = hashlib.sha256(); total = 0
                while data := reply.read(32768):
                    digest.update(data); total += len(data)
                assert reply.status == 206 and total == 15000001-12345
                assert digest.digest() == hashlib.sha256(large[12345:15000001]).digest()
                conn.request('GET', '/fast'); assert conn.getresponse().read() == b'ok'
            checks.append('14 MiB range in configured 16 KiB storage and keep-alive reuse')
            def parallel(n):
                first = n*73
                status, _, body = fetch(fields=[('Range', f'bytes={first}-{first+999}')])
                assert status == 206 and body == normal[first:first+1000]
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
                list(executor.map(parallel, range(40)))
            for _ in range(12):
                with socket.create_connection(('127.0.0.1', port), timeout=5) as conn:
                    conn.sendall(request('/slow.bin')); assert headers(conn).startswith(b'HTTP/1.1 200 ')
            assert idle() == baseline
            with socket.create_connection(('127.0.0.1', port), timeout=5) as conn:
                conn.sendall(request('/badhead')); assert headers(conn).startswith(b'HTTP/1.1 500 ')  # rejected head answers 500
            assert idle() == baseline
            checks.append('concurrent ranges, repeated disconnect and rejected head release all tracked bytes/descriptors')
            with socket.create_connection(('127.0.0.1', port), timeout=5) as slow:
                slow.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
                slow.sendall(request('/slow.bin')); headers(slow)
                assert fetch('/fast')[2] == b'ok'
                time.sleep(.5)
                assert idle() == baseline  # descriptors are measured inside the server process
            assert idle() == baseline
            checks.append('slow-reader write timeout releases producer while cheap route stays responsive')
            with socket.create_connection(('127.0.0.1', port), timeout=5) as slow:
                slow.sendall(request('/slow.bin')); headers(slow)
                proc.stdin.write('s'); proc.stdin.flush(); proc.wait(timeout=8)
            reader.join(timeout=2)
            error = proc.stderr.read()
            assert proc.returncode == 0, error
            assert 'ERROR: AddressSanitizer' not in error and 'WARNING: ThreadSanitizer' not in error, error
            assert output.get(timeout=2) == 'stopped'
            checks.append('shutdown with active file stream releases every producer and buffer')
        finally:
            if proc.poll() is None:
                proc.kill(); proc.wait(timeout=5)
            for pipe in [proc.stdin, proc.stdout, proc.stderr]:
                pipe.close()
    print(json.dumps({'checks': checks, 'workers': args.workers, 'sanitize': args.sanitize}, indent=2))


if __name__ == '__main__':
    main()
