# CLAUDE.md — working notes for `stack-switching-benchmark`

Auto-loaded context for Claude Code, and a map for contributors. Human-facing docs are
[`RUNNING.md`](RUNNING.md) (how to run the suites) and [`lit-review/`](lit-review/) (the
literature). This file holds the orientation and the gotchas.

## What this is

Research on **optimizing WebAssembly stack switching with stack compression** — the goal
statement lives in [`research/GOAL.md`](research/GOAL.md).

The thesis in one paragraph: engines allocate a **fixed-size stack per continuation**, and that
single choice dominates the memory cost of stack switching. WasmFX measured **55.5 MB vs 13.4 MB**
against a hand-written state machine on 10 000 coroutines and attributed the gap *entirely* to a
fixed 4096-byte stack per coroutine. Nobody in the literature reports **bytes per suspended
continuation**, and no benchmark sweeps *number of live suspended continuations* as a parameter.
That is the gap this repo aims at. Background: [`lit-review/README.md`](lit-review/README.md).

## Layout

| Path | What | Ours? |
|---|---|---|
| `research/` | **The project.** `GOAL.md` is the goal statement; the rest is to be written | ours |
| `lit-review/` | Condensed literature notes (7 files, ~12k words), from `../fx-research` | ours |
| `tools/` | Pipeline for running OCaml→Wasm on the reference interpreter | ours |
| `RUNNING.md` | How each suite runs on the reference interpreter, with per-repo status | ours |
| `benchmark/fiber-c/` | C fiber library — Asyncify vs WasmFX backends. **This is the source language of [`benchfx`](https://github.com/wasmfx/benchfx)** | submodule, upstream |
| `benchmark/benches/` | OCaml micro-benchmarks; `multicore/multicore-effects/` is the effects set | submodule, upstream |
| `benchmark/macro-benches/` | OCaml macro-benchmarks, 23 vendored real tools | submodule, upstream |
| `benchmark/angstrom/` | Parser combinators. Uses **no effects** — a baseline for what the stack-switching calling convention costs ordinary code | submodule, upstream |
| `dependencies/wizard-engine/` | **The research vehicle.** Titzer's Wizard engine, in Virgil | submodule, upstream |
| `dependencies/wasmtime/` | Reference implementation to compare against, in Rust | submodule, upstream |
| `dependencies/virgil/` | The Virgil compiler, for building Wizard — `build-all.sh` bootstraps it from the pinned master sources into `bin/current/` (the checked-in stable binary is too old for Wizard) | submodule, upstream |
| `dependencies/specfx/` | The WasmFX-merged reference interpreter (`interpreter/wasm`) | submodule, upstream |
| `dependencies/binaryen/` | binaryen `version_124` (`wasm-merge`, `wasm-opt`, …), built into `dependencies/binaryen-build/` | submodule, upstream |
| `dependencies/js_of_ocaml/` | js_of_ocaml master, for `wasm_of_ocaml.exe` | submodule, upstream |
| `dependencies/wasi-sdk/`, `dependencies/ocaml/` | wasi-sdk 22 (downloaded) and the local opam switch — created by `build-all.sh`, gitignored | generated |
| `env.sh`, `build-all.sh` | The environment (every tool variable → `dependencies/`) and the single build entry point | ours |
| `microbench/` | Our harness: built `.wasm` modules, results, build intermediates (all gitignored) | ours |

**Submodules are upstream repos.** Do not commit into them; do not push them. If a change is
needed there, say so rather than editing in place.

## Where the research actually bites

### Wizard (`dependencies/wizard-engine/`, Virgil)

Supports stack-switching in **every tier** (load, v3-int, fast-int, spc) — which is why it is the
vehicle. Wasmtime supports it in one tier, off by default, x86-64 Linux only.

| File | What |
|---|---|
| `src/engine/x86-64/X86_64Stack.v3:1007` | `component X86_64StackManager` — **the allocator.** A free-list `cache`, `getFreshStack`, `recycleStack`, `allocStackBatch` |
| `src/engine/x86-64/X86_64Stack.v3:9` | `class X86_64Stack` — the stack itself: a native `mapping`, `vsp`/`rsp`, a redzone placed *mid-mapping*, a custom GC scan routine, and `next_stack` for the cache free-list |
| `src/engine/Tuning.v3:75` | `component StackTuning` — currently one knob, `stackCacheSize = 8` |
| `src/engine/EngineOptions.v3:8` | `DEFAULT_STACK_SIZE = 512 KiB`, exposed as `--stack-size` |
| `src/engine/WasmStack.v3` | `ExecStack` / `VersionedStack` / `WasmStack`, `StackState`, `FrameAccessor` — the tier-independent interface |
| `src/engine/x86-64/X86_64Target.v3:19` | `newWasmStack` / `recycleWasmStack` hooks |

**The state of play:** Wizard *already* pools and recycles stacks — batch-allocating 8 at a time
and returning them to a free list. That is the optimization the literature values most (68× on
`c10m` in Wasmtime). What it does **not** do is size them: every stack is
`X86_64Stack.new(EngineOptions.STACK_SIZE.get())`, one global fixed size for every continuation.
**That is the compression opportunity, and it is exactly the axis the literature leaves open.**

Virgil is installed at `~/workspace/virgil` (`v3c`, `virgil` on PATH). Build with
`dependencies/wizard-engine/build.sh`. `benchmark/fiber-c/config.yml` already drives Wizard as a benchmark engine with
`--ext:stack-switching --ext:gc --stack-size=65536 --mode=jit`.

### Wasmtime (`dependencies/wasmtime/`, Rust)

The comparison point, and a cautionary one. Walkthrough in
[`lit-review/04-runtimes.md`](lit-review/04-runtimes.md) Part II. The short version: codegen is
excellent (a switch is six `mov`s, a `lea`, and an indirect `jmp`), and **memory is the weak
point** — every `cont.new` `mmap`s a fresh **2 MiB** stack, nothing is pooled, and *nothing is ever
freed until the store is dropped*. `crates/wasmtime/src/runtime/store.rs:2137` `allocate_continuation`
is the whole story (verified at the pinned commit `d8a0da6d66`); the pooling machinery that would fix it already exists one directory over, for
async fiber stacks, and is simply not wired up.

So the two engines fail in opposite directions: **Wizard pools but does not size; Wasmtime neither
pools nor frees.**

## Toolchain

Everything lives under `dependencies/` and is built by `./build-all.sh`; `source env.sh` puts it
in a shell (`WIZENG`, `WASMTIME`, `V3C`/`VIRGIL_LOC`, `WASI_SDK`, `BINARYEN`, `WASM_INTERP`,
`WASM_OF_OCAML_EXE`, `OCAML_SWITCH`, `RUST_TOOLCHAIN`, plus `PATH` and the opam switch). Every
script sources it itself. Pinned: Virgil `bb8956d0a`, specfx `15ec7d15` (reports `wasm 3.0.0`;
`cont.new`/`resume`/`suspend`/`switch` always on, no feature flag), binaryen `version_124`,
js_of_ocaml master `27e40dda`, wasi-sdk 22, OCaml 5.4.0 in a local opam switch with pinned
dune/menhir/ppxlib/sedlex/cmdliner/yojson/ocamlfind. Host prerequisites: git, curl, python3,
rustup, opam, cmake and a C++ compiler.

**Overrides, never guesses.** A tool variable that is already set (shell, or the gitignored
`build.env` — template `build.env.example`) is used as-is and `build-all.sh` skips building that
dependency. A missing tool stops a step with a message naming the variable and the step that
builds it.

**js_of_ocaml caveat.** Released js_of_ocaml (and its `#native-effects` branch) emit *legacy*
exception handling, which the reference interpreter rejects (`decoding error: illegal opcode
06`). Master emits `try_table` and adds `--effects=native` — which is why it is vendored and
built from source, and why `WASM_OF_OCAML_EXE` must point at that build.

## Reference-interpreter gotchas

Full detail in [`RUNNING.md`](RUNNING.md); the four that cost the most time:

1. **No WASI.** The interpreter registers only `spectest` and `env`; `env` provides just `abort`
   and `exit`. Anything built `--enable wasi` cannot be instantiated as-is.
2. **`wasm foo.wasm` does not run anything.** It decodes and validates, then exits 0. It never
   instantiates, so a `start` section never fires.
3. **Every CLI argument is an independent script.** `wasm foo.wasm -e '(invoke "_start")'` fails
   with `no module instance defined`. `(input "foo.wasm")` *inside* a script is sandboxed too.
4. **Execution needs one `.wast`** holding both the module and the commands driving it.

Two more that bite when extending the tooling:

- `wasm-merge` **order matters**: main module first, or the shim's `(import "main" "memory")` does
  not resolve and you get two memories.
- `wasm_of_ocaml` merges the prelinked runtime **and every user runtime file under the single
  module name `env`**. A runtime shim importing from `"bigstring"` (the runtime *source file*
  name) leaves an unresolvable import. Import from `"env"`.

**The interpreter is a semantics oracle, not a timing instrument** — ~120 µs per perform/resume
round trip against 62 ns native, about 1,900× slower. Use it to check that generated code is
correct; measure on Wizard, wasmtime, or d8.

## Running things

The benchmark pipeline, from a fresh clone: `./build-all.sh` (builds `dependencies/` and every
wasm module — ~30 min the first time, mostly wasmtime, binaryen and the opam switch), then
`./run-wizard.sh --repeat 5` / `./run-wasmtime.sh --repeat 5` for timings (shared driver
`bench-common.sh`, wasm dir `microbench/wasm/`), and `./runtime-compare.sh` for the perf-based
"where the time goes" tables of `research/FIBER_C_COMPARE.md`. Details in `microbench/README.md`.
For interactive use, `source env.sh`.

Single OCaml programs on the reference interpreter:

```bash
./tools/ocaml-refrun.sh benchmark/benches/multicore/multicore-effects/effect_throughput_perform.ml 200
```

Pass **explicit small arguments**. Every benchmark takes its size from `Sys.argv.(1)` and falls
back to a large default (`effect_throughput_perform` defaults to 1,000,000 iterations — about four
hours on the interpreter).

`EXTRA_RUNTIME=` adds runtime `.wat` files (needed for libraries with C stubs); `OUTDIR=` keeps
intermediates. A pre-linked `.byte` can be passed instead of a `.ml` for anything needing
libraries.

## Conventions

- **Commit or push only when asked.** Submodules and the docs/tools are currently staged but not
  committed.
- **Do not commit into submodules**, and do not `git submodule update` them to new upstream
  commits without being asked — the pinned commits are part of the experimental setup.
- Benchmark numbers in docs must say what was measured and on what. If a number is virtual — the
  WASI shim's clock advances 1 ms per query, so anything a benchmark *prints* about time under the
  reference interpreter is fictional — say so at the point of use.
- `lit-review/` is condensed from `../fx-research`; that repo remains the long-form source. Update
  both, or neither.
