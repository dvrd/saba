#!/usr/bin/env python3
"""Owned native Saba HTTPS interoperability; independent Go/OpenSSL, public testkeys only."""
import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import queue
import select
import shlex
import shutil
import subprocess
import tempfile
import threading
import time

import sys; sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent))
import harness_env
import shutil

HERE = Path(__file__).resolve().parent
SOURCE = HERE / 'https80'


def go_root(go):
    return Path(subprocess.run([str(go), 'env', 'GOROOT'], capture_output=True, text=True, timeout=30).stdout.strip())


def run(command, timeout=90, env=None):
    started = time.monotonic()
    result = subprocess.run([str(item) for item in command], capture_output=True,
                            text=True, timeout=timeout, env=env)
    record = dict(command=[str(item) for item in command], returncode=result.returncode,
                  stdout=result.stdout, stderr=result.stderr,
                  seconds=time.monotonic()-started)
    assert result.returncode == 0, record
    assert 'ERROR: AddressSanitizer' not in result.stderr, record
    assert 'WARNING: ThreadSanitizer' not in result.stderr, record
    return record


def input_file(path):
    parts = path.parts
    if any(part in {'.git', '__pycache__', 'evidence', 'binaries', '.webtools-worktrees',
                    'odin-cache', '.odin-cache', '.cache'} for part in parts):
        return False
    # shared/http/v3 is not an input of this server. Saba speaks HTTP/2.
    if any(parts[index] == 'http' and parts[index + 1] == 'v3' for index in range(len(parts) - 1)):
        return False
    if path.name.startswith('.#') or path.name.endswith('~') or path.suffix in {
            '.o', '.obj', '.ll', '.bc', '.pdb', '.dwo', '.tmp', '.swp', '.bin'}:
        return False
    return True


def input_directories(shared, sdk):
    # Packages this server compiles. The rest of shared/ is not an input.
    return [
        shared/'saba', shared/'http', shared/'websocket', shared/'surf',
        shared/'async', shared/'kakunou',
        sdk/'core', sdk/'base/runtime',
        sdk/'tests/core/crypto/tls/credentials/testdata',
    ]


def input_hashes(shared, sdk):
    paths = {Path(__file__).resolve()}
    for directory in input_directories(shared, sdk):
        if directory.is_dir():
            paths.update(path for path in directory.rglob('*') if path.is_file() and input_file(path))
    hashed = {}
    for path in sorted(paths):
        try:
            data = path.read_bytes()
        except FileNotFoundError:
            if path.suffix == '.bin':
                continue
            raise
        hashed[str(path)] = hashlib.sha256(data).hexdigest()
    return hashed


