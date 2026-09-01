#!/usr/bin/env bash
# build-all.sh — the one place that builds everything in this repo.
#
#   git clone --recurse-submodules <repo> && cd <repo> && ./build-all.sh
#   ./run-wizard.sh --repeat 5; ./run-wasmtime.sh --repeat 5   # then time the suites ...
#   ./runtime-compare.sh                                      # ... or profile both engines
#
# Steps (in order; each can be skipped):
#   submodules  git submodule update --init for wizard-engine, wasmtime, fiber-c, benches
#   wizard      wizard-engine/build.sh wizeng x86-64-linux            (needs Virgil v3c)
#   wasmtime    cargo +<toolchain> build --release --bin wasmtime     (needs rustup; >= 1.96)
#   fiberc      fiber-c benchmarks -> microbench/wasm/*_wasmfx.wasm   (needs wasi-sdk, binaryen,
#               reference interpreter), incl. the switch module with its two toolchain
#               workarounds (research/COMPILER_DIFF.md 2.2: tag reorder + 0xE5->0xE6 patch)
#   pingpong    microbench/wasm/pingpong_checked.wasm from research/compiler-diff/pingpong.wat
#   ocaml       benches/multicore/multicore-effects -> microbench/wasm/ocaml_*.wasm
#               (needs opam env with ocamlfind, and the wasm_of_ocaml master build)
#   smoke       one tiny run per engine to confirm the setup works
#
# Usage: ./build-all.sh [--skip step[,step...]] [--only step[,step...]] [--list]
# Tool locations (defaults match CLAUDE.md "Toolchain on this machine"; override via env):
#   V3C, RUST_TOOLCHAIN (1.98.0), WASI_SDK, BINARYEN, WASM_INTERP, WASM_OF_OCAML
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-1.98.0}"
WASI_SDK="${WASI_SDK:-$HOME/workspace/benchfx/tools/wasi-sdk/wasi-sdk-22.0}"
BINARYEN="${BINARYEN:-$HOME/dev_path/binaryen}"
WASM_INTERP="${WASM_INTERP:-$HOME/.opam/default/bin/wasm}"
WASM_OF_OCAML="${WASM_OF_OCAML:-$HOME/workspace/js_of_ocaml/_build/default/compiler/bin-wasm_of_ocaml/wasm_of_ocaml.exe}"
export WASI_SDK BINARYEN WASM_INTERP WASM_OF_OCAML

STEPS=(submodules wizard wasmtime fiberc pingpong ocaml smoke)
SKIP=""; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --skip) SKIP="$2"; shift 2 ;;
    --skip=*) SKIP="${1#*=}"; shift ;;
    --only) ONLY="$2"; shift 2 ;;
    --only=*) ONLY="${1#*=}"; shift ;;
    --list) printf '%s\n' "${STEPS[@]}"; exit 0 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
done
enabled() { # step name
  case ",$SKIP," in *",$1,"*) return 1 ;; esac
  [ -z "$ONLY" ] && return 0
  case ",$ONLY," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

BUILD="$ROOT/microbench/build"       # intermediates (gitignored)
WASM_OUT="$ROOT/microbench/wasm"     # what run-wizard.sh / run-wasmtime.sh consume
mkdir -p "$BUILD" "$WASM_OUT"
LOG="$BUILD/build-all.log"; : > "$LOG"

declare -A STATUS
say()  { printf '\n==> %s\n' "$*"; }
run_step() { # name  fn
  local name="$1" fn="$2"
  if ! enabled "$name"; then STATUS[$name]="skipped"; return 0; fi
  say "$name"
  if "$fn" >>"$LOG" 2>&1; then STATUS[$name]="ok"; echo "    ok"
  else STATUS[$name]="FAILED"; echo "    FAILED — see $LOG (tail below)"; tail -8 "$LOG" | sed 's/^/    | /'; fi
}

step_submodules() {
  git submodule update --init wizard-engine wasmtime fiber-c benches
}

step_wizard() {
  command -v "${V3C:-v3c}" >/dev/null || { echo "Virgil compiler (v3c) not on PATH; install Virgil (https://github.com/titzer/virgil) or set V3C"; return 1; }
  ( cd wizard-engine && ./build.sh wizeng x86-64-linux )
  test -x wizard-engine/bin/wizeng.x86-64-linux
}

