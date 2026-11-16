#!/bin/sh
# ODIN selects the compiler; remaining arguments apply to every test suite.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
exec bash "$root/tests/run.sh" --odin "${ODIN:-odin}" -- "$@"
