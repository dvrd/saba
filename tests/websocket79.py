#!/usr/bin/env python3
"""Owned independent application WS/WSS policy, framing and lifecycle verification."""
import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import queue
import select
import shutil
import subprocess
import tempfile
import threading
import time

HERE = Path(__file__).resolve().parent
SOURCE = HERE/'websocket79'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def snapshot(shared, sdk):
    paths = {Path(__file__).resolve()}
    for directory in [shared, sdk/'core', sdk/'base/runtime',
                      sdk/'tests/core/crypto/tls/credentials/testdata']:
        paths.update(path for path in directory.rglob('*') if path.is_file() and
                     not any(part in {'.git', '__pycache__', 'evidence', 'binaries'}
                             for part in path.parts))
    return {str(path): digest(path) for path in sorted(paths)}


def run(command, env=None, timeout=90):
    started = time.monotonic()
    result = subprocess.run([str(value) for value in command], capture_output=True,
                            text=True, timeout=timeout, env=env)
    output = result.stdout+result.stderr
    record = dict(command=[str(value) for value in command], returncode=result.returncode,
                  stdout=result.stdout, stderr=result.stderr, seconds=time.monotonic()-started)
    assert result.returncode == 0, record
    assert 'ERROR: AddressSanitizer' not in output, record
    assert 'WARNING: ThreadSanitizer' not in output, record
    return record


def thread_count(pid):
    directory = Path('/proc')/str(pid)/'task'
    if directory.is_dir():
        return len(list(directory.iterdir()))
    result = subprocess.run(['ps', '-M', '-p', str(pid), '-o', 'pid='],
                            capture_output=True, text=True, timeout=5)
    assert result.returncode == 0, result.stderr
    return len(result.stdout.splitlines())


class Server:
    def __init__(self, binary, mode, cert, key):
        self.process = subprocess.Popen([str(binary), mode, str(cert), str(key)],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True)
        self.lines, self.pending, self.buffered = [], queue.Queue(), []
        self.joined = False
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
        return '127.0.0.1:'+str(self.port)

    def line(self, prefix, timeout=20):
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
        values = self.line('METRICS ').split()[1:]
        names = ['active', 'valid', 'created', 'opened', 'closed', 'dropped', 'messages',
                 'queue_count', 'queue_bytes', 'out_limit', 'scope_bytes', 'scope_nodes',
                 'write_waits', 'partial_writes', 'writable_callbacks', 'clean', 'unclean',
                 'close_timeouts', 'combined_timeouts']
        assert len(values) == len(names), values
        return {name: value if name == 'valid' else int(value)
                for name, value in zip(names, values)}

    def wait_metrics(self, predicate, timeout=12):
        until = time.monotonic()+timeout
        while True:
            values = self.metrics()
            if predicate(values):
                return values
            assert time.monotonic() < until, (values, self.lines)
            time.sleep(.005)

    def idle(self):
        values = self.wait_metrics(lambda value: value['active'] == 0)
        assert values['created'] == values['dropped'], values
        assert values['scope_bytes'] == 0, values
        return values

    def join(self):
        self.command('s')
        assert self.line('FINISHED ').split()[1] == 'true'
        self.command('j')
        values = list(map(int, self.line('JOINED ').split()[1:]))
        names = ['created', 'opened', 'closed', 'dropped', 'scope_bytes', 'scope_nodes',
                 'heap_bytes', 'tls_bytes', 'write_waits', 'partial_writes']
        assert len(values) == len(names), values
        record = dict(zip(names, values))
        assert record['created'] == record['dropped'], record
        assert record['opened'] <= record['closed'], record
        assert record['scope_nodes'] == 1, record
        assert record['scope_bytes'] == record['heap_bytes'] == record['tls_bytes'] == 0, record
        self.joined = True
        lsof = shutil.which('lsof') or '/usr/sbin/lsof'
        if Path(lsof).is_file():
            sockets = subprocess.run([lsof, '-nP', '-a', '-p', str(self.process.pid),
                                      '-iTCP', '-Fn'], capture_output=True, text=True, timeout=5)
            assert sockets.returncode in (0, 1) and not sockets.stdout.strip(), sockets
            record['tcp_descriptors_after_join'] = 0
        return record

    def close(self):
        if self.process.poll() is None:
            if not self.joined:
                self.join()
            self.command('q')
        try:
            self.process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            self.process.kill();self.process.wait()
            raise
        self.reader.join(timeout=2)
        stderr = self.process.stderr.read()
        assert self.process.returncode == 0, (self.lines, stderr)
        assert 'ERROR: AddressSanitizer' not in stderr, stderr
        assert 'WARNING: ThreadSanitizer' not in stderr, stderr
        return dict(lines=self.lines, stderr=stderr)


