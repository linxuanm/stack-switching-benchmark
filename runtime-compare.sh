#!/usr/bin/env bash
# runtime-compare.sh — where does the time go?  Profile Wizard (SPC) and Wasmtime (Cranelift)
# on the fiber-c benchmarks with perf and print, in one run, the two "where the time goes"
# tables of research/FIBER_C_COMPARE.md (sections 3 and 4) plus the JIT-only comparison.
#
#   ./build-all.sh && ./runtime-compare.sh
#
# Usage: ./runtime-compare.sh [--only pat] [--skip pat] [--freq HZ] [--timeout SECS]
#                             [--out DIR] [--list]
# Each benchmark runs twice per engine: a plain run for wall time and exit status, then the
# profiled run (perf adds ~0.2 s of its own startup, which would distort short runs).
# Output: the report on stdout and DIR/REPORT.md (default microbench/results/runtime-compare-<stamp>/),
#         next to the raw perf data, `perf script` samples, per-run symbol tables, Wizard code
#         maps, and each engine's stdout/stderr.
# Needs:  perf (sampling uses the cpu-clock software event, so no PMU is required — WSL2 works),
#         setarch, python3, and the engines + fiber-c modules that build-all.sh produces.
#         Kernel samples need kernel.perf_event_paranoid <= 1; above that the script samples
#         user space only (`cpu-clock:u`) and says so in the report.
# Env:    WIZENG, WASMTIME (from env.sh), WIZARD_FLAGS, WASMTIME_FLAGS (as in run-*.sh), PERF.
#
# Method (research/FIBER_C_COMPARE.md section 2):
#   * `perf record -e cpu-clock -F <freq>` around the whole engine process.
#   * Wizard: the SPC JIT region and the pregenerated stubs carry no ELF symbols, so a separate
#     `wizeng -tk` pass prints their addresses (`func[N].target_code` and `code start/end`
#     lines, emitted while the module is compiled). Both passes run under `setarch x86_64 -R`
#     (ASLR off), which makes the addresses identical; the map pass is cut off with `head`
#     once compilation has been traced, so it costs ~1 s regardless of the benchmark.
#   * Wasmtime: `--profile perfmap` writes /tmp/perf-<pid>.map, which perf uses to name JIT
#     frames `wasm[0]::function[N]`; function names come from the module's import/export/name
#     sections.
#   * microbench/profile-report.py classifies every sample by address, then by symbol, into
#     the clusters of the FIBER_C_COMPARE tables.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi   # `sh <script>` -> re-run under bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WASM_DIR="$ROOT/microbench/wasm"

# shellcheck disable=SC1091
. "$ROOT/env.sh"                      # WIZENG, WASMTIME (dependencies/), overridable
WIZARD_FLAGS="${WIZARD_FLAGS:---ext:all --stack-size=65536 --mode=jit}"
WASMTIME_FLAGS="${WASMTIME_FLAGS:--W=exceptions,function-references,gc,stack-switching,tail-call}"

# Benchmark | argv — the fiber-c set and sizes of research/FIBER_C_COMPARE.md.
BENCHMARKS=(
  "itersum|5000000"
  "state|"
  "treesum|4"
  "c10m|"
  "sieve|2000"
  "skynet|"
)

FREQ=4999; TIMEOUT_SECS=600; ONLY=""; SKIP=""; OUT=""; LIST_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY="$2"; shift 2 ;;      --only=*) ONLY="${1#*=}"; shift ;;
    --skip) SKIP="$2"; shift 2 ;;      --skip=*) SKIP="${1#*=}"; shift ;;
    --freq) FREQ="$2"; shift 2 ;;      --freq=*) FREQ="${1#*=}"; shift ;;
    --timeout) TIMEOUT_SECS="$2"; shift 2 ;; --timeout=*) TIMEOUT_SECS="${1#*=}"; shift ;;
    --out) OUT="$2"; shift 2 ;;        --out=*) OUT="${1#*=}"; shift ;;
    --list) LIST_ONLY=1; shift ;;
    -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { print }' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
