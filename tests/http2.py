#!/usr/bin/env python3
"""Owned loopback peer for the Saba HTTP/2 adapter. No public endpoints."""
import sys; sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent))
import harness_env
import os
import shutil
from pathlib import Path
import queue
import subprocess
import threading
import time

HERE = Path(__file__).resolve().parent
SOURCE = HERE / "http2"
SHARED = harness_env.shared()
ODIN = harness_env.odin()
CERT = harness_env.TLS / "rsa2048-valid.pem"
KEY = harness_env.TLS / "rsa2048.pem"
ENV = os.environ.copy()
ENV["GO111MODULE"] = "off"


def run(command, timeout=120):
    started = time.monotonic()
    result = subprocess.run([str(item) for item in command], capture_output=True,
                            text=True, timeout=timeout, env=ENV)
    record = dict(command=[str(item) for item in command], returncode=result.returncode,
                  stdout=result.stdout[-4000:], stderr=result.stderr[-4000:],
                  seconds=round(time.monotonic() - started, 3))
    if result.returncode != 0 or "ERROR: AddressSanitizer" in result.stderr:
        raise SystemExit(record)
    return record


class Server:
    def __init__(self, binary):
        self.process = subprocess.Popen(
            [str(binary), str(CERT), str(KEY)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=ENV)
        self.lines, self.pending = [], queue.Queue()

        def read():
            for line in self.process.stdout:
                value = line.strip()
                self.lines.append(value)
                self.pending.put(value)
            self.pending.put(None)

        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()
        self.port = int(self.line("READY ").split()[1])

    def line(self, prefix, timeout=15):
        until = time.monotonic() + timeout
        while time.monotonic() < until:
            try:
                value = self.pending.get(timeout=max(0.1, until - time.monotonic()))
            except queue.Empty:
                continue
            if value is None:
                raise SystemExit({"dead": self.lines, "stderr": self.process.stderr.read()})
            if value.startswith(prefix):
                return value
            self.lines.append(value)
        raise SystemExit({"timeout": prefix, "lines": self.lines})

    def stop(self):
        try:
            self.process.stdin.write("s\n")
            self.process.stdin.flush()
        except BrokenPipeError:
            pass
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()


def peer(mode, port):
    result = subprocess.run([harness_env.go(), "run", str(SOURCE / "peer.go"), mode, f"127.0.0.1:{port}"],
                            capture_output=True, text=True, timeout=20, env=ENV)
    if result.returncode != 0 or not result.stdout.strip().endswith(mode):
        raise SystemExit({"mode": mode, "code": result.returncode,
                          "stdout": result.stdout, "stderr": result.stderr, "server": None})
    return result.stdout.strip()


def main():
    harness_env.go()
    work = harness_env.workdir("saba-http2-")
    binary = work / "server"
    run([ODIN, "build", SOURCE, f"-collection:shared={SHARED}", "-warnings-as-errors",
         *harness_env.sanitize_flags(), f"-out:{binary}"])
    server = Server(binary)
    try:
        results = {}
        for mode in ("success", "malformed", "stall", "http1", "noalpn"):
            try:
                results[mode] = peer(mode, server.port)
            except SystemExit as failure:
                raise SystemExit({"failure": failure.code, "server": server.lines})
        if not any(line.startswith("REQ ") for line in server.lines):
            raise SystemExit({"missing-request": server.lines})
        print("PASS", results)
    finally:
        server.stop()
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
