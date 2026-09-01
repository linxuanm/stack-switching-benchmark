#!/usr/bin/env bash
# run-wizard.sh — time every benchmark wasm in microbench/wasm on Wizard (SPC via --mode=jit).
# Usage: ./run-wizard.sh --repeat N [--only pat] [--skip pat] [--timeout SECS] [--list]
# WIZENG comes from env.sh (dependencies/); override it or WIZARD_FLAGS in the environment.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi   # `sh <script>` -> re-run under bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
. "$ROOT/env.sh"
ENGINE=wizard
WIZARD_FLAGS="${WIZARD_FLAGS:---ext:all --stack-size=65536 --mode=jit}"

if [ ! -x "$WIZENG" ]; then
  echo "Wizard binary not found at $WIZENG" >&2
  echo "Build it with: ./build-all.sh --only wizard" >&2
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