done
if [ "$LIST_ONLY" = 1 ]; then
  for b in "${BENCHMARKS[@]}"; do printf '%-10s %s\n' "${b%%|*}" "${b#*|}"; done; exit 0
fi

fail() { echo "runtime-compare.sh: $*" >&2; exit 1; }

# ---- prerequisites -----------------------------------------------------------------------
[ "$(uname -m)" = x86_64 ] || fail "x86-64 Linux only (Wizard's SPC tier and the code-map trick are x86-64)"
[ -x "$WIZENG" ] || fail "Wizard binary not found at $WIZENG — run ./build-all.sh"
[ -x "$WASMTIME" ] || fail "Wasmtime binary not found at $WASMTIME — run ./build-all.sh"
for b in "${BENCHMARKS[@]}"; do
  [ -f "$WASM_DIR/${b%%|*}_wasmfx.wasm" ] || fail "$WASM_DIR/${b%%|*}_wasmfx.wasm missing — run ./build-all.sh (fiberc step)"
done
command -v setarch >/dev/null || fail "setarch (util-linux) not found"
command -v python3 >/dev/null || fail "python3 not found"

# perf: $PERF, then PATH, then any linux-tools install (on WSL2 /usr/bin/perf is a wrapper
# that rejects the Microsoft kernel; the versioned binary underneath works fine with cpu-clock).
perf_works() { [ -x "$1" ] && "$1" record -q -e cpu-clock -o /dev/null -- true >/dev/null 2>&1; }
find_perf() {
  local c
  for c in "${PERF:-}" "$(command -v perf 2>/dev/null)"; do
    [ -n "$c" ] && perf_works "$c" && { echo "$c"; return 0; }
  done
  for c in $(ls -1 /usr/lib/linux-tools-*/perf /usr/lib/linux-tools/*/perf 2>/dev/null | sort -rV); do
    perf_works "$c" && { echo "$c"; return 0; }
  done
  return 1
}
PERF_BIN="$(find_perf)" || fail "no working perf found (tried \$PERF, PATH, /usr/lib/linux-tools-*/perf).
  Install linux-tools for your kernel (Debian/Ubuntu: apt install linux-tools-common linux-tools-\$(uname -r);
  on WSL2 any linux-tools-<version> package works — set PERF=/usr/lib/linux-tools-<version>/perf).
  If perf exists but 'perf record -e cpu-clock' fails, check kernel.perf_event_paranoid (needs <= 2)."
PARANOID="$(sysctl -n kernel.perf_event_paranoid 2>/dev/null || echo '?')"
EVENT=cpu-clock; NOTE=""
if [ "$PARANOID" != "?" ] && [ "$PARANOID" -gt 1 ]; then
  EVENT=cpu-clock:u
  NOTE="kernel.perf_event_paranoid=$PARANOID: user-space samples only; the kernel rows are empty (sysctl kernel.perf_event_paranoid=1 to include them)"
fi

# ---- output dir ----------------------------------------------------------------------------
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${OUT:-$ROOT/microbench/results/runtime-compare-$STAMP}"
mkdir -p "$OUT"
RUNS="$OUT/runs.tsv"; : > "$RUNS"
{
  echo "date=$(date '+%Y-%m-%d %H:%M %Z')"
  echo "host=$(uname -srm)$(grep -qi microsoft /proc/version 2>/dev/null && echo ' (WSL2: no PMU, cpu-clock sampling)')"
  echo "perf=$PERF_BIN ($("$PERF_BIN" version 2>/dev/null | head -1))"
  echo "event=$EVENT"; echo "freq=$FREQ"
  echo "wizard=$WIZENG $WIZARD_FLAGS"
  echo "wasmtime=$WASMTIME run $WASMTIME_FLAGS --profile perfmap"
  [ -n "$NOTE" ] && echo "note=$NOTE"
} > "$OUT/meta.txt"

echo "== runtime-compare: perf=$PERF_BIN event=$EVENT freq=$FREQ"
echo "== out: $OUT"
[ -n "$NOTE" ] && echo "== note: $NOTE"

selected() { # name
  [ -n "$ONLY" ] && ! [[ "$1" == *"$ONLY"* ]] && return 1
  [ -n "$SKIP" ] && [[ "$1" == *"$SKIP"* ]] && return 1
  return 0
}
now_ms() { date +%s%3N; }

elapsed() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f", (b - a) / 1000 }'; }

# plain_run <engine> <bench> -- <command...>: wall clock and exit status without perf
PLAIN_RC=0; PLAIN_WALL=0
plain_run() {
  local engine="$1" bench="$2"; shift 3
  local t0 t1
  t0=$(now_ms)
  timeout -k 5 "$TIMEOUT_SECS" "$@" > "$OUT/$engine-$bench.out" 2> "$OUT/$engine-$bench.err"
  PLAIN_RC=$?
  t1=$(now_ms)
  PLAIN_WALL=$(elapsed "$t0" "$t1")
}

# record <engine> <bench> <wasm> <args> <map-file-or-dash> -- <command...>: the profiled run
record() {
  local engine="$1" bench="$2" wasm="$3" args="$4" mapf="$5"; shift 6
  local data="$OUT/$engine-$bench.perf.data" samples="$OUT/$engine-$bench.samples"
  local t0 t1 rc
  t0=$(now_ms)
  timeout -k 5 "$TIMEOUT_SECS" "$PERF_BIN" record -q -e "$EVENT" -F "$FREQ" -o "$data" -- "$@" \
    > "$OUT/$engine-$bench.perf.out" 2> "$OUT/$engine-$bench.perf.err"
  rc=$?
  t1=$(now_ms)
  "$PERF_BIN" script -i "$data" -F ip,sym,dso > "$samples" 2> "$OUT/$engine-$bench.perf-script.err" || true
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$engine" "$bench" "$wasm" "$args" \
    "$PLAIN_RC" "$PLAIN_WALL" "$samples" "$mapf" "$rc" >> "$RUNS"
  printf '   %-9s rc=%-3s %7ss plain, %7ss under perf, %7s samples\n' \
    "$engine" "$PLAIN_RC" "$PLAIN_WALL" "$(elapsed "$t0" "$t1")" "$(wc -l < "$samples")"
}

# Wizard code map: -tk traces compilation (and, later, every suspension — hence the cut-off).
wizard_map() { # <bench> <wasm> [args...]
  local bench="$1" wasm="$2"; shift 2
  local mapf="$OUT/wizard-$bench.map"
  # shellcheck disable=SC2086
  setarch x86_64 -R "$WIZENG" -tk $WIZARD_FLAGS "$wasm" "$@" 2>/dev/null | head -n 2000000 > "$mapf"
  if ! grep -q 'code end:' "$mapf" || ! grep -q 'target_code: break' "$mapf"; then
    echo "   warning: incomplete SPC code map for $bench (see $mapf); its JIT samples will be unclassified" >&2
  fi
  echo "$mapf"
}

for entry in "${BENCHMARKS[@]}"; do
  bench="${entry%%|*}"; args="${entry#*|}"
  selected "$bench" || continue
  wasm="$WASM_DIR/${bench}_wasmfx.wasm"
  echo "-- $bench $args"
  # shellcheck disable=SC2086
  mapf="$(wizard_map "$bench" "$wasm" $args)"
  # shellcheck disable=SC2086
  plain_run wizard "$bench" -- setarch x86_64 -R "$WIZENG" $WIZARD_FLAGS "$wasm" $args
  # shellcheck disable=SC2086
  record wizard "$bench" "$wasm" "$args" "$mapf" -- setarch x86_64 -R "$WIZENG" $WIZARD_FLAGS "$wasm" $args
  # shellcheck disable=SC2086
  plain_run wasmtime "$bench" -- "$WASMTIME" run $WASMTIME_FLAGS "$wasm" $args
  # shellcheck disable=SC2086
  record wasmtime "$bench" "$wasm" "$args" - -- "$WASMTIME" run $WASMTIME_FLAGS --profile perfmap "$wasm" $args
done

echo
python3 "$ROOT/microbench/profile-report.py" "$OUT"
echo "== report: $OUT/REPORT.md"
