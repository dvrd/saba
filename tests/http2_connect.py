#!/usr/bin/env python3
"""Owned RFC8441 peers. Only loopback sockets; no module downloads."""
import sys; sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent))
import harness_env
import argparse
import json
import os
import shutil
from pathlib import Path
import queue
import subprocess
import threading

HERE = Path(__file__).resolve().parent
SHARED = harness_env.shared()


def run(command, env, timeout=120):
    result = subprocess.run([str(x) for x in command], env=env, capture_output=True,
                            text=True, timeout=timeout)
    record = dict(command=[str(x) for x in command], returncode=result.returncode,
                  stdout=result.stdout, stderr=result.stderr)
    if result.returncode or "ERROR: AddressSanitizer" in result.stderr or "WARNING: ThreadSanitizer" in result.stderr:
        raise RuntimeError(json.dumps(record))
    return record


def exercise(binary, server_arguments, peers, env):
    server = subprocess.Popen([str(binary), *map(str, server_arguments)], env=env,
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True)
    lines, inbox = [], queue.Queue()
    def read_output():
        for line in server.stdout:
            lines.append(line.rstrip())
            inbox.put(line.rstrip())
        inbox.put(None)
    reader = threading.Thread(target=read_output, daemon=True)
    reader.start()
    try:
        line = inbox.get(timeout=10)
        if not line or not line.startswith("READY "):
            raise RuntimeError(f"server failed: {lines}")
        port = line.split()[1]
        records = [run(command(port), env, 20) for command in peers]
        server.stdin.write("s\n")
        server.stdin.flush()
        server.wait(timeout=8)
        reader.join(timeout=2)
        stderr = server.stderr.read()
        record = dict(returncode=server.returncode, stdout="\n".join(lines), stderr=stderr)
        records.append(record)
        if server.returncode or "ERROR: AddressSanitizer" in stderr or "WARNING: ThreadSanitizer" in stderr:
            raise RuntimeError(json.dumps(record))
        return records
    except Exception:
        if server.poll() is None:
            server.kill()
            server.wait()
        reader.join(timeout=2)
        print(json.dumps(dict(server_stdout=lines,server_stderr=server.stderr.read())))
        raise
    finally:
        if server.poll() is None:
            server.kill()
            server.wait()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--odin", type=Path, default=Path(harness_env.odin()))
    parser.add_argument("--sanitize", choices=("address", "thread"), default=harness_env.sanitizer())
    parser.add_argument("--mutual-tls", action="store_true")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    env = os.environ.copy()
    env["GO111MODULE"] = "off"
    go = harness_env.go()
    work = harness_env.workdir("saba-http2-connect-")
    try:
        exercise_all(args, env, go, work)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def exercise_all(args, env, go, work):
    binary, peer = work / "server", work / "peer"
    sanitize = [f"-sanitize:{args.sanitize}"] if args.sanitize else []
    cert = HERE / 'testdata/tls/localhost.pem'
    key = HERE / 'testdata/tls/rsa2048.pem'
    records = [run([go, "build", "-o", peer, HERE / "http2_connect/peer.go"], env),
               run([args.odin, "build", HERE / "http2_connect", f"-collection:shared={SHARED}",
                    "-warnings-as-errors", *sanitize, f"-out:{binary}"], env)]
    plain = exercise(binary, ["server", cert, key],
                     [lambda port: [peer, f"127.0.0.1:{port}"],
                      lambda port: [binary, "client", port, cert]], env)
    assert "opened=4 dropped=4" in plain[-1]["stdout"] and "resets=1" in plain[-1]["stdout"], plain
    records += plain
    if args.mutual_tls:
        sdk = harness_env.sdk()
        mtls = sdk / "core/crypto/tls/testdata/mtls"
        records += exercise(binary, ["server-mtls", mtls / "server.pem", mtls / "server-key.pem", mtls / "root.pem"],
                            [lambda port: [binary, "client-mtls", port, mtls / "root.pem",
                                           mtls / "client.pem", mtls / "client-key.pem",
                                           mtls / "client-large.pem", mtls / "client-large-key.pem"]], env)
    result = dict(passed=True, sanitizer=args.sanitize, mutual_tls=args.mutual_tls, records=records)
    if args.report:
        args.report.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(dict(passed=True, sanitizer=args.sanitize, mutual_tls=args.mutual_tls, records=len(records))))

if __name__ == "__main__":
    main()
