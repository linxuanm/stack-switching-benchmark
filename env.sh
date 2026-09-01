#!/usr/bin/env bash
# env.sh — the benchmark's virtual environment.  Source it from bash:
#
#   source ./env.sh
#
# It points every tool the scripts use into dependencies/ (populated by ./build-all.sh):
#   WIZENG, WASMTIME     the two engines
#   V3C, VIRGIL_LOC      Virgil, for building Wizard
#   WASI_SDK             wasi-sdk 22 (downloaded by build-all.sh)
#   BINARYEN             binaryen build tree: $BINARYEN/bin/{wasm-opt,wasm-merge,...}
#   WASM_INTERP          the WasmFX reference interpreter (specfx)
#   WASM_OF_OCAML_EXE    wasm_of_ocaml.exe from the js_of_ocaml submodule (not WASM_OF_OCAML:
#                        js_of_ocaml's own dune-workspace reads that name as a true/false switch)
#   OCAML_SWITCH         the opam switch (a local one under dependencies/ocaml)
#   RUST_TOOLCHAIN       the rustup toolchain used to build wasmtime
# puts Virgil's and binaryen's bin/ on PATH, and activates the opam switch.
#
# build-all.sh, run-wizard.sh, run-wasmtime.sh, runtime-compare.sh and the helper scripts
# source this file themselves.  A variable that is already set is kept — that is how you point
# at a tool installed elsewhere (build-all.sh then skips building that dependency); ./build.env,
# if present, is sourced first for exactly that purpose (template: build.env.example).
if [ -z "${BASH_VERSION:-}" ]; then
  echo "env.sh: source it from bash" >&2
  return 1 2>/dev/null || exit 1
fi
BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BENCH_ROOT
export DEPS="$BENCH_ROOT/dependencies"
export BENCHMARK_SRC="$BENCH_ROOT/benchmark"

# shellcheck disable=SC1091
[ -f "$BENCH_ROOT/build.env" ] && . "$BENCH_ROOT/build.env"

: "${WIZENG:=$DEPS/wizard-engine/bin/wizeng.x86-64-linux}"
: "${WASMTIME:=$DEPS/wasmtime/target/release/wasmtime}"
: "${VIRGIL_LOC:=$DEPS/virgil}"
: "${V3C:=$VIRGIL_LOC/bin/v3c}"
: "${WASI_SDK:=$DEPS/wasi-sdk}"
: "${BINARYEN:=$DEPS/binaryen-build}"
: "${WASM_INTERP:=$DEPS/specfx/interpreter/wasm}"
: "${WASM_OF_OCAML_EXE:=$DEPS/js_of_ocaml/_build/default/compiler/bin-wasm_of_ocaml/wasm_of_ocaml.exe}"
: "${OCAML_SWITCH:=$DEPS/ocaml}"
: "${RUST_TOOLCHAIN:=1.98.0}"
export WIZENG WASMTIME VIRGIL_LOC V3C WASI_SDK BINARYEN WASM_INTERP WASM_OF_OCAML_EXE OCAML_SWITCH RUST_TOOLCHAIN

_bench_path_add() { case ":$PATH:" in *":$1:"*) ;; *) PATH="$1:$PATH" ;; esac; }
_bench_path_add "$BINARYEN/bin"
_bench_path_add "$VIRGIL_LOC/bin"
export PATH
unset -f _bench_path_add

# The opam switch: local (dependencies/ocaml, created by build-all.sh) or a named one.
if command -v opam >/dev/null 2>&1; then
  if [ -d "$OCAML_SWITCH/_opam" ] || opam switch list --short 2>/dev/null | grep -qx "$OCAML_SWITCH"; then
    eval "$(opam env --switch="$OCAML_SWITCH" --set-switch 2>/dev/null)" || true
  fi
fi
