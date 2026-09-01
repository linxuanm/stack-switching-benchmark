#!/usr/bin/env bash
# build-ocaml.sh — rebuild the ocaml_*.wasm benchmarks in microbench/wasm/ from
# benchmark/benches/multicore/multicore-effects/ via wasm_of_ocaml's native effects backend.
#
# Pipeline per program (same as tools/ocaml-refrun.sh stages 1-2):
#   ocamlfind ocamlc prog.ml -o prog.byte
#   wasm_of_ocaml compile --effects=native --enable wasi prog.byte -o prog.js
#   cp prog.assets/code.wasm  ->  microbench/wasm/ocaml_<prog>.wasm
#
# The output imports only wasi_snapshot_preview1, so it runs directly on engines
# with WASI. Wizard runs these with --ext:all; upstream Wasmtime refuses them at
# compile time ("Stack switching feature not compatible with GC, yet").
#
# Requires (all from env.sh, i.e. dependencies/ as built by build-all.sh): the opam switch
# with ocamlfind, WASM_OF_OCAML_EXE (wasm_of_ocaml.exe) and BINARYEN (wasm_of_ocaml runs
# wasm-opt/wasm-merge from $BINARYEN/bin).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT/env.sh"
WOO="$WASM_OF_OCAML_EXE"
BINARYEN_BIN="$BINARYEN/bin"
[ -x "$BINARYEN_BIN/wasm-opt" ] || { echo "binaryen wasm-opt not found at $BINARYEN_BIN/wasm-opt (./build-all.sh --only binaryen)" >&2; exit 1; }
BENCH="$ROOT/benchmark/benches/multicore/multicore-effects"
OUT="$ROOT/microbench/wasm"
TMP="$(mktemp -d)"
PROGRAMS=(effect_throughput_perform effect_throughput_perform_drop effect_throughput_val
          rec_eff_fib rec_seq_fib eratosthenes algorithmic_differentiation)
[ -x "$WOO" ] || { echo "wasm_of_ocaml not found at $WOO (./build-all.sh --only jsoo)" >&2; exit 1; }
for p in "${PROGRAMS[@]}"; do
  ocamlfind ocamlc "$BENCH/$p.ml" -o "$TMP/$p.byte" 2>/dev/null || ocamlc "$BENCH/$p.ml" -o "$TMP/$p.byte"
  PATH="$BINARYEN_BIN:$PATH" "$WOO" compile --effects=native --enable wasi "$TMP/$p.byte" -o "$TMP/$p.js"
  cp "$TMP/$p.assets/code.wasm" "$OUT/ocaml_$p.wasm"
  echo "built $OUT/ocaml_$p.wasm"
done
