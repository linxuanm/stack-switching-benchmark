#!/usr/bin/env bash
# build-all.sh — the one place that builds everything: the dependencies under dependencies/ and
# the benchmark modules under microbench/wasm/.
#
#   git clone <repo> && cd <repo> && ./build-all.sh   # the first step fetches the submodules
#   (--recurse-submodules also works but pulls the engines' own third-party submodules too)
#   ./run-wizard.sh --repeat 5; ./run-wasmtime.sh --repeat 5   # then time the suites ...
#   ./runtime-compare.sh                                      # ... or profile both engines
#
# Layout: benchmark/ holds the benchmark sources (fiber-c, benches, macro-benches, angstrom);
# dependencies/ holds the engines and the toolchain — pinned submodules, plus the wasi-sdk
# download and a local opam switch. env.sh points every tool variable into dependencies/ and
# every script sources it. A variable set beforehand (environment or ./build.env, template
# build.env.example) wins, and the step that would build that dependency is skipped.
#
# Steps (in order; each can be skipped):
#   submodules   git submodule update --init for everything built here
#   virgil       dependencies/virgil: bootstrap the compiler from the pinned sources
#                (bin/dev/aeneas bootstrap -> bin/current/x86-64-linux/Aeneas; the checked-in
#                stable binary is only used to build it and cannot compile Wizard itself)
#   wizard       dependencies/wizard-engine/build.sh wizeng x86-64-linux
#   wasmtime     cargo +$RUST_TOOLCHAIN build --release --bin wasmtime            (needs rustup)
#   wasi-sdk     wasi-sdk 22: download (105 MB, sha256-checked) into dependencies/wasi-sdk
#   binaryen     dependencies/binaryen -> dependencies/binaryen-build (cmake; needs a C++17
#                compiler; the vendored LLVM DWARF subset is part of the build)
#   ocaml        local opam switch dependencies/ocaml: OCaml 5.4.0 + dune, menhir, ppxlib, ...
#                (needs opam >= 2.1 after `opam init`; compiles OCaml, ~10 min the first time)
#   specfx       dependencies/specfx/interpreter: the WasmFX reference interpreter (`wasm`)
#   jsoo         dependencies/js_of_ocaml: wasm_of_ocaml.exe
#   fiberc       fiber-c benchmarks -> microbench/wasm/*_wasmfx.wasm, incl. the switch module
#                with its two toolchain workarounds (research/COMPILER_DIFF.md 2.2)
#   pingpong     microbench/wasm/pingpong_checked.wasm from research/compiler-diff/pingpong.wat
#   ocaml-bench  benchmark/benches/multicore/multicore-effects -> microbench/wasm/ocaml_*.wasm
#   smoke        one tiny run per engine to confirm the setup works
#
# Usage: ./build-all.sh [--skip step[,step...]] [--only step[,step...]] [--list]
# Host prerequisites (not vendored): git, curl, tar, python3, rustup, opam, cmake and a C++
# compiler (ninja is used when present). Everything else comes from dependencies/.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi   # `sh <script>` -> re-run under bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
. "$ROOT/env.sh"

STEPS=(submodules virgil wizard wasmtime wasi-sdk binaryen ocaml specfx jsoo fiberc pingpong ocaml-bench smoke)
SKIP=""; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --skip) SKIP="$2"; shift 2 ;;
    --skip=*) SKIP="${1#*=}"; shift ;;
    --only) ONLY="$2"; shift 2 ;;
    --only=*) ONLY="${1#*=}"; shift ;;
    --list) printf '%s\n' "${STEPS[@]}"; exit 0 ;;
    -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { print }' "$0"; exit 0 ;;
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
echo "tools (from env.sh):"
for v in WIZENG WASMTIME V3C WASI_SDK BINARYEN WASM_INTERP WASM_OF_OCAML_EXE OCAML_SWITCH RUST_TOOLCHAIN; do
  printf '    %-14s %s\n' "$v" "${!v}"
done

