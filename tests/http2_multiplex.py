#!/usr/bin/env python3
"""Independent raw HTTP2 multiplexing, ownership and lifetime-budget gate."""
import argparse
import json
import os
from pathlib import Path
from http2_connect import exercise, run

HERE = Path(__file__).resolve().parent
SHARED = HERE.parents[1]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--odin', type=Path, required=True)
    parser.add_argument('--sanitize', choices=('address', 'thread'), default='address')
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    env = os.environ.copy()
    env['PATH'] = '/opt/homebrew/opt/llvm@22/bin:' + env.get('PATH', '')
    env['GO111MODULE'] = 'off'
    prefix = Path(f'/tmp/webtools392-h2-{args.sanitize}-{os.getpid()}')
    binary, peer = prefix.with_suffix('.server'), prefix.with_suffix('.peer')
    records = [run(['/opt/homebrew/bin/go', 'build', '-o', peer, HERE / 'http2_multiplex/peer.go'], env),
               run([args.odin, 'build', HERE / 'http2_multiplex', f'-collection:shared={SHARED}',
                    '-vet', '-warnings-as-errors', f'-sanitize:{args.sanitize}', f'-out:{binary}'], env)]
    records += exercise(binary, [HERE / 'testdata/tls/localhost.pem', HERE / 'testdata/tls/rsa2048.pem'],
                        [lambda port: [peer, f'127.0.0.1:{port}']], env)
    assert 'created=23 disposed=23 cancelled=3' in records[-1]['stdout'], records[-1]
    records += exercise(binary, [HERE / 'testdata/tls/localhost.pem', HERE / 'testdata/tls/rsa2048.pem'],
                        [lambda port: [peer, f'127.0.0.1:{port}', 'drain']], env)
    result = dict(passed=True, sanitizer=args.sanitize, records=records)
    args.report.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))

if __name__ == '__main__':
    main()