step_wasmtime() {
  command -v rustup >/dev/null || { echo "rustup not found; install from https://rustup.rs (wasmtime needs Rust >= 1.96)"; return 1; }
  if ! rustup toolchain list | grep -q "^$RUST_TOOLCHAIN"; then
    echo "installing Rust toolchain $RUST_TOOLCHAIN (one-time, network)"
    rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal
  fi
  ( cd wasmtime && cargo "+$RUST_TOOLCHAIN" build --release --bin wasmtime )
  test -x wasmtime/target/release/wasmtime
}

check_wasm_tools() {
  [ -x "$WASI_SDK/bin/clang" ] || { echo "wasi-sdk not found at $WASI_SDK (set WASI_SDK; wasi-sdk-22 from https://github.com/WebAssembly/wasi-sdk/releases)"; return 1; }
  [ -x "$BINARYEN/bin/wasm-merge" ] || { echo "binaryen not found at $BINARYEN (set BINARYEN; needs --enable-stack-switching, v124 works)"; return 1; }
  [ -x "$WASM_INTERP" ] || { echo "reference interpreter not found at $WASM_INTERP (set WASM_INTERP; build ~/workspace/specfx/interpreter)"; return 1; }
}

# Patch old-encoding `switch` opcodes (0xE5 ct tag) to the current 0xE6 — the reference
# interpreter and binaryen predate the renumbering (research/COMPILER_DIFF.md 2.2 item 1).
patch_switch() { # file  ct-byte  tag-byte  expected-count
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys
path, ct, tag, want = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
data = bytearray(open(path, 'rb').read())
def leb(b, i):
    r = s = 0
    while True:
        x = b[i]; i += 1; r |= (x & 0x7f) << s; s += 7
        if not x & 0x80: return r, i
i, code = 8, None
while i < len(data):
    sid = data[i]; size, j = leb(data, i + 1)
    if sid == 10: code = (j, j + size)
    i = j + size
pat = bytes([0xE5, ct, tag])
hits = [k for k in range(code[0], code[1]) if data[k:k+3] == pat]
assert len(hits) == want, f"{path}: expected {want} switch sites, found {[hex(h) for h in hits]}"
for h in hits: data[h] = 0xE6
open(path, 'wb').write(data)
print(f"{path}: patched {len(hits)} switch site(s)")
PY
}

step_fiberc() {
  check_wasm_tools || return 1
  local b=research/compiler-diff/build-fiber-c.sh
  # plain (resume/suspend) benchmarks — exactly the fiber-c Makefile pipeline
  local n
  for n in itersum state sieve treesum c10m skynet; do
    OUT="$BUILD/fiberc" "$b" "$n"
    cp "$BUILD/fiberc/${n}_wasmfx.wasm" "$WASM_OUT/"
  done
  # itersum_switch needs the two workarounds: declare $cancel first (so resume_throw's
  # immediates read the same under Wizard's validator), then the opcode patch.
  OUT="$BUILD/fiberc" "$b" itersum_switch   # produces shim + pre.wasm + unopt merge (Makefile stops here too)
  python3 - "$BUILD/fiberc" <<'PY'
import sys
d = sys.argv[1]
src = open(f"{d}/fiber_switch_wasmfx_imports.wat").read()
tags = ['  (tag $yield (result i32))\n', '  (tag $switch-return (param i32 i32))\n', '  (tag $cancel (param i32 i32))\n']
for t in tags: assert t in src, t
for t in tags: src = src.replace(t, '', 1)
i = src.index('  (table $conts')
src = src[:i] + tags[2] + tags[0] + tags[1] + '\n' + src[i:]
open(f"{d}/fiber_switch_wasmfx_imports.tagreorder.wat", 'w').write(src)
PY
  "$WASM_INTERP" -d -i "$BUILD/fiberc/fiber_switch_wasmfx_imports.tagreorder.wat" -o "$BUILD/fiberc/fiber_switch_wasmfx_imports.tagreorder.wasm"
  "$BINARYEN/bin/wasm-merge" --enable-nontrapping-float-to-int --enable-exception-handling \
      --enable-reference-types --enable-multivalue --enable-bulk-memory --enable-gc \
      --enable-stack-switching --enable-multimemory \
      "$BUILD/fiberc/fiber_switch_wasmfx_imports.tagreorder.wasm" fiber_switch_wasmfx_imports \
      "$BUILD/fiberc/itersum_switch_wasmfx.pre.wasm" main \
      -o "$WASM_OUT/itersum_switch_wasmfx.wasm"
  patch_switch "$WASM_OUT/itersum_switch_wasmfx.wasm" 13 1 1   # switch $ct2(=type 13) $yield(=tag 1 after reorder)
}