class Server:
    def __init__(self, binary, mode, cert, key, env=None):
        self.process = subprocess.Popen([str(binary), mode, str(cert), str(key)],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True, env=env)
        self.lines, self.pending, self.buffered = [], queue.Queue(), []
        self.finished = self.joined = False
        def read():
            for line in self.process.stdout:
                value = line.strip()
                self.lines.append(value)
                self.pending.put(value)
            self.pending.put(None)
        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()
        self.port = int(self.line('READY ').split()[1])

    @property
    def endpoint(self):
        return '127.0.0.1:' + str(self.port)

    def line(self, prefix, timeout=15):
        until = time.monotonic()+timeout
        while True:
            for index, value in enumerate(self.buffered):
                if value.startswith(prefix):
                    return self.buffered.pop(index)
            remaining = until-time.monotonic()
            assert remaining > 0, (prefix, self.lines)
            value = self.pending.get(timeout=remaining)
            assert value is not None, (prefix, self.lines, self.process.poll(),
                                       self.process.stderr.read())
            self.buffered.append(value)

    def command(self, value):
        self.process.stdin.write(value)
        self.process.stdin.flush()

    def metrics(self):
        self.command('m')
        parts = self.line('METRICS ').split()
        return dict(zip(['active', 'valid', 'handled', 'handshakes', 'closed',
                         'write_waits', 'partial_writes', 'leases', 'started', 'completed'],
                        [parts[1], *parts[2:]]))

    def wait_metrics(self, predicate, timeout=8):
        until = time.monotonic()+timeout
        while True:
            metrics = self.metrics()
            if predicate(metrics):
                return metrics
            assert time.monotonic() < until, (metrics, self.lines)
            time.sleep(.005)

    def idle(self):
        metrics = self.wait_metrics(lambda value: int(value['active']) == 0)
        assert int(metrics['leases']) == 0, metrics
        assert int(metrics['handshakes']) == int(metrics['closed']), metrics
        return metrics

    def join(self, stop=True):
        if stop:
            self.command('s')
        assert self.line('FINISHED ').split()[1] == 'true'
        self.finished = True
        self.command('j')
        parts = self.line('JOINED ').split()
        assert parts[1] == 'true', parts
        values = dict(zip(['handled', 'handshakes', 'successes', 'closed', 'live_bytes',
                           'write_waits', 'partial_writes', 'leases'], map(int, parts[2:])))
        assert values['handshakes'] == values['closed'], values
        assert values['live_bytes'] == values['leases'] == 0, values
        self.joined = True
        # The child stays alive here, so process exit cannot hide listener/stream leaks.
        lsof = shutil.which('lsof') or '/usr/sbin/lsof'
        if Path(lsof).is_file():
            sockets = subprocess.run([lsof, '-nP', '-a', '-p', str(self.process.pid),
                                      '-iTCP', '-Fn'], capture_output=True, text=True, timeout=5)
            assert sockets.returncode in (0, 1), sockets.stderr
            assert not sockets.stdout.strip(), sockets.stdout
            values['tcp_descriptors_after_join'] = 0
        return values

    def close(self):
        if self.process.poll() is None:
            if not self.joined:
                self.join()
            self.command('q')
        try:
            self.process.wait(timeout=8)
            self.reader.join(timeout=2)
            stdout, stderr = '', self.process.stderr.read()
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            self.reader.join(timeout=2)
            stdout, stderr = '', self.process.stderr.read()
            raise AssertionError(('server exit timeout', self.lines, stdout, stderr))
        self.reader.join(timeout=2)
        assert self.process.returncode == 0, (self.lines, stderr)
        assert 'ERROR: AddressSanitizer' not in stderr, stderr
        assert 'WARNING: ThreadSanitizer' not in stderr, stderr
        return dict(lines=self.lines, stderr=stderr)


