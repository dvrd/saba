#!/usr/bin/env python3
"""Independent raw HTTP2 multiplexing, ownership and lifetime-budget gate."""
import sys; sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent))
import harness_env
import argparse
import json
import os
import shutil
from pathlib import Path
from http2_connect import exercise, run

HERE = Path(__file__).resolve().parent
SHARED = harness_env.shared()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--odin', type=Path, default=Path(harness_env.odin()))
    parser.add_argument('--sanitize', choices=('address', 'thread'), default=harness_env.sanitizer())
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    env = os.environ.copy()
    env['GO111MODULE'] = 'off'
    go = harness_env.go()
    work = harness_env.workdir('saba-http2-multiplex-')
    try:
        exercise_all(args, env, go, work)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def exercise_all(args, env, go, work):
    binary, peer = work / 'server', work / 'peer'
    sanitize = [f'-sanitize:{args.sanitize}'] if args.sanitize else []
    records = [run([go, 'build', '-o', peer, HERE / 'http2_multiplex/peer.go'], env),
               run([args.odin, 'build', HERE / 'http2_multiplex', f'-collection:shared={SHARED}',
                    '-vet', '-warnings-as-errors', *sanitize, f'-out:{binary}'], env)]
    records += exercise(binary, [HERE / 'testdata/tls/localhost.pem', HERE / 'testdata/tls/rsa2048.pem'],
                        [lambda port: [peer, f'127.0.0.1:{port}']], env)
    assert 'created=23 disposed=23 cancelled=3' in records[-1]['stdout'], records[-1]
    records += exercise(binary, [HERE / 'testdata/tls/localhost.pem', HERE / 'testdata/tls/rsa2048.pem'],
                        [lambda port: [peer, f'127.0.0.1:{port}', 'drain']], env)
    result = dict(passed=True, sanitizer=args.sanitize, records=records)
    if args.report:
        args.report.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(dict(passed=True, sanitizer=args.sanitize, records=len(records))))

if __name__ == '__main__':
    main()
