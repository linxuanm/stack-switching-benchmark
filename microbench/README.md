# microbench — Wizard vs Wasmtime wall-clock microbenchmarks

Run from the repo root (after `./build-all.sh`, which builds both engines and every module here):

```bash
./run-wasmtime.sh --repeat 10
./run-wizard.sh   --repeat 10
# options: --only <substr>  --skip <substr>  --timeout <secs>  --list
```

`bench-common.sh` holds the shared machinery: the hardcoded benchmark directory
(`microbench/wasm/`), the benchmark/argument table, and the repeat + timing loop (one untimed
warm-up, then `--repeat` timed runs of the whole process; wall clock; min/median/mean printed,
per-run times appended to `microbench/results/<engine>-<stamp>.csv`, last run's output kept in
`microbench/results/<engine>-<name>.log`). The engine scripts only supply the command line:
Wizard runs `wizeng --ext:all --stack-size=65536 --mode=jit` (SPC compiler tier; `--ext:all`
because the OCaml modules also need tail calls), Wasmtime runs
`wasmtime run -W=exceptions,function-references,gc,stack-switching,tail-call` (Cranelift).
Override with `WIZENG`/`WIZARD_FLAGS` and `WASMTIME`/`WASMTIME_FLAGS`.

## The modules

All built at the pinned submodule commits; sizes/args chosen so single runs land in roughly
0.05–13 s (see the table in `bench-common.sh`).

| Module | Source | Shape | Opcodes |
|---|---|---|---|
| `itersum_wasmfx.wasm` | `fiber-c/examples/itersum.c` | 2 fibers, N yields (argv) | `cont.new` `resume` `suspend` |
| `itersum_switch_wasmfx.wasm` | `fiber-c/examples/itersum_switch.c` | 2 fibers, N symmetric switches (argv) | + `switch`, `resume_throw` |
| `pingpong_checked.wasm` | `research/compiler-diff/pingpong.wat`, N = 2 000 000 baked in, `main()` returns 0 iff the sum checks out | 2 continuations ping-pong via `switch` | `cont.new` `resume` `suspend` `switch` |
| `sieve_wasmfx.wasm` | `fiber-c/examples/sieve.c` | one fiber per prime (argv = 500), pipeline | resume/suspend |
| `treesum_wasmfx.wasm` | `fiber-c/examples/treesum.c` | generator over a fixed tree, argv = repetitions (4) | resume/suspend |
| `state_wasmfx.wasm` | `fiber-c/examples/state.c` | 1 fiber, 10 M get/put round trips (compiled in) | resume/suspend |
| `skynet_wasmfx.wasm` | `fiber-c/examples/skynet.c` | 1 M fibers in a tree, 6 live (compiled in) | resume/suspend |
| `c10m_wasmfx.wasm` | `fiber-c/examples/c10m.c` | 10 M connections over 10 000 live fibers (compiled in) | resume/suspend |

Rebuilding: `research/compiler-diff/build-fiber-c.sh <name>` reproduces the fiber-c modules
(wasi-sdk 22 from `~/workspace/benchfx/tools/wasi-sdk/`, binaryen v124, the reference
interpreter for the shim). `itersum_switch` additionally needs the two toolchain workarounds
from `research/COMPILER_DIFF.md` §2.2–2.3 (declare `$cancel` first; patch the `switch` opcode
byte `0xE5`→`0xE6`), and `pingpong_checked.wasm` is generated from `pingpong.wat` by renaming
`$main`→`$run` and appending
`(func (export "main") (result i32) (i32.ne (call $run (i32.const 2000000)) (i32.const -1455759936)))`,
then assembling and patching as in `research/compiler-diff/mk-pingpong.sh`.

## Known failures (kept on purpose — the harness reports them rather than hiding them)

- **`itersum_switch` on Wizard** fails at run time
  (`!NullCheckException in Runtime.TABLE_GET() … [spc-module] #12`): the SPC mis-executes the
  fiber-c switch module; the interpreter runs it. `research/COMPILER_DIFF.md` §5.4.
- **`skynet` and `c10m` on Wasmtime** die with `Cannot allocate memory (os error 12)`: upstream
  Wasmtime `mmap`s a fresh 2 MiB + guard stack per `cont.new` and never frees or pools any
  (`research/GOAL.md` §5), so millions of `cont.new`s exhaust mappings: each stack is two VMAs
  (guard + `RW`), and the 32 702nd `mmap` fails against `vm.max_map_count` = 65 530 (`skynet`
  at 0.21 s, `c10m` at 0.30 s). Reducing `-W async-stack-size` does not help — the mapping
  *count* is what runs out.

## OCaml benchmarks (`benches/multicore/multicore-effects/` via `wasm_of_ocaml`)

`ocaml_*.wasm` are single-file OCaml effect benchmarks compiled with
`wasm_of_ocaml --effects=native --enable wasi` (WasmGC + `cont.new`/`resume`/`suspend` +
`try_table`; they import only `wasi_snapshot_preview1`, so they run directly on a WASI engine).
Rebuild with `microbench/build-ocaml.sh`. Coverage across the resumption taxonomy
(`lit-review/01-background.md` §1):

| Module | Category / shape (args) |
|---|---|
| `ocaml_effect_throughput_perform` | one-shot tail: perform → continue (iterations) |
| `ocaml_effect_throughput_perform_drop` | zero-shot: continuation dropped — disposal cost (iterations) |
| `ocaml_effect_throughput_val` | handler install/teardown only, never performs (iterations) |
| `ocaml_rec_eff_fib` / `ocaml_rec_seq_fib` | handler per recursive call vs the no-handler control (iters n) |
| `ocaml_eratosthenes` | sieve as a pipeline of communicating handlers (limit) |
| `ocaml_algorithmic_differentiation` | one-shot non-tail through deep handlers (iterations) |

**The effect-using modules run on Wizard only.** Upstream Wasmtime refuses each of them at
compile time with `Unsupported feature: Stack switching feature not compatible with GC, yet` —
the GC × stack-switching integration gap (`research/GOAL.md` §5) — so the harness shows FAIL
rows there. The one exception is `ocaml_rec_seq_fib`, the no-handler control: `wasm_of_ocaml`
dead-code-eliminates the effects runtime from it, so it compiles and runs on both engines.
That asymmetry is itself a result: of the two engines, only Wizard can execute the OCaml
native-effects workloads today.

Note on tiers: on these WasmGC-heavy modules Wizard's *interpreter* currently beats its SPC
(e.g. `eratosthenes 1000`: ≈0.8 s at `--mode=int` vs ≈3.4 s at `--mode=jit`) — try
`WIZARD_FLAGS="--ext:all --mode=int" ./run-wizard.sh` for the comparison. The fiber-c rows are
the other way around.

**`macro-benches/` is deliberately not included**: its 23 tools need `make setup` to vendor a
duniverse (network-heavy), the input ladder is sized for native runtimes (`RUNNING.md`), and in
this project it serves as a *no-continuations control* (`research/GOAL.md` §10) rather than a
stack-switching microbenchmark. Revisit once a `small` rung is wired end-to-end through
`wasm_of_ocaml`.

Caveats: wall-clock of the whole process (module load + compile included; both engines' AOT
excluded — no `.cwasm` here); this machine is WSL2 (no hardware perf counters); `sieve` prints
its primes (discarded into the log). For per-opcode costs and the assembly-level explanation of
the gap, see `research/COMPILER_DIFF.md`.

The scripts exit 0 only if every benchmark passed, so the two expected failures above make
the exit status 1 — deliberate (usable as a regression signal), but remember it when chaining
with `&&`.
