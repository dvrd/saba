#!/usr/bin/env python3
"""Build and check two synthetic HTTP/3 phase profiles on owned loopback only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
HTTP = HERE.parents[2]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sources():
    return {str(p.relative_to(HTTP)): digest(p)
            for p in HTTP.rglob('*') if p.is_file() and p.suffix in ('.odin', '.py', '.pem')}


def profile(binary, python, name, environment):
    command = [str(binary), str(HERE.parent / 'rsa2048-valid.pem'),
               str(HERE.parent / 'rsa2048.pem')]
    if name == 'progress':
        command.append('progress')
    server = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True, env=environment)
    try:
        with selectors.DefaultSelector() as selected:
            selected.register(server.stdout, selectors.EVENT_READ)
            assert selected.select(5), 'owned server did not announce ready'
        line = server.stdout.readline()
        assert line.startswith('READY '), line
        port = int(line.split()[1])
        peer = subprocess.run([python, str(HERE / 'peer.py'), '--port', str(port),
                               '--profile', name], capture_output=True, text=True,
                              env=environment, timeout=12)
        output, errors = server.communicate(timeout=20)
        result = dict(profile=name, response_budget_ms=400 if name == 'isolation' else (3000 if name == 'progress' else 400),
                      peer_wait_seconds=5, peer_exit=peer.returncode,
                      server_exit=server.returncode, peer_stdout=peer.stdout,
                      peer_stderr=peer.stderr, server_stdout=line + output,
                      server_stderr=errors)
        result['passed'] = peer.returncode == server.returncode == 0
        return result
    finally:
        if server.poll() is None:
            server.terminate()
            server.communicate(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--odin', type=Path, required=True)
    parser.add_argument('--python', default=sys.executable)
    parser.add_argument('--sanitize', choices=('address', 'thread'))
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    environment = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
    before = sources()
    report = dict(source_sha256=before, profiles=[])
    with tempfile.TemporaryDirectory(prefix='http3-phases-') as work:
        binary = Path(work) / 'server'
        command = [str(args.odin.resolve()), 'build', str(HERE),
                   '-collection:shared=' + str(HTTP.parent), '-thread-count:1',
                   '-warnings-as-errors', '-vet', '-out:' + str(binary)]
        if args.sanitize:
            command.append('-sanitize:' + args.sanitize)
        build = subprocess.run(command, capture_output=True, text=True,
                               env=environment, timeout=120)
        report['build'] = dict(command=command, exit_code=build.returncode,
                               stdout=build.stdout, stderr=build.stderr)
        if build.returncode == 0:
            report['binary_sha256'] = digest(binary)
            for name in ('isolation', 'progress', 'stream-budget'):
                result = profile(binary, args.python, name, environment)
                report['profiles'].append(result)
                if not result['passed']:
                    break
        report['source_unchanged'] = sources() == before
        report['passed'] = (build.returncode == 0 and report['source_unchanged']
                            and len(report['profiles']) == 3
                            and all(row['passed'] for row in report['profiles']))
        args.report.write_text(json.dumps(report, indent=2) + '\n')
    assert report['passed'], str(args.report)
    print('owned phase isolation and small-window progress pass')


if __name__ == '__main__':
    main()