step_pingpong() {
  check_wasm_tools || return 1
  python3 - "$ROOT" "$BUILD" <<'PY'
import sys
root, build = sys.argv[1], sys.argv[2]
N = 2_000_000
expected = (N * (N - 1) // 2) & 0xFFFFFFFF
if expected >= 2**31: expected -= 2**32
src = open(f"{root}/research/compiler-diff/pingpong.wat").read()
src = src.replace('(func $main (export "main") (param $n i32) (result i32)',
                  '(func $run (param $n i32) (result i32)')
src = src.replace('(elem declare func $producer $consumer)',
                  '(elem declare func $producer $consumer)\n  (func (export "main") (result i32)\n'
                  f'    (i32.ne (call $run (i32.const {N})) (i32.const {expected})))')
open(f"{build}/pingpong_checked.wat", 'w').write(src)
print(f"pingpong_checked: N={N} expected={expected}")
PY
  "$WASM_INTERP" -d -i "$BUILD/pingpong_checked.wat" -o "$WASM_OUT/pingpong_checked.wasm"
  patch_switch "$WASM_OUT/pingpong_checked.wasm" 1 0 3         # switch $ct(=type 1) $yield(=tag 0), 3 sites
}

step_ocaml() {
  if ! command -v ocamlfind >/dev/null; then
    command -v opam >/dev/null && eval "$(opam env)" || true
  fi
  command -v ocamlfind >/dev/null || command -v ocamlc >/dev/null || { echo "no ocamlc/ocamlfind (opam switch not set up)"; return 1; }
  [ -x "$WASM_OF_OCAML" ] || { echo "wasm_of_ocaml not found at $WASM_OF_OCAML (build js_of_ocaml master; see CLAUDE.md)"; return 1; }
  microbench/build-ocaml.sh
}

step_smoke() {
  local rc=0 out
  if [ -x wizard-engine/bin/wizeng.x86-64-linux ]; then
    out=$(wizard-engine/bin/wizeng.x86-64-linux --ext:all --stack-size=65536 --mode=jit "$WASM_OUT/itersum_wasmfx.wasm" 1000 2>&1)       && echo "wizard   itersum 1000 -> $out" || { echo "wizard smoke FAILED: $out"; rc=1; }
  else echo "wizard binary missing"; rc=1; fi
  if [ -x wasmtime/target/release/wasmtime ]; then
    out=$(wasmtime/target/release/wasmtime run -W=exceptions,function-references,gc,stack-switching,tail-call "$WASM_OUT/itersum_wasmfx.wasm" 1000 2>&1)       && echo "wasmtime itersum 1000 -> $out" || { echo "wasmtime smoke FAILED: $out"; rc=1; }
  else echo "wasmtime binary missing"; rc=1; fi
  return $rc
}

run_step submodules step_submodules
run_step wizard     step_wizard
run_step wasmtime   step_wasmtime
run_step fiberc     step_fiberc
run_step pingpong   step_pingpong
run_step ocaml      step_ocaml
run_step smoke      step_smoke

say "summary"
overall=0
for s in "${STEPS[@]}"; do
  printf '    %-11s %s\n' "$s" "${STATUS[$s]:-skipped}"
  [ "${STATUS[$s]:-}" = "FAILED" ] && overall=1
done
if [ $overall -eq 0 ]; then
  echo
  echo "Ready. Next: ./run-wizard.sh --repeat 5   and   ./run-wasmtime.sh --repeat 5"
else
  echo
  echo "Some steps failed — details in $LOG"
fi
exit $overall
