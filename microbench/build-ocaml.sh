#!/usr/bin/env bash
# build-ocaml.sh — rebuild the ocaml_*.wasm benchmarks in microbench/wasm/ from
# benches/multicore/multicore-effects/ via wasm_of_ocaml's native effects backend.
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
# Requires: the opam switch (eval $(opam env)), the wasm_of_ocaml master build
# (see CLAUDE.md "Toolchain on this machine"), binaryen on PATH for wasm_of_ocaml.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WOO="${WASM_OF_OCAML:-$HOME/workspace/js_of_ocaml/_build/default/compiler/bin-wasm_of_ocaml/wasm_of_ocaml.exe}"
BINARYEN_BIN="${BINARYEN_BIN:-$HOME/dev_path/binaryen/bin}"
BENCH="$ROOT/benches/multicore/multicore-effects"
OUT="$ROOT/microbench/wasm"
TMP="$(mktemp -d)"
PROGRAMS=(effect_throughput_perform effect_throughput_perform_drop effect_throughput_val
          rec_eff_fib rec_seq_fib eratosthenes algorithmic_differentiation)
[ -x "$WOO" ] || { echo "wasm_of_ocaml not found at $WOO (set WASM_OF_OCAML)" >&2; exit 1; }
for p in "${PROGRAMS[@]}"; do
  ocamlfind ocamlc "$BENCH/$p.ml" -o "$TMP/$p.byte" 2>/dev/null || ocamlc "$BENCH/$p.ml" -o "$TMP/$p.byte"
  PATH="$BINARYEN_BIN:$PATH" "$WOO" compile --effects=native --enable wasi "$TMP/$p.byte" -o "$TMP/$p.js"
  cp "$TMP/$p.assets/code.wasm" "$OUT/ocaml_$p.wasm"
  echo "built $OUT/ocaml_$p.wasm"
done