# in_deps VAR: true when the variable points into dependencies/, i.e. this script owns it.
in_deps() { case "${!1}" in "$DEPS"/*) return 0 ;; *) return 1 ;; esac; }
# override VAR: when the tool comes from elsewhere, say so and let the step return early.
override() { in_deps "$1" && return 1; echo "using $1=${!1} (override — not built here)"; return 0; }
# need_tool VAR "what it is" step [path-under-it-that-must-exist]: never guess, say what to do.
need_tool() {
  local var="$1" what="$2" step="$3" sub="${4:-}" val="${!1}"
  if [ ! -e "$val$sub" ]; then
    if in_deps "$var"; then echo "$var: $val$sub is missing — $what. Run: ./build-all.sh --only $step"
    else echo "$var=$val (override), but $val$sub does not exist — $what."; fi
    return 1
  fi
}

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
  local mods=(dependencies/virgil dependencies/wizard-engine dependencies/wasmtime
              dependencies/binaryen dependencies/specfx dependencies/js_of_ocaml
              benchmark/fiber-c benchmark/benches)
  # Nested submodules (binaryen's, wasmtime's third_party) are deliberately not initialised.
  # A transient network failure is the common failure here; a retry resumes where it stopped.
  git submodule update --init "${mods[@]}" \
    || { echo "submodule fetch failed; retrying once"; git submodule update --init "${mods[@]}"; }
  # benchmark/macro-benches and benchmark/angstrom are not built by anything here:
  #   git submodule update --init benchmark/macro-benches benchmark/angstrom
}

step_virgil() {
  override V3C && return 0
  [ -e "$VIRGIL_LOC/lib/util/Vector.v3" ] || { echo "Virgil sources not found under $VIRGIL_LOC (submodules step?)"; return 1; }
  if [ ! -x "$V3C" ]; then
    [ -x "$VIRGIL_LOC/bin/stable/x86-64-linux/Aeneas" ] || { echo "no stable Virgil binary for x86-64-linux under $VIRGIL_LOC/bin/stable (needed to bootstrap)"; return 1; }
    # Build the compiler from the pinned sources: stable -> bin/bootstrap -> bin/current (both ignored
    # by Virgil's .gitignore). With V3C unset, aeneas starts from the stable binary.
    ( cd "$VIRGIL_LOC" && env -u V3C bin/dev/aeneas bootstrap x86-64-linux ) || return 1
  fi
  [ -x "$V3C" ] || { echo "bootstrap did not produce $V3C"; return 1; }
  # aeneas' final .setup-v3c step turns the tracked wrapper bin/v3c into a symlink; hide that from
  # git as upstream's own script intends (bin/v3c is also in Virgil's .gitignore).
  ( cd "$VIRGIL_LOC" && git update-index --assume-unchanged bin/v3c 2>/dev/null ) || true
  echo "v3c: $V3C ($("$V3C" -version 2>&1 | head -1))"
}

step_wizard() {
  override WIZENG && return 0
  need_tool V3C "the Virgil compiler" virgil || return 1
  ( cd "$DEPS/wizard-engine" && ./build.sh wizeng x86-64-linux )
  test -x "$WIZENG"
}

step_wasmtime() {
  override WASMTIME && return 0
  command -v rustup >/dev/null || { echo "rustup not found; install from https://rustup.rs (wasmtime needs Rust >= 1.96)"; return 1; }
  if ! rustup toolchain list | grep -q "^$RUST_TOOLCHAIN"; then
    echo "installing Rust toolchain $RUST_TOOLCHAIN (one-time, network)"
    rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal
  fi
  ( cd "$DEPS/wasmtime" && cargo "+$RUST_TOOLCHAIN" build --release --bin wasmtime )
  test -x "$WASMTIME"
}

WASI_SDK_URL=https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-22/wasi-sdk-22.0-linux.tar.gz
WASI_SDK_SHA256=fa46b8f1b5170b0fecc0daf467c39f44a6d326b80ced383ec4586a50bc38d7b8
step_wasi_sdk() {
  override WASI_SDK && return 0
  if [ -x "$WASI_SDK/bin/clang" ]; then echo "already present: $WASI_SDK"; return 0; fi
  local tarball="$DEPS/$(basename "$WASI_SDK_URL")"
  if ! echo "$WASI_SDK_SHA256  $tarball" | sha256sum -c --status 2>/dev/null; then
    command -v curl >/dev/null || { echo "curl not found (needed to download wasi-sdk)"; return 1; }
    echo "downloading $WASI_SDK_URL"
    curl -fL --retry 3 -o "$tarball" "$WASI_SDK_URL" || return 1
    echo "$WASI_SDK_SHA256  $tarball" | sha256sum -c --status || { echo "sha256 mismatch for $tarball"; return 1; }
  fi
  rm -rf "$WASI_SDK"; mkdir -p "$WASI_SDK"
  tar xzf "$tarball" -C "$WASI_SDK" --strip-components=1
  test -x "$WASI_SDK/bin/clang"
}

step_binaryen() {
  override BINARYEN && return 0
  command -v cmake >/dev/null || { echo "cmake not found (binaryen needs cmake and a C++17 compiler)"; return 1; }
  local gen=()
  command -v ninja >/dev/null && gen=(-G Ninja)
  cmake -S "$DEPS/binaryen" -B "$BINARYEN" ${gen[@]+"${gen[@]}"} -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_TESTS=OFF -DBUILD_STATIC_LIB=OFF -DENABLE_WERROR=OFF -DBUILD_LLVM_DWARF=ON || return 1
  cmake --build "$BINARYEN" -j"$(nproc)" --target wasm-opt wasm-merge wasm-metadce wasm-as wasm-dis || return 1
  test -x "$BINARYEN/bin/wasm-merge"
}

OCAML_VERSION=5.4.0
OCAML_PACKAGES=(dune.3.20.2 menhir.20231231 menhirLib.20231231 menhirSdk.20231231 sedlex.3.7
                ppxlib.0.37.0 cmdliner.2.0.0 yojson.2.1.2 ocamlfind.1.9.6 ocaml-compiler-libs.v0.17.0)
step_ocaml() {
  if override OCAML_SWITCH; then eval "$(opam env --switch="$OCAML_SWITCH" --set-switch)"; return 0; fi
  command -v opam >/dev/null || { echo "opam not found (https://opam.ocaml.org/doc/Install.html)"; return 1; }
  opam switch list >/dev/null 2>&1 || { echo "opam is not initialised — run: opam init --bare"; return 1; }
  if [ ! -d "$OCAML_SWITCH/_opam" ]; then
    # a registration left behind by a deleted checkout blocks re-creation at the same path
    if opam switch list --short 2>/dev/null | grep -qx "$OCAML_SWITCH"; then
      opam switch remove "$OCAML_SWITCH" --yes || true
    fi
    echo "creating opam switch $OCAML_SWITCH with OCaml $OCAML_VERSION (compiles OCaml; several minutes)"
    mkdir -p "$OCAML_SWITCH"
    opam switch create "$OCAML_SWITCH" "ocaml-base-compiler.$OCAML_VERSION" --no-install --yes || return 1
  fi
  opam install --switch="$OCAML_SWITCH" --yes "${OCAML_PACKAGES[@]}" \
    || { echo "opam install failed — if a version is unknown to your opam repository, run 'opam update' and retry"; return 1; }
  eval "$(opam env --switch="$OCAML_SWITCH" --set-switch)"
  echo "ocaml $(ocamlfind ocamlc -version) at $OCAML_SWITCH"
}

step_specfx() {
  override WASM_INTERP && return 0
  command -v dune >/dev/null || { echo "dune not on PATH — the ocaml step provides it"; return 1; }
  ( cd "$DEPS/specfx/interpreter" && make )
  test -x "$WASM_INTERP"
}

step_jsoo() {
  override WASM_OF_OCAML_EXE && return 0
  command -v dune >/dev/null || { echo "dune not on PATH — the ocaml step provides it"; return 1; }
  need_tool BINARYEN "binaryen (the wasm runtime build runs wasm-as/wasm-merge)" binaryen /bin/wasm-merge || return 1
  ( cd "$DEPS/js_of_ocaml" && dune build compiler/bin-wasm_of_ocaml/wasm_of_ocaml.exe )
  test -x "$WASM_OF_OCAML_EXE"
}

check_wasm_tools() {
  need_tool WASI_SDK "wasi-sdk 22" wasi-sdk /bin/clang || return 1
  need_tool BINARYEN "binaryen (wasm-merge, wasm-opt)" binaryen /bin/wasm-merge || return 1
  need_tool WASM_INTERP "the WasmFX reference interpreter" specfx || return 1
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
  need_tool WASM_INTERP "the WasmFX reference interpreter" specfx || return 1
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

step_ocaml_bench() {
  command -v ocamlfind >/dev/null || { echo "ocamlfind not on PATH — the ocaml step provides it (or set OCAML_SWITCH)"; return 1; }
  need_tool WASM_OF_OCAML_EXE "wasm_of_ocaml.exe" jsoo || return 1
  need_tool BINARYEN "binaryen (wasm_of_ocaml runs wasm-opt/wasm-merge)" binaryen /bin/wasm-opt || return 1
  microbench/build-ocaml.sh
}

step_smoke() {
  local rc=0 out
  if [ -x "$WIZENG" ]; then
    out=$("$WIZENG" --ext:all --stack-size=65536 --mode=jit "$WASM_OUT/itersum_wasmfx.wasm" 1000 2>&1) \
      && echo "wizard   itersum 1000 -> $out" || { echo "wizard smoke FAILED: $out"; rc=1; }
  else echo "wizard binary missing ($WIZENG)"; rc=1; fi
  if [ -x "$WASMTIME" ]; then
    out=$("$WASMTIME" run -W=exceptions,function-references,gc,stack-switching,tail-call "$WASM_OUT/itersum_wasmfx.wasm" 1000 2>&1) \
      && echo "wasmtime itersum 1000 -> $out" || { echo "wasmtime smoke FAILED: $out"; rc=1; }
  else echo "wasmtime binary missing ($WASMTIME)"; rc=1; fi
  return $rc
}

run_step submodules  step_submodules
run_step virgil      step_virgil
run_step wizard      step_wizard
run_step wasmtime    step_wasmtime
run_step wasi-sdk    step_wasi_sdk
run_step binaryen    step_binaryen
run_step ocaml       step_ocaml
run_step specfx      step_specfx
run_step jsoo        step_jsoo
run_step fiberc      step_fiberc
run_step pingpong    step_pingpong
run_step ocaml-bench step_ocaml_bench
run_step smoke       step_smoke

say "summary"
overall=0
for s in "${STEPS[@]}"; do
  printf '    %-12s %s\n' "$s" "${STATUS[$s]:-skipped}"
  [ "${STATUS[$s]:-}" = "FAILED" ] && overall=1
done
if [ $overall -eq 0 ]; then
  echo
  echo "Ready. Next: ./run-wizard.sh --repeat 5   and   ./run-wasmtime.sh --repeat 5   (or: source env.sh)"
else
  echo
  echo "Some steps failed — details in $LOG"
fi
exit $overall
