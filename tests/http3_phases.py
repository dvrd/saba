#!/usr/bin/env python3
"""Qualify Saba's public phase mapping using HTTP's maintained independent peer."""
import sys; sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent))
import harness_env
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
SABA = HERE.parent
SHARED = Path(harness_env.shared())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sources():
    return {str(p.relative_to(SABA)): digest(p)
            for root in (SABA / 'src', SABA / 'tests') for p in root.rglob('*')
            if p.is_file() and p.suffix in ('.odin', '.py', '.pem')}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--odin', type=Path, default=Path(harness_env.odin()))
    parser.add_argument('--python')
    parser.add_argument('--sanitize', choices=('address', 'thread'))
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    args.python = args.python or harness_env.aioquic_python()
    # Imported fixtures belong to the validated source tree, never a bytecode cache.
    sys.dont_write_bytecode = True
    path = HERE / 'testdata/tls/request_phases/run.py'
    spec = importlib.util.spec_from_file_location('http_phase_harness', path)
    harness = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(harness)
    environment = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
    before = sources()
    result = dict(source_sha256=before, http_harness_sha256=digest(path), profiles=[])
    with tempfile.TemporaryDirectory(prefix='saba-h3-phases-') as work:
        binary = Path(work) / 'server'
        command = [str(args.odin.resolve()), 'build', str(HERE / 'http3_phases'),
                   '-collection:shared=' + str(SHARED), '-thread-count:1',
                   '-warnings-as-errors', *harness_env.VET, '-out:' + str(binary)]
        if args.sanitize:
            command.append('-sanitize:' + args.sanitize)
        build = subprocess.run(command, capture_output=True, text=True,
                               env=environment, timeout=120)
        result['build'] = dict(command=command, exit_code=build.returncode,
                               stdout=build.stdout, stderr=build.stderr)
        if build.returncode == 0:
            result['binary_sha256'] = digest(binary)
            for name in ('isolation', 'progress', 'stream-budget'):
                row = harness.profile(binary, args.python, name, environment)
                result['profiles'].append(row)
                if not row['passed']:
                    break
        result['source_unchanged'] = sources() == before
        result['passed'] = (build.returncode == 0 and result['source_unchanged']
                            and len(result['profiles']) == 3
                            and all(r['passed'] for r in result['profiles']))
        if args.report:
            args.report.write_text(json.dumps(result, indent=2) + '\n')
    assert result['passed'], json.dumps(result.get('profiles'), indent=2)[-6000:]
    print('public Saba facade phase isolation and small-window progress pass')


if __name__ == '__main__':
    main()
