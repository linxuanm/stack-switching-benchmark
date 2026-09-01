#!/usr/bin/env bash
# bench-common.sh — shared driver for run-wizard.sh / run-wasmtime.sh.
#
# The engine script defines, BEFORE sourcing this file:
#   ENGINE        short engine name (used in output and result files)
#   engine_run    a function: engine_run <kind> <wasm-file> [args...]
#                 kind is "wasi" (module has a WASI _start; args become argv) or
#                 "invoke:main" (invoke the exported nullary function `main`).
#                 It must exec the engine on the module; stdout/stderr may be noisy —
#                 the driver redirects them to a log.
#
# Usage (via the engine scripts):
#   ./run-<engine>.sh --repeat N [--only pat] [--skip pat] [--timeout SECS] [--list]
#
# Behaviour: for each benchmark, one untimed warm-up run, then N timed runs
# (wall clock, whole process). A run "passes" if it exits 0 within the timeout.
# Per-run times go to microbench/results/<engine>-<stamp>.csv; the last run's
# output is kept at microbench/results/<engine>-<benchmark>.log.

set -u
BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WASM_DIR="$BENCH_ROOT/microbench/wasm"          # <-- the hardcoded benchmark directory
RESULTS_DIR="$BENCH_ROOT/microbench/results"

# Benchmark table: file | args | kind.  Files live in $WASM_DIR.
# (itersum_switch is known to fail on Wizard's compiler tier and c10m/skynet on
#  upstream Wasmtime — kept on purpose; failures are reported, not hidden.
#  See microbench/README.md.)
BENCHMARKS=(
  "itersum_wasmfx.wasm|1000000|wasi"
  "itersum_switch_wasmfx.wasm|1000000|wasi"
  "pingpong_checked.wasm||invoke:main"
  "sieve_wasmfx.wasm|500|wasi"
  "treesum_wasmfx.wasm|4|wasi"
  "state_wasmfx.wasm||wasi"
  "skynet_wasmfx.wasm||wasi"
  "c10m_wasmfx.wasm||wasi"
  # OCaml effect benchmarks (benchmark/benches/multicore/multicore-effects via wasm_of_ocaml
  # --effects=native; rebuild: microbench/build-ocaml.sh). The effect-using ones are
  # Wizard-only today: upstream Wasmtime refuses them ("Stack switching feature not
  # compatible with GC, yet"); rec_seq_fib is the no-effects control and runs on both.
  "ocaml_effect_throughput_perform.wasm|200000|wasi"
  "ocaml_effect_throughput_perform_drop.wasm|50000|wasi"
  "ocaml_effect_throughput_val.wasm|1000000|wasi"
  "ocaml_rec_eff_fib.wasm|1 28|wasi"
  "ocaml_rec_seq_fib.wasm|1 28|wasi"
  "ocaml_eratosthenes.wasm|1000|wasi"
  "ocaml_algorithmic_differentiation.wasm|300|wasi"
)

REPEAT=5
ONLY=""
SKIP=""
TIMEOUT_SECS=120
LIST_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repeat)  REPEAT="$2"; shift 2 ;;
    --repeat=*) REPEAT="${1#*=}"; shift ;;
    --only)    ONLY="$2"; shift 2 ;;
    --skip)    SKIP="$2"; shift 2 ;;
    --timeout) TIMEOUT_SECS="$2"; shift 2 ;;
    --list)    LIST_ONLY=1; shift ;;
    -h|--help)
      sed -n '2,20p' "$BENCH_ROOT/bench-common.sh"; exit 0 ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
done
case "$REPEAT" in (*[!0-9]*|"") echo "--repeat needs a positive integer" >&2; exit 2 ;; esac
[ "$REPEAT" -ge 1 ] || { echo "--repeat needs a positive integer" >&2; exit 2; }

command -v engine_run >/dev/null || { echo "bench-common.sh must be sourced by an engine script" >&2; exit 2; }

