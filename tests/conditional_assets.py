#!/usr/bin/env python3
"""HEAD/cache validation through the public facade and owned loopback sockets."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from async_server import SABA, exact, headers, server


def exchange(instance, path, method='GET', fields=()):
    with instance.connect() as conn:
        wire = f'{method} {path} HTTP/1.1\r\nHost: localhost\r\n'
        wire += ''.join(f'{name}: {value}\r\n' for name, value in fields) + '\r\n'
        conn.sendall(wire.encode('latin1'))
        head = headers(conn)
        status = int(head.split(b' ', 2)[1])
        values = dict(line.decode('latin1').split(': ', 1)
                      for line in head.split(b'\r\n')[1:] if b': ' in line)
        body = b'' if method == 'HEAD' or status == 304 else exact(conn, int(values['Content-Length']))
        assert conn.recv(1) == b'', 'unexpected body bytes after HEAD/304 or framing error'
        return status, values, body


def check_production(binary, web):
    with server(binary, web) as instance:
        for path in ['/assets/data.txt', '/assets/empty.txt', '/view.js', '/',
                     '/__saba/dom.js', '/__saba/page-entry.js']:
            status, meta, body = exchange(instance, path)
            assert status == 200
            assert meta['Cache-Control'] == 'no-cache'
            tag = '"' + hashlib.sha256(body).hexdigest() + '"'
            assert meta['ETag'] == tag, path
            head_status, head_meta, head_body = exchange(instance, path, 'HEAD')
            assert (head_status, head_meta, head_body) == (200, meta, b''), path
            for method in ['GET', 'HEAD']:
                for condition in [tag, 'W/' + tag, '"miss", W/' + tag, '*']:
                    code, not_modified, content = exchange(instance, path, method, [('If-None-Match', condition)])
                    assert code == 304 and not content, (path, condition)
                    assert not_modified['ETag'] == tag and not_modified['Cache-Control'] == 'no-cache'
                    assert 'Content-Length' not in not_modified and 'Transfer-Encoding' not in not_modified
                code, repeated, _ = exchange(instance, path, method,
                    [('If-None-Match', '"miss"'), ('if-none-match', tag)])
                assert code == 304 and repeated['ETag'] == tag
                for fields in [[('If-None-Match', '"miss"')],
                               [('If-None-Match', tag + ', invalid')],
                               [('If-None-Match', '*'), ('If-None-Match', tag)]]:
                    assert exchange(instance, path, method, fields)[0] == 200
        # A production mount retains its startup snapshot until rebuilt/restarted.
        original = exchange(instance, '/assets/data.txt')
        (web/'assets/data.txt').write_bytes(b'new bytes')
        assert exchange(instance, '/assets/data.txt') == original
        assert exchange(instance, '/assets/data.txt', fields=[('If-None-Match', original[1]['ETag'])])[0] == 304
        for method in ['GET', 'HEAD']:
            for path in ['/assets/%2e%2e/index.html', '/assets/private.jsx',
                         '/assets/escape.txt', '/%2e%2e/view.js', '/private.jsx']:
                assert exchange(instance, path, method, [('If-None-Match', '*')])[0] == 404, path
    with server(binary, web) as instance:
        current = exchange(instance, '/assets/data.txt', fields=[('If-None-Match', original[1]['ETag'])])
        assert current[0] == 200 and current[2] == b'new bytes'
        assert current[1]['ETag'] != original[1]['ETag']


def check_development(binary, web):
    with server(binary, web, development=True) as instance:
        for path in ['/assets/data.txt', '/view.js', '/']:
            get = exchange(instance, path, fields=[('If-None-Match', '*')])
            assert get[0] == 200 and get[1]['Cache-Control'] == 'no-store'
            assert 'ETag' not in get[1]
            head = exchange(instance, path, 'HEAD', [('If-None-Match', '*')])
            assert head == (200, get[1], b''), path
        for path, file, replacement in [
            ('/assets/data.txt', web/'assets/data.txt', b'changed asset'),
            ('/view.js', web/'view.jsx', b'export default function View(){ return <p>changed module</p>; }'),
            ('/', web/'index.html', b'<html><head></head><body>changed shell<!--saba:page--></body></html>'),
        ]:
            previous = exchange(instance, path)[2]
            file.write_bytes(replacement)
            current = exchange(instance, path, fields=[('If-None-Match', '*')])
            assert current[0] == 200 and current[2] != previous
            assert b'changed' in current[2]
            assert exchange(instance, path, 'HEAD')[1] == current[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--odin', default=os.environ.get('ODIN') or shutil.which('odin') or str(SABA.parents[1]/'odin'))
    parser.add_argument('--sanitize', choices=['address'])
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='saba-cache-test-') as work:
        root = Path(work); web = root/'web'
        (web/'assets').mkdir(parents=True); (web/'pages').mkdir()
        (web/'assets/data.txt').write_bytes(b'abc')
        (web/'assets/empty.txt').write_bytes(b'')
        (web/'assets/private.jsx').write_text('private')
        (root/'outside.txt').write_text('secret')
        (web/'assets/escape.txt').symlink_to(root/'outside.txt')
        (web/'view.jsx').write_text('export default function View(){ return <div>hello</div>; }')
        (web/'pages/index.jsx').write_text('export default function Home(){ return <h1>Home</h1>; }')
        (web/'index.html').write_text('<html><head></head><body><!--saba:page--></body></html>')
        binary = root/'server'
        command = [args.odin, 'build', str(SABA/'testdata/async'), '-warnings-as-errors', '-out:'+str(binary)]
        if args.sanitize:
            command.append('-sanitize:'+args.sanitize)
        subprocess.run(command, check=True, timeout=60)
        check_production(binary, web)
        check_development(binary, web)
    print(json.dumps({'valid': True, 'sanitizer': args.sanitize or 'none', 'checks': [
        'GET/HEAD metadata parity and headers-only HEAD on assets, empty files, modules, pages and runtimes',
        'independent SHA256 ETag, weak/list/wildcard/repeated conditions, malformed non-matches',
        '304 headers-only framing and validator/cache policy retention',
        'production snapshot and restart invalidation',
        'development no-store and immediate asset/module/shell freshness, including HEAD',
        'conditional requests preserve traversal, private JSX and symlink containment checks',
    ]}, indent=2))


if __name__ == '__main__':
    main()
