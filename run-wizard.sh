#!/usr/bin/env bash
# run-wizard.sh — time every benchmark wasm in microbench/wasm on Wizard (SPC via --mode=jit).
# Usage: ./run-wizard.sh --repeat N [--only pat] [--skip pat] [--timeout SECS] [--list]
# Overrides: WIZENG (binary), WIZARD_FLAGS (engine flags).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENGINE=wizard
WIZENG="${WIZENG:-$ROOT/wizard-engine/bin/wizeng.x86-64-linux}"
WIZARD_FLAGS="${WIZARD_FLAGS:---ext:all --stack-size=65536 --mode=jit}"

if [ ! -x "$WIZENG" ]; then
  echo "Wizard binary not found at $WIZENG" >&2
  echo "Build it with: (cd wizard-engine && ./build.sh wizeng x86-64-linux)" >&2
  exit 1
fi

engine_run() {
  local kind="$1" wasm="$2"; shift 2
  # Wizard invokes the exported main/_start itself, so both kinds run the same way;
  # WASI argv are the trailing arguments.
  # shellcheck disable=SC2086
  "$WIZENG" $WIZARD_FLAGS "$wasm" "$@"
}
export WIZENG WIZARD_FLAGS
export -f engine_run

source "$ROOT/bench-common.sh" "$@"
