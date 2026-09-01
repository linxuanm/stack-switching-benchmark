#!/usr/bin/env bash
# Compile a single-file OCaml program to Wasm with wasm_of_ocaml's native
# stack-switching effects backend and run it on the Wasm reference interpreter.
#
#   tools/ocaml-refrun.sh path/to/bench.ml   [args...]
#   tools/ocaml-refrun.sh path/to/bench.byte [args...]   (pre-linked, for libraries)
#
# Pipeline:
#   ocamlfind ocamlc          .ml   -> .byte      (OCaml bytecode)
#   wasm_of_ocaml --effects=native  -> code.wasm  (cont.new/resume/suspend + try_table)
#   wasi_shim_gen.py + wasm-merge   -> merged     (resolves wasi_snapshot_preview1)
#   wasm2wast.py                    -> .wast      (module + (invoke "_start"))
#   wasm -i                         -> run
#
# Output: the guest's stdout bytes, one decimal byte per line via
# spectest.print_i32, decoded back to text at the end.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# Tools come from env.sh (dependencies/, built by build-all.sh; overridable in the environment).
# shellcheck disable=SC1091
. "$HERE/../env.sh"
WOO="$WASM_OF_OCAML_EXE"
BINARYEN_BIN="$BINARYEN/bin"
WASM="$WASM_INTERP"
[ -x "$WASM" ] || { echo "reference interpreter not found at $WASM (./build-all.sh --only specfx)" >&2; exit 1; }
[ -x "$BINARYEN_BIN/wasm-merge" ] || { echo "binaryen wasm-merge not found at $BINARYEN_BIN (./build-all.sh --only binaryen)" >&2; exit 1; }
OUTDIR="${OUTDIR:-$(mktemp -d)}"

MERGE_FLAGS="--enable-nontrapping-float-to-int --enable-exception-handling \
--enable-reference-types --enable-multivalue --enable-bulk-memory --enable-gc \
--enable-stack-switching --enable-tail-call"

[ $# -ge 1 ] || { echo "usage: $0 program.ml [args...]" >&2; exit 2; }
SRC="$1"; shift
BASE="$(basename "${SRC%.ml}")"; BASE="${BASE%.byte}"

[ -x "$WOO" ] || { echo "wasm_of_ocaml not found at $WOO (./build-all.sh --only jsoo)" >&2; exit 1; }

case "$SRC" in
  *.byte)
    # Already-linked bytecode: use it as-is. This is the escape hatch for
    # programs that need libraries (angstrom, etc.) -- link them however you
    # like, then hand the .byte here.
    echo "==> using prebuilt bytecode $SRC" >&2
    cp "$SRC" "$OUTDIR/$BASE.byte"
    ;;
  *)
    echo "==> bytecode" >&2
    ocamlfind ocamlc -package str -linkpkg "$SRC" -o "$OUTDIR/$BASE.byte" >/dev/null 2>&1 \
      || ocamlc "$SRC" -o "$OUTDIR/$BASE.byte"
    ;;
esac

echo "==> wasm_of_ocaml --effects=native --enable wasi" >&2
PATH="$BINARYEN_BIN:$PATH" "$WOO" compile --effects=native --enable wasi \
  ${EXTRA_RUNTIME:-} "$OUTDIR/$BASE.byte" -o "$OUTDIR/$BASE.js"
cp "$OUTDIR/$BASE.assets/code.wasm" "$OUTDIR/$BASE.wasm"

echo "==> wasi shim (argv: $BASE $*)" >&2
python3 "$HERE/wasi_shim_gen.py" -o "$OUTDIR/shim.wat" "$BASE" "$@"
"$WASM" -d -i "$OUTDIR/shim.wat" -o "$OUTDIR/shim.wasm"

echo "==> merge" >&2
"$BINARYEN_BIN/wasm-merge" $MERGE_FLAGS \
  "$OUTDIR/$BASE.wasm" "main" "$OUTDIR/shim.wasm" "wasi_snapshot_preview1" \
  -o "$OUTDIR/$BASE.merged.wasm"

echo "==> package as script" >&2
python3 "$HERE/wasm2wast.py" "$OUTDIR/$BASE.merged.wasm" -o "$OUTDIR/$BASE.wast"

echo "==> run on reference interpreter" >&2
"$WASM" -i "$OUTDIR/$BASE.wast" 2>&1 \
  | sed -n 's/^\([0-9]\+\) : i32$/\1/p' \
  | python3 -c 'import sys;sys.stdout.write("".join(chr(int(l)) for l in sys.stdin if l.strip()))'