if [ "$LIST_ONLY" = 1 ]; then
  for entry in "${BENCHMARKS[@]}"; do IFS='|' read -r f a k <<<"$entry"; printf "%-30s args='%s' kind=%s\n" "$f" "$a" "$k"; done
  exit 0
fi

mkdir -p "$RESULTS_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
CSV="$RESULTS_DIR/$ENGINE-$STAMP.csv"
echo "engine,benchmark,args,run,seconds,exit_code" > "$CSV"

now_ns() { date +%s%N; }

echo "== $ENGINE microbenchmarks: $REPEAT timed run(s) each (+1 warm-up), timeout ${TIMEOUT_SECS}s"
echo "== wasm dir: $WASM_DIR"
printf "%-28s %-9s %5s  %9s %9s %9s   %s\n" "benchmark" "args" "runs" "min" "median" "mean" "status"

overall_rc=0
for entry in "${BENCHMARKS[@]}"; do
  IFS='|' read -r file args kind <<<"$entry"
  name="${file%.wasm}"
  [ -n "$ONLY" ] && [[ "$name" != *"$ONLY"* ]] && continue
  [ -n "$SKIP" ] && [[ "$name" == *"$SKIP"* ]] && continue
  wasm="$WASM_DIR/$file"
  if [ ! -f "$wasm" ]; then
    printf "%-28s %-9s %5s  %9s %9s %9s   %s\n" "$name" "$args" "-" "-" "-" "-" "MISSING ($wasm)"
    overall_rc=1; continue
  fi
  log="$RESULTS_DIR/$ENGINE-$name.log"

  # one warm-up run (untimed, same failure detection)
  # shellcheck disable=SC2086
  timeout "$TIMEOUT_SECS" bash -c 'engine_run "$@"' _ "$kind" "$wasm" $args >"$log" 2>&1
  rc=$?
  if [ $rc -ne 0 ]; then
    st="FAIL (rc=$rc$( [ $rc -eq 124 ] && echo ', timeout'))"
    printf "%-28s %-9s %5s  %9s %9s %9s   %s\n" "$name" "$args" "0" "-" "-" "-" "$st  [log: ${log#"$BENCH_ROOT"/}]"
    echo "$ENGINE,$name,$args,warmup,,${rc}" >> "$CSV"
    overall_rc=1; continue
  fi

  times=()
  fail_rc=0
  for i in $(seq 1 "$REPEAT"); do
    t0=$(now_ns)
    # shellcheck disable=SC2086
    timeout "$TIMEOUT_SECS" bash -c 'engine_run "$@"' _ "$kind" "$wasm" $args >"$log" 2>&1
    rc=$?
    t1=$(now_ns)
    secs=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.4f", (b-a)/1e9}')
    echo "$ENGINE,$name,$args,$i,$secs,$rc" >> "$CSV"
    if [ $rc -ne 0 ]; then fail_rc=$rc; break; fi
    times+=("$secs")
  done

  if [ $fail_rc -ne 0 ]; then
    printf "%-28s %-9s %5s  %9s %9s %9s   %s\n" "$name" "$args" "${#times[@]}" "-" "-" "-" "FAIL (rc=$fail_rc)  [log: ${log#"$BENCH_ROOT"/}]"
    overall_rc=1; continue
  fi
  stats=$(printf "%s\n" "${times[@]}" | sort -n | awk '
    { v[NR] = $1; s += $1 }
    END {
      min = v[1]
      med = (NR % 2) ? v[(NR+1)/2] : (v[NR/2] + v[NR/2+1]) / 2
      printf "%.3fs %.3fs %.3fs", min, med, s/NR
    }')
  read -r tmin tmed tmean <<<"$stats"
  printf "%-28s %-9s %5s  %9s %9s %9s   ok\n" "$name" "$args" "$REPEAT" "$tmin" "$tmed" "$tmean"
done
echo "== per-run times: ${CSV#"$BENCH_ROOT"/}"
exit $overall_rc
