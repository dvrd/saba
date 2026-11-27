#!/bin/bash
# Run from the checkout root. PLAYWRIGHT_PATH can identify an existing install.
set -euo pipefail
root=$(pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/saba-preload.XXXXXXXX")
service_pids=()
cleanup() {
  if ((${#service_pids[@]})); then
    for pid in "${service_pids[@]}"; do kill "$pid" 2>/dev/null || true; done
    for pid in "${service_pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  fi
  rm -rf -- "$scratch"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
odin_flags=(-o:speed "-out:$scratch/server")
if [[ -n "${WEBTOOLS_SHARED:-}" ]]; then odin_flags+=("-collection:shared=$WEBTOOLS_SHARED"); fi
"${ODIN:-odin}" build benchmarks/mesa "${odin_flags[@]}"

variant="$scratch/preload"
mkdir -p "$variant/benchmarks/mesa"
ln -s "$root/src" "$variant/src"
for file in entry.js planned.js app.js style.css; do
  ln -s "$root/benchmarks/mesa/$file" "$variant/benchmarks/mesa/$file"
done
# Every other byte of the document, and every application module, stays identical.
sed 's|</head>|<link rel="modulepreload" href="/app.js"><link rel="modulepreload" href="/__saba/dom.js"></head>|' \
  benchmarks/mesa/index.html > "$variant/benchmarks/mesa/index.html"

origins=()
for arm in control preload; do
  workdir="$root"
  if [[ "$arm" == preload ]]; then workdir="$variant"; fi
  (cd "$workdir"; exec "$scratch/server" 0 "$scratch/$arm.sqlite" "$scratch/$arm.port") &
  pid=$!
  service_pids+=("$pid")
  for ((i=0; i<300; i++)); do
    if [[ -s "$scratch/$arm.port" ]]; then break; fi
    kill -0 "$pid"
    sleep .05
  done
  [[ -s "$scratch/$arm.port" ]]
  origins+=("http://127.0.0.1:$(cat "$scratch/$arm.port")")
done
"${SABA_BENCH_NODE:-node}" benchmarks/mesa/startup.cjs "${origins[0]}" \
  "${1:-docs/benchmarks/saba-preload.json}" "${origins[1]}"
