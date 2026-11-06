#!/usr/bin/env python3
"""Verify observer->snapshot->drain reentry on an actual finishing request."""
import argparse
import os
from pathlib import Path
import select
import socket
import subprocess
import tempfile
import json

SABA = Path(__file__).resolve().parents[1]

def line(proc):
    assert select.select([proc.stdout], [], [], 6)[0], 'observer drain timed out'
    result = proc.stdout.readline()
    assert result, proc.stderr.read().decode()
    return result

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--odin', default=os.environ.get('ODIN','odin'))
    args=parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='saba-observer-drain-') as tmp:
        binary=Path(tmp)/'fixture'
        subprocess.run([args.odin,'build',str(SABA/'testdata/drain_observer'),'-thread-count:1',
                        '-warnings-as-errors','-sanitize:address','-out:'+str(binary)],check=True)
        for workers in (1,4):
            proc=subprocess.Popen([str(binary)],env=dict(os.environ,DRAIN_WORKERS=str(workers)),
                                  stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            try:
                ready=line(proc);assert ready.startswith(b'ready '),ready
                with socket.create_connection(('127.0.0.1',int(ready.split()[1])),timeout=5) as conn:
                    conn.sendall(b'GET /ok HTTP/1.1\r\nHost: localhost\r\n\r\n')
                    response=b''
                    while True:
                        part=conn.recv(4096)
                        if not part:break
                        response+=part
                    assert response.startswith(b'HTTP/1.1 200 ') and response.endswith(b'\r\n\r\nok'),response
                    assert line(proc)==b'observer drain completed once\n'
                    assert proc.poll() is None,'process exit must not hide socket cleanup'
                proc.stdin.write(b'q');proc.stdin.flush();proc.wait(timeout=5)
                assert proc.returncode==0,proc.stderr.read().decode()
            finally:
                if proc.poll() is None:proc.kill();proc.wait()
                proc.stdin.close();proc.stdout.close();proc.stderr.close()
    print(json.dumps({'valid':True,'sanitizer':'address','checks':['workers=1 observer snapshot/drain reentry','workers=4 observer snapshot/drain reentry']}))

if __name__=='__main__':main()