def peer_wait(process, prefix):
    assert select.select([process.stdout], [], [], 8)[0], ('peer readiness', process.poll())
    line = process.stdout.readline().strip()
    assert line.startswith(prefix), (line, process.poll())
    return line


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--odin', type=Path, default=Path(harness_env.odin()))
    parser.add_argument('--go', type=Path)
    parser.add_argument('--go-root', type=Path)
    parser.add_argument('--openssl', type=Path)
    parser.add_argument('--shared', type=Path, default=Path(harness_env.shared()))
    parser.add_argument('--sdk-root', type=Path)
    parser.add_argument('--sanitize', choices=['address', 'thread'], default=harness_env.sanitizer())
    parser.add_argument('--report', type=Path)
    parser.add_argument('--evidence-dir', type=Path, help='Retain built peer/native binaries here')
    parser.add_argument('--case', help='Run only cases whose name starts with this value')
    args = parser.parse_args()
    args.go = args.go or Path(harness_env.go())
    args.go_root = args.go_root or go_root(args.go)
    if not args.openssl:
        located = shutil.which('openssl')
        if not located:
            harness_env.skip('openssl is not available')
        args.openssl = Path(located)
    for tool in ('pkg-config', 'clang'):
        if not shutil.which(tool):
            harness_env.skip(tool + ' is not available for the OpenSSL peer')
    if subprocess.run(['pkg-config', '--exists', 'openssl']).returncode != 0:
        harness_env.skip('pkg-config has no openssl package for the OpenSSL peer')
    compiler = args.odin.resolve()
    sdk = args.sdk_root.resolve() if args.sdk_root else Path(
        run([compiler, 'root'])['stdout'].strip())
    fixtures = harness_env.TLS
    cert, key = fixtures/'rsa2048-valid.pem', fixtures/'rsa2048.pem'
    report = dict(passed=False, sanitizer=args.sanitize,
                  scope='Darwin/native HTTP1 Saba HTTPS correctness; owned peers; no Mesa integration or performance certification',
                  compiler_sha256=hashlib.sha256(compiler.read_bytes()).hexdigest(), cases=[])
    env = dict(os.environ, GOROOT=str(args.go_root), GOTOOLCHAIN='local', GOPROXY='off',
               GOSUMDB='off', CGO_ENABLED='0', GO111MODULE='off')
    def selected(name):
        return not args.case or name.startswith(args.case)
    inputs = input_hashes(args.shared.resolve(), sdk)
    report['input_sha256'] = inputs
    if args.evidence_dir:
        args.evidence_dir.mkdir(parents=True, exist_ok=True)
    work = contextlib.nullcontext(str(args.evidence_dir)) if args.evidence_dir else tempfile.TemporaryDirectory(prefix='saba-https80-')
    try:
        report['compiler'] = run([compiler, 'version'])
        report['go'] = run([args.go, 'version'], env=env)
        report['openssl'] = run([args.openssl, 'version'])
        report['sources'] = {str(path.relative_to(SOURCE)): hashlib.sha256(path.read_bytes()).hexdigest()
                             for path in SOURCE.rglob('*') if path.is_file()}
        with work as temporary:
            temp = Path(temporary)
            native, go, openssl = temp/'server', temp/'go-peer', temp/'openssl-peer'
            report['builds'] = [run([compiler, 'build', SOURCE,
                                    '-collection:shared='+str(args.shared.resolve()),
                                    # No -vet: the facade pulls in shared:kessel, which does not pass it.
                                    '-thread-count:1', '-warnings-as-errors',
                                    *(['-sanitize:'+args.sanitize] if args.sanitize else []), '-out:'+str(native)]),
                                run([args.go, 'build', '-o', go, SOURCE/'peer.go'], env=env)]
            flags = shlex.split(run(['pkg-config', '--cflags', '--libs', 'openssl'])['stdout'])
            report['builds'].append(run(['clang', '-Wall', '-Wextra', '-Werror',
                                        SOURCE/'openssl_client.c', '-o', openssl, *flags]))
            report['binaries'] = {path.name: dict(path=str(path),
                sha256=hashlib.sha256(path.read_bytes()).hexdigest())
                for path in [native, go, openssl]}
            for mode in ['core', 'application', 'facade', 'plain']:
                name = mode+'-trusted'
                if not selected(name):
                    continue
                server = Server(native, mode, cert, key)
                case = dict(name=name, passed=False)
                report['cases'].append(case)
                try:
                    peer_mode = 'plain' if mode == 'plain' else 'trusted'
                    case['peer'] = run([go, server.endpoint, cert, peer_mode])
                    metrics = server.idle()
                    assert int(metrics['handled']) == 4, metrics
                    case['metrics'] = metrics
                    case['joined'] = server.join()
                    case['passed'] = True
                finally:
                    case['server'] = server.close()
            name = 'core-independent-matrix'
            if selected(name):
                server = Server(native, 'core', cert, key)
                case = dict(name=name, peers=[], passed=False)
                report['cases'].append(case)
                try:
                    for client in [go, openssl]:
                        for mode in ['trust', 'hostname', 'expired', 'before', 'trusted']:
                            before = server.idle()
                            anchor = fixtures/'rsa4096-valid.pem' if mode == 'trust' else cert
                            peer = run([client, server.endpoint, anchor, mode])
                            after = server.idle()
                            if mode != 'trusted':
                                assert before['handled'] == after['handled'], (before, after)
                            case['peers'].append(dict(client=client.name, mode=mode, **peer))
                    for mode in ['fragment', 'helpers', 'timeout', 'backpressure']:
                        case['peers'].append(dict(mode=mode,
                                                  **run([go, server.endpoint, cert, mode])))
                        metrics = server.idle()
                        if mode == 'backpressure':
                            assert int(metrics['write_waits']) > 0, metrics
                            assert int(metrics['partial_writes']) > 0, metrics
                        case['metrics'] = metrics
                    case['joined'] = server.join()
                    case['passed'] = True
                finally:
                    case['server'] = server.close()
            for mode in ['hold-handshake', 'hold-http', 'drain-body', 'deferred',
                         'deferred-pipeline', 'wss', 'wss-stop']:
                name = 'shutdown-'+mode
                if not selected(name):
                    continue
                web = temp / ('web-' + mode)
                if web.exists():
                    shutil.rmtree(web)
                web.mkdir()
                (web/'view.jsx').write_text('export default function View(){return <p>first</p>}')
                native_mode = 'development' if mode.startswith('wss') else 'core'
                environment = dict(os.environ, HTTPS80_WEB=str(web))
                server = Server(native, native_mode, cert, key, env=environment)
                case = dict(name=name, passed=False)
                report['cases'].append(case)
                process = subprocess.Popen([str(go), server.endpoint, str(cert), mode],
                                           stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                           stderr=subprocess.PIPE, text=True)
                try:
                    peer_wait(process, 'HELD')
                    metrics = server.wait_metrics(lambda value: int(value['active']) > 0)
                    case['held_metrics'] = metrics
                    if mode.startswith('deferred'):
                        server.line('DEFERRED')
                        # Give the pre-header continuation its actual suspended
                        # peer-read turn before signalling Ready from another thread.
                        time.sleep(.05)
                        server.command('r');server.line('RELEASED')
                        process.stdin.write('release\n');process.stdin.flush()
                        stdout, stderr = process.communicate(timeout=10)
                        assert process.returncode == 0, (stdout, stderr)
                        case['peer'] = dict(stdout=stdout, stderr=stderr)
                        case['metrics'] = server.idle()
                        case['joined'] = server.join()
                    elif mode == 'wss':
                        (web/'view.jsx').write_text('export default function View(){return <p>changed</p>}')
                        stdout, stderr = process.communicate(timeout=10)
                        assert process.returncode == 0, (stdout, stderr)
                        case['peer'] = dict(stdout=stdout, stderr=stderr)
                        case['metrics'] = server.idle()
                        case['joined'] = server.join()
                    elif mode == 'drain-body':
                        server.wait_metrics(lambda value: int(value['started']) > 0)
                        server.command('d');server.line('DRAIN')
                        process.stdin.write('release\n');process.stdin.flush()
                        stdout, stderr = process.communicate(timeout=10)
                        assert process.returncode == 0, (stdout, stderr)
                        case['peer'] = dict(stdout=stdout, stderr=stderr)
                        case['joined'] = server.join(stop=False)
                    else:
                        case['joined'] = server.join()
                        stdout, stderr = process.communicate(timeout=10)
                        assert process.returncode == 0, (stdout, stderr)
                        case['peer'] = dict(stdout=stdout, stderr=stderr)
                    case['passed'] = True
                finally:
                    if process.poll() is None:
                        process.kill();process.communicate()
                    case['server'] = server.close()
            assert report['cases'], 'No cases selected'
            after = input_hashes(args.shared.resolve(), sdk)
            report['inputs_unchanged'] = after == inputs
            if not report['inputs_unchanged']:
                for path in sorted(set(inputs) ^ set(after)):
                    print('INPUT_KEY', path)
                for path in sorted(set(inputs) & set(after)):
                    if inputs[path] != after[path]:
                        print('INPUT_CHG', path)
            assert report['inputs_unchanged'], 'Source inputs changed during the wire gate'
            assert hashlib.sha256(compiler.read_bytes()).hexdigest() == report['compiler_sha256']
            report['passed'] = all(case['passed'] for case in report['cases'])
    finally:
        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps(report, indent=2)+'\n')
        elif not report['passed']:
            print(json.dumps([case for case in report['cases'] if not case['passed']], indent=2)[-6000:])
    print(json.dumps(dict(passed=True, cases=len(report['cases']), report=str(args.report))))


if __name__ == '__main__':
    main()
