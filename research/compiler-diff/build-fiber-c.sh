#!/usr/bin/env bash
# Build one fiber-c benchmark (wasmfx backend) outside the submodule tree.
# Mirrors fiber-c/Makefile rules out/%_wasmfx.wasm and out/%_switch_wasmfx.wasm.
# Usage: build-fiber-c.sh <name>      e.g. itersum  or  itersum_switch
set -euo pipefail
NAME=$1
REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
FIBER=$REPO/fiber-c
OUT=${OUT:-$(dirname "$0")/fiber-c-build}
WASI_SDK=${WASI_SDK:-$HOME/workspace/benchfx/tools/wasi-sdk/wasi-sdk-22.0}
BINARYEN=${BINARYEN:-$HOME/dev_path/binaryen}
WASM_INTERP=${WASM_INTERP:-$HOME/.opam/default/bin/wasm}
WASICC=$WASI_SDK/bin/clang
SHADOW_STACK_FLAG=-DFIBER_WASMFX_PRESERVE_SHADOW_STACK        # make.config: WASMFX_PRESERVE_SHADOW_STACK=1
CAP=-DWASMFX_CONT_TABLE_INITIAL_CAPACITY=1024                 # make.config default
SS=-DWASMFX_CONT_SHADOW_STACK_SIZE=65536                      # make.config default
WASI_FLAGS="--sysroot=$WASI_SDK/share/wasi-sysroot -std=c17 -Wall -Wextra -Werror -Wpedantic -Wno-strict-prototypes -O3 -I $FIBER/inc"
BINARYEN_FLAGS="--enable-nontrapping-float-to-int --enable-exception-handling --enable-reference-types --enable-multivalue --enable-bulk-memory --enable-gc --enable-stack-switching"
mkdir -p "$OUT"
if [[ $NAME == *_switch ]]; then
  PP=$FIBER/src/wasmfx/imports_switch.wat.pp; IMPL=$FIBER/src/wasmfx/wasmfx_switch_impl.c; IMPMOD=fiber_switch_wasmfx_imports
else
  PP=$FIBER/src/wasmfx/imports.wat.pp;        IMPL=$FIBER/src/wasmfx/wasmfx_impl.c;        IMPMOD=fiber_wasmfx_imports
fi
# 1. preprocess the .wat.pp shim (the module that holds resume/suspend/switch)
$WASICC -xc $SHADOW_STACK_FLAG $CAP -E $PP | sed 's/^#.*//g' > $OUT/$IMPMOD.wat
# 2. assemble it with the reference interpreter
$WASM_INTERP -d -i $OUT/$IMPMOD.wat -o $OUT/$IMPMOD.wasm
# 3. compile the C side
$WASICC $SHADOW_STACK_FLAG $SS $CAP -Wl,--export-table,--export-memory,--export=__stack_pointer $IMPL $WASI_FLAGS $FIBER/examples/$NAME.c -o $OUT/${NAME}_wasmfx.pre.wasm
# 4. merge (shim first, exactly as the Makefile does)
$BINARYEN/bin/wasm-merge $BINARYEN_FLAGS --enable-multimemory $OUT/$IMPMOD.wasm "$IMPMOD" $OUT/${NAME}_wasmfx.pre.wasm "main" -o $OUT/${NAME}_wasmfx.unopt.wasm
# 5. optimize -- only for non-switch modules, exactly as fiber-c/Makefile does (its out/%_switch_wasmfx.wasm rule
#    stops after wasm-merge; binaryen v124's -O2 also asserts on any module containing `switch`)
if [[ $NAME == *_switch ]]; then
  cp $OUT/${NAME}_wasmfx.unopt.wasm $OUT/${NAME}_wasmfx.wasm
else
  $BINARYEN/bin/wasm-opt $BINARYEN_FLAGS -O2 -g $OUT/${NAME}_wasmfx.unopt.wasm -o $OUT/${NAME}_wasmfx.wasm
fi
echo "built $OUT/${NAME}_wasmfx.wasm"