def peer_held(process):
    assert select.select([process.stdout], [], [], 30)[0], ('peer readiness', process.poll())
    line = process.stdout.readline().strip()
    assert line == 'HELD', (line, process.poll())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--odin', required=True, type=Path)
    parser.add_argument('--go', required=True, type=Path)
    parser.add_argument('--go-root', required=True, type=Path)
    parser.add_argument('--shared', type=Path, default=HERE.parents[1])
    parser.add_argument('--sdk-root', type=Path)
    parser.add_argument('--sanitize', choices=['address', 'thread'], default='address')
    parser.add_argument('--evidence-dir', type=Path)
    parser.add_argument('--report', required=True, type=Path)
    parser.add_argument('--case', help='Select case name prefix')
    args = parser.parse_args()
    compiler = args.odin.resolve()
    sdk = args.sdk_root.resolve() if args.sdk_root else Path(run([compiler, 'root'])['stdout'].strip())
    shared = args.shared.resolve()
    fixtures = sdk/'tests/core/crypto/tls/credentials/testdata'
    cert, key = fixtures/'rsa2048-valid.pem', fixtures/'rsa2048.pem'
    initial = snapshot(shared, sdk)
    report = dict(passed=False, scope='Darwin/native Saba application WS/WSS; owned peers; no Mesa or performance certification',
                  sanitizer=args.sanitize, compiler_sha256=digest(compiler),
                  input_sha256=initial, cases=[])
    environment = dict(os.environ, GOROOT=str(args.go_root), GOTOOLCHAIN='local',
                       GOPROXY='off', GOSUMDB='off', GO111MODULE='off', CGO_ENABLED='0')
    if args.evidence_dir:
        args.evidence_dir.mkdir(parents=True, exist_ok=True)
    work = contextlib.nullcontext(str(args.evidence_dir)) if args.evidence_dir else tempfile.TemporaryDirectory(prefix='saba-websocket79-')
    def selected(name):
        return not args.case or name.startswith(args.case)
    try:
        report['compiler'] = run([compiler, 'version'])
        report['go'] = run([args.go, 'version'], env=environment)
        with work as temporary:
            directory = Path(temporary)
            native, peer, surf = directory/'server', directory/'go-peer', directory/'surf-peer'
            flags = ['-collection:shared='+str(shared), '-thread-count:1',
                     '-warnings-as-errors', '-vet', '-sanitize:'+args.sanitize]
            report['builds'] = [run([compiler, 'build', SOURCE, *flags, '-out:'+str(native)]),
                                run([compiler, 'build', SOURCE/'surf_client', *flags, '-out:'+str(surf)]),
                                run([args.go, 'build', '-o', peer, SOURCE/'peer.go'], env=environment)]
            report['binaries'] = {path.name: dict(path=str(path), sha256=digest(path))
                                   for path in [native, peer, surf]}
            for transport in ['ws', 'wss']:
                for mode in ['echo', 'policy', 'invalid', 'queue', 'application-close', 'empty-close', 'application-noack',
                             'peer-close-discard', 'combined-frame', 'combined-fragment', 'slow', 'hold']:
                    name = transport+'-'+mode
                    if not selected(name):
                        continue
                    server = Server(native, transport, cert, key)
                    case = dict(name=name, passed=False)
                    report['cases'].append(case)
                    command = [peer, server.endpoint, cert, mode, str(transport == 'wss').lower()]
                    process = None
                    try:
                        if mode.startswith('combined-'):
                            process = subprocess.Popen([str(value) for value in command],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                            peer_held(process)
                            started = time.monotonic()
                            server.line('COMBINED')
                            metrics = server.wait_metrics(lambda value: value['active'] == 1 and value['scope_bytes'] >= 8*1024*1024, timeout=.5)
                            until = time.monotonic()+.5
                            while True:
                                server.command('b')
                                valid, ready = server.line('PRESSURE ').split()[1:]
                                if valid == 'true' and ready == 'false':
                                    break
                                assert time.monotonic() < until, ('no observed kernel write pressure', valid, ready)
                                time.sleep(.005)
                            case['pressure_barrier'] = dict(kernel_write_ready=False, metrics=metrics,
                                client_application_reads_before_retirement=0)
                            retired = server.wait_metrics(lambda value: value['active'] == 0, timeout=2.5)
                            elapsed = time.monotonic()-started
                            assert .5 <= elapsed < 2.5, (elapsed, retired)
                            assert retired['combined_timeouts'] == 1 and retired['unclean'] == 1 and retired['clean'] == 0, retired
                            assert retired['scope_bytes'] == 0, retired
                            if transport == 'wss':
                                assert retired['write_waits'] > 0 and retired['partial_writes'] > 0, retired
                            case['metrics'] = retired
                            case['deadline_milliseconds'] = elapsed*1000
                            process.stdin.write('release\n');process.stdin.flush()
                            stdout, stderr = process.communicate(timeout=10)
                            assert process.returncode == 0, (stdout, stderr)
                            case['peer'] = dict(command=[str(value) for value in command], stdout=stdout, stderr=stderr)
                            case['joined'] = server.join()
                        elif mode in ['slow', 'hold']:
                            # Warm lazy runtime/sanitizer state before measuring worker count.
                            case['warmup'] = run([peer, server.endpoint, cert, 'echo', str(transport == 'wss').lower()])
                            server.idle()
                            baseline = thread_count(server.process.pid)
                            process = subprocess.Popen([str(value) for value in command],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                            peer_held(process)
                            metrics = server.wait_metrics(lambda value: value['active'] >= (25 if mode == 'slow' else 24))
                            assert metrics['scope_bytes'] <= 64*1024*1024, metrics
                            assert thread_count(server.process.pid) == baseline, metrics
                            case['held_metrics'] = metrics
                            case['threads_before'] = case['threads_held'] = baseline
                            if mode == 'slow':
                                process.stdin.write('release\n');process.stdin.flush()
                                stdout, stderr = process.communicate(timeout=30)
                                assert process.returncode == 0, (stdout, stderr)
                                case['peer'] = dict(command=[str(value) for value in command], stdout=stdout, stderr=stderr)
                                case['metrics'] = server.idle()
                                if transport == 'wss':
                                    assert case['metrics']['write_waits'] > 0, case['metrics']
                                    assert case['metrics']['partial_writes'] > 0, case['metrics']
                                case['joined'] = server.join()
                            else:
                                case['joined'] = server.join()
                                stdout, stderr = process.communicate(timeout=10)
                                assert process.returncode == 0, (stdout, stderr)
                                case['peer'] = dict(command=[str(value) for value in command], stdout=stdout, stderr=stderr)
                        else:
                            case['peer'] = run(command)
                            case['metrics'] = server.idle()
                            if mode in ['echo', 'application-close', 'empty-close', 'peer-close-discard']:
                                assert case['metrics']['clean'] == 1 and case['metrics']['unclean'] == 0, case['metrics']
                            if mode == 'application-noack':
                                assert case['metrics']['clean'] == 0 and case['metrics']['unclean'] == 1 and case['metrics']['close_timeouts'] == 1, case['metrics']
                            if mode == 'invalid':
                                assert case['metrics']['clean'] == 0, case['metrics']
                            if mode == 'queue':
                                assert case['metrics']['queue_count'] == case['metrics']['queue_bytes'] == case['metrics']['out_limit'] == 1, case['metrics']
                                assert case['metrics']['writable_callbacks'] == 2, case['metrics']
                            case['joined'] = server.join()
                        case['passed'] = True
                    finally:
                        if process is not None and process.poll() is None:
                            process.kill();process.communicate()
                        case['server'] = server.close()
            if selected('surf-compatibility'):
                server = Server(native, 'ws', cert, key)
                case = dict(name='surf-compatibility', passed=False)
                report['cases'].append(case)
                try:
                    case['peer'] = run([surf, str(server.port)])
                    case['metrics'] = server.idle()
                    case['joined'] = server.join()
                    case['passed'] = True
                finally:
                    case['server'] = server.close()
            assert report['cases'], 'No selected cases'
            report['inputs_unchanged'] = snapshot(shared, sdk) == initial
            assert report['inputs_unchanged'], 'Source/resource inputs changed during gate'
            assert digest(compiler) == report['compiler_sha256'], 'Compiler changed during gate'
            report['passed'] = all(case['passed'] for case in report['cases'])
    finally:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(dict(passed=True, groups=len(report['cases']), report=str(args.report))))


if __name__ == '__main__':
    main()
