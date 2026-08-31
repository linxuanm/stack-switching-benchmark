# Benchmarking effect handlers and stack switching

Condensed from `fx-research` note 02. This is the methodology file: what the field measures,
with what harness, and where the practice is weak.

## 1. The language-level suite

**[`effect-handlers/effect-handlers-bench`](https://github.com/effect-handlers/effect-handlers-bench)**
— cited as *Hillerström, Koprivec, Schuster et al. 2023*. It came out of Dagstuhl seminar
**21292 "Scalable Handling of Effects"** (2021), which appointed rotating **benchmarking
chairs** to curate the repo and police benchmark quality. It is deliberately community-owned,
not one group's microbenchmarks.

**Harness.** Docker (Ubuntu 22.04) for reproducibility, Makefile rules per system,
**`hyperfine`** to run and emit CSV. Benchmarks take parameters on the command line and print
a checked result. **Whole-process wall time, not in-process timers.**

Systems covered: Eff, Effekt, Koka, OCaml (via `ocaml-multicont`), Links, Handlers-in-Action,
libhandler, libmpeff, libseff; papers add Lexa, Flix, SML/MLton, WasmFX, and JS/Python
encodings.

| Benchmark | Control-flow shape |
|---|---|
| `countdown` | tail-resumptive state; the "can you optimize the handler away entirely" test |
| `fibonacci-recursive` | **no handlers at all** — a control for baseline runtime speed |
| `product-early` | **zero-shot**: push ~1000 frames, discard via exception. Continuation *disposal* cost |
| `iterator` | push-stream; handler resumes in tail position |
| `generator` | consumer-driven pull |
| `nqueens`, `tree-explore`, `triples` | **multi-shot**: backtracking / non-determinism |
| `parsing-dollars` | three interacting handlers over one function — tests *composition* |
| `resume-nontail` | **one-shot non-tail**: isolates cost of stack growth under resumption |
| `handler-sieve` | dynamically-shaped handler stack — defeats static stack-shape analysis |

### Benchmarks papers add on top

**Gaißert et al. (OOPSLA 2025)** contribute four probing handler *search* and *dispatch*:
`unused-handlers` (unrelated handlers between `do op` and its handler — search cost vs depth),
`to-outermost-handler` (intervening handlers for the *same* effect at the *same* program
position, to defeat heuristics keyed on type or definition site), `multiple-handlers` (one
`do op` site handled by three different handlers — defeats monomorphic inline caching), and
`startup` (a constant-`0` program, to separate JIT warmup from steady state).

**libseff (OOPSLA 2024)** contribute two that are about *stacks*, not handlers:

- **State-at-depth** — nest *N* handlers for an unperformed effect, then run a get/put loop
  underneath. Sweeping *N* separates **locating the handler** from **transferring control to
  it**; they run a "general" and an "optimal" variant to isolate the two. Finding: *every*
  implementation degrades with handler depth, and **lookup dominates the context switch beyond
  depth ≈3**.
- **Hot-split** — force every call to need a new segment, 10⁸ iterations, sweeping real work in
  the callee. **11× slowdown at zero work, gone by ~13 FP multiplies**; and recycling freed
  segments vs. `free`ing them is a **3–34×** difference. The canonical measurement of the
  segmented-stack hot-split problem.

### Macro-ish benchmarks that exist

- **HTTP server / plaintext** (TechEmpower-style; used for OCaml 5 and libseff): one coroutine
  per connection, work-stealing scheduler, `wrk2` for load. The closest the field gets to a
  realistic workload.
- **Prefetching / interleaved binary search** (libseff): coroutines to hide memory latency.
- **Leijen & Sivaramakrishnan's web-server simulation** (2021): 10 000 concurrent coroutines,
  10 M total. Used by the WasmFX paper. Measures **binary size, wall time, and peak RSS** — the
  only widely-used benchmark that treats memory as a first-class result.
- **`are-we-fast-yet`** subset: used by Gaißert et al. as a *direct-style* control, to check
  that making handlers fast did not make ordinary code slow.

## 2. `benchfx` — the Wasm suite

[`wasmfx/benchfx`](https://github.com/wasmfx/benchfx). Source language is **C with a bespoke
fiber library** — [`wasmfx/fiber-c`](https://github.com/wasmfx/fiber-c), **which is a submodule
of this repo**. It compiles two ways: through `wasm-opt -O2 --asyncify`, or straight to WasmFX
instructions. WASI SDK 22, clang `-O3 --std=c17`, AOT-compiled with `wasmtime compile`.

Stated requirement: **all fibers must terminate gracefully** (return or cancellation) — i.e.
cancellation paths are part of the benchmark, not an afterthought.

Declared "apples & oranges" caveat, and it is an honest one: **Asyncify fibers live in linear
memory, WasmFX fibers live in tables**, so the two do not store state in comparable places.

`benchfx` measures run time, **binary size**, and **tail latency** — the language-level suite
measures none of the last two. The two suites barely reference each other, which is itself a
gap: the language-level suite has the right *control-flow shapes*, the Wasm suite has the right
*scale and metrics*. Results are in [03-wasm-stack-switching.md](03-wasm-stack-switching.md) §4.

## 3. Methodology worth copying

**Gaißert, Bolz-Tereick & Brachthäuser (OOPSLA 2025)** is the most carefully-reported
methodology in this literature:

- `hyperfine` 1.19.0, pinned OS and CPU, **all results replicated on Apple M1** in an appendix.
- **Versions pinned to git hashes**, not just release numbers.
- **One correctness run first**, which also times out anything over 90 s — reported as `>90s`,
  **not silently dropped**.
- **≥20 runs or ≥6 seconds**, whichever is longer, with **one warmup run** before each set.
  Reports the **arithmetic mean** plus per-benchmark relative standard deviation, and calls out
  the outliers explicitly.
- **States what is inside the measurement**: whole-program wall time including bytecode load,
  JIT tracing and codegen; excluding AOT compilation. This is the part most papers skip.
- **Geometric mean slowdown** vs a named baseline, computed only over benchmarks where *both*
  systems ran. Failure modes distinguished in the tables: `≡` stack overflow, `—`
  unimplemented, `✗` compile failure, `OOM`.
- **Ablation study**: geomean with each optimization individually disabled. One "optimization"
  turned out to be a *pessimization* (0.90–0.93). **Publishing the negative result is the good
  practice here.**
- **External anchoring**: hand-translate benchmarks into idiomatic JS and Python to answer "is
  a specialized effect implementation actually better than what V8/PyPy already do?" (Yes for
  control effects; no for direct-style code, where V8 is 2.3× faster.)
- **Threats to validity stated plainly**: *"there are not yet larger programs written using
  [effect handlers]. Thus, the quantitative evaluation has to rely on microbenchmarks."*

Two more practices worth stealing:

- **Müller et al. (OOPSLA 2023)** add a **hand-optimized baseline** — take the code their
  compiler generates, then minimize and hand-optimize it using each language's *native*
  effects. This gives an "abstraction overhead = 0?" target rather than only relative
  comparisons. They also **debug their competitors and say so** (Eff's specialization "seems to
  be blocked"), which is rare and correct.
- **Muhcu et al. (ICFP 2025)** report **≥10 repetitions, median**, as a log-scale bar chart
  normalized to their own system, with explicit ✗ marks for benchmarks a system *cannot run* —
  expressiveness gaps shown, not hidden. They **excluded `countdown` from the geomean and said
  why**, added a targeted micro-experiment for the one cost their design introduces, and used
  a **scaling curve** (running time vs. number of nested handlers) rather than a single point.
  *Scaling curves, not single points, are the right instrument for handler search.*

## 4. What the field measures badly

1. **Memory is nearly never reported.** Almost every table is wall-clock only; `hyperfine`
   doesn't measure memory. The exceptions — WasmFX (peak RSS + binary size) and the OCaml 5
   work — are exactly where the interesting result showed up. **If you are working on stack
   compression, you are working in a gap: there is no accepted memory benchmark for
   continuations.**
2. **No large programs exist.** Every author says so. The HTTP server is the only
   quasi-realistic workload in common use.
3. **Handler-search depth is under-tested** relative to how much it dominates. libseff and
   Gaißert et al. both had to invent their own depth sweeps.
4. **Multi-shot is systematically excluded.** OCaml and libseff omit those benchmarks entirely.
   Comparisons therefore run over the subset everyone supports, which flatters one-shot designs.
5. **Continuation *size* is untested.** Gaißert et al. flag a performance cliff for very large
   captured continuations and note *"this case did not occur in the benchmarks"*. Nobody sweeps
   captured-continuation depth as a parameter.
6. **Cross-language comparison confounds runtime with technique.** MLton vs OCaml vs gcc vs V8
   differences leak into every number. The good papers handle this with a no-handlers control
   and a hand-optimized baseline.

## 5. A checklist for benchmarking Wasm stack switching

- Sweep three independent axes: **handler-stack depth**, **captured-continuation size**, and
  **number of live suspended continuations**. The third is what stack compression targets.
- Report **peak and steady-state RSS**, plus **bytes per suspended continuation** — not just
  time.
- Report the four resumption categories separately.
- Include a **no-continuations control** so engine-level differences stay visible.
- Baselines to beat: **Asyncify**, **JSPI**, a **hand-written state machine**, and native
  threads/goroutines.
- Distinguish the costs, which have different asymptotic stories:
  create · first resume · suspend · resume · dispose · grow · copy (multi-shot).

### Hillerström's own open questions (verbatim framing)

- *"Microbenchmarks: what are the key interesting properties to measure?"*
- *"Macrobenchmarks: what are some inherently stack-switching-y representative workloads?"* —
  candidates offered: HTTP servers, generator programs, HPC, a canonical work-stealing
  benchmark.
- *"What are some representative workloads that combine stack switching features?"*

Memory-per-suspended-continuation is conspicuously **not** on that list, which is where a
stack-compression contribution would land.
