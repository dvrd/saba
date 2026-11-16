#!/bin/sh
# ODIN selects the compiler; remaining arguments apply to every test suite.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec python3 "$root/tests/run.py" --odin "${ODIN:-odin}" -- "$@"
