"""Environment shared by the loopback harnesses in this directory.

`task test` exports ODIN (the compiler) and SABA_TEST_SHARED (a staged
collection whose `saba` entry is this checkout's src/). Every harness resolves
its tools from here, so none of them names a path on a particular machine.
A harness that needs an optional tool exits with SKIP and a one-line reason.
"""
import atexit
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

TESTS = Path(__file__).resolve().parent
SABA = TESTS.parent
TLS = TESTS / 'testdata/tls'
SKIP = 77
# Vet Saba's packages and the test program, not the dependencies: async, surf
# and the rest are vetted in their own repositories.
VET = ['-vet', '-vet-packages:main,server,saba_application,saba_assets,saba_core,saba_development,'
       'saba_jsx,saba_modules,saba_offload,saba_pages,saba_s3,saba_upstream,saba_websocket']


def skip(reason):
    print('SKIP: ' + reason, flush=True)
    sys.exit(SKIP)


def odin():
    compiler = os.environ.get('ODIN') or shutil.which('odin')
    if not compiler:
        sys.exit('No Odin compiler: set ODIN or put odin on PATH')
    resolved = shutil.which(compiler) or compiler
    return str(Path(resolved).resolve())


def shared():
    collection = os.environ.get('SABA_TEST_SHARED')
    if not collection or not Path(collection, 'saba').exists():
        sys.exit('Set SABA_TEST_SHARED to a collection that contains saba (task test does this)')
    return str(Path(collection).resolve())


def collection():
    return '-collection:shared=' + shared()


def sdk():
    """Root of the compiler's own tree (core/, base/), for fixtures it ships."""
    root = os.environ.get('ODIN_ROOT')
    if not root:
        root = subprocess.run([odin(), 'root'], capture_output=True, text=True, timeout=30).stdout.strip()
    return Path(root)


def go():
    tool = os.environ.get('SABA_GO') or shutil.which('go')
    if not tool:
        skip('go is not available (set SABA_GO)')
    return tool


def aioquic_python():
    """A Python that can import aioquic; never installs anything."""
    for candidate in (os.environ.get('SABA_AIOQUIC_PYTHON'), sys.executable):
        if not candidate:
            continue
        probe = subprocess.run([candidate, '-c', 'import aioquic'], capture_output=True, timeout=60)
        if probe.returncode == 0:
            return candidate
    skip('the Python package aioquic is not available (set SABA_AIOQUIC_PYTHON to an interpreter that has it)')


def workdir(prefix):
    """A private directory for built binaries, removed when the harness exits."""
    path = Path(tempfile.mkdtemp(prefix=prefix))
    atexit.register(shutil.rmtree, path, ignore_errors=True)
    return path


def sanitize_for(name):
    return ['-sanitize:' + name] if name else []


def sanitizer():
    """Sanitizer requested for this run. Off unless SABA_TEST_SANITIZE names one,
    because a sanitizer build needs a clang that matches the compiler's LLVM."""
    return os.environ.get('SABA_TEST_SANITIZE') or None


def sanitize_flags():
    name = sanitizer()
    return ['-sanitize:' + name] if name else []
