#!/usr/bin/env bash
# run-wasmtime.sh — time every benchmark wasm in microbench/wasm on Wasmtime (Cranelift).
# Usage: ./run-wasmtime.sh --repeat N [--only pat] [--skip pat] [--timeout SECS] [--list]
# Overrides: WASMTIME (binary), WASMTIME_FLAGS (feature flags for `wasmtime run`).
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi   # `sh <script>` -> re-run under bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENGINE=wasmtime
WASMTIME="${WASMTIME:-$ROOT/wasmtime/target/release/wasmtime}"
WASMTIME_FLAGS="${WASMTIME_FLAGS:--W=exceptions,function-references,gc,stack-switching,tail-call}"

if [ ! -x "$WASMTIME" ]; then
  echo "Wasmtime binary not found at $WASMTIME" >&2
  echo "Build it with: (cd wasmtime && cargo +1.98.0 build --release --bin wasmtime)" >&2
  exit 1
fi

engine_run() {
  local kind="$1" wasm="$2"; shift 2
  case "$kind" in
    invoke:*)
      # shellcheck disable=SC2086
      "$WASMTIME" run $WASMTIME_FLAGS --invoke "${kind#invoke:}" "$wasm" "$@" ;;
    *)
      # shellcheck disable=SC2086
      "$WASMTIME" run $WASMTIME_FLAGS "$wasm" "$@" ;;
  esac
}
export WASMTIME WASMTIME_FLAGS
export -f engine_run

source "$ROOT/bench-common.sh" "$@"
