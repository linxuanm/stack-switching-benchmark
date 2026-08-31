# Open questions and project openings

Condensed from `fx-research` note 07, plus the Wasmtime-specific opportunities from note 09.

## 1. What the literature agrees on

1. **One-shot is the sweet spot, and everybody landed there independently.** OCaml 5, WasmFX,
   libseff and Loom all restrict to one-shot (affine) continuations, dynamically checked, because
   that is exactly the condition under which *a continuation can just be a stack and never needs
   copying*. Multi-shot is a library or an extension, and is consistently what gets dropped from
   comparisons.
2. **Handler search dominates in dynamically-scoped designs, and it is avoidable.** libseff: every
   implementation degrades with handler depth, and lookup dominates the context switch beyond
   depth ≈3. Lexical handlers (Effekt, Lexa) and evidence passing (Koka) eliminate it statically.
3. **Tail-resumptive handlers should never capture a continuation.** The single highest-leverage
   optimization in every fast implementation. **Wasm has no way to express it** — the proposal
   notes this as future work.
4. **Allocation dominates cheap operations.** OCaml: 23 ns to create a fiber vs 5/11/7 ns for
   perform/resume/return. Wasmtime: 68× on `c10m` from pooling alone. libseff: 3–34× from segment
   recycling. **If you are making stack switching fast, you are mostly making stack *allocation*
   fast.**
5. **Microbenchmarks mislead about control-flow features.** Asyncify beats WasmFX 3–4× on
   microbenchmarks and loses ~90× on tail latency at saturation. The interesting property of stack
   switching is *latency and composability*, not throughput.

## 2. The five gaps

### (a) Nobody reports memory
Essentially every results table is wall-clock only. The community suite has no memory metric;
`hyperfine` doesn't measure one. The two places memory *was* reported are the two places the
headline result was about memory.

**Concretely missing:** a benchmark parameterized by *number of live suspended continuations*
that reports **bytes per suspended continuation**, alongside peak and steady-state RSS. That is a
small, publishable, obviously-useful artifact and it would slot straight into
`effect-handlers-bench` and `benchfx`.

### (b) Continuation size is never a swept parameter
Every benchmark fixes the captured continuation's depth. Gaißert et al. explicitly flag a
performance cliff for large continuations and note it *"did not occur in the benchmarks"*.
`skynet` (deep) vs `c10m` (shallow) in `benchfx` is the only place the axis appears at all, and
it is two points, not a sweep.

### (c) The shadow stack is treated as out of scope
Every Wasm stack-switching paper reasons about the *engine* stack. The 4 KB per coroutine that
produced WasmFX's 4× memory penalty is largely about the *linear-memory shadow stack*, and that
region cannot be moved because pointers into it are ordinary `i32`s. No paper addresses this
directly. **The most under-attacked part of the problem, and the most Wasm-specific.**

### (d) No principled way to size a stack
Fixed 4 KB is a guess; upstream Wasmtime's 2 MiB is a host-async knob doing double duty. OCaml
starts at 16 words and doubles. Nobody asks whether the *producer* could tell the engine how much
stack a coroutine body needs — which, for compiled generators and async functions, is often
statically known or boundable. There is no size hint in the proposal, no profile-guided sizing,
no adaptive scheme in the literature.

### (e) Cancellation and finalization are unresolved in practice
OCaml leaks abandoned continuations by design (finalisers cost 2–4×, so they are off by default).
Wasm has `resume_throw` but Wasmtime hasn't implemented it, and "continuation deallocation" is
open on the tracking issue. Brachthäuser's *Dynamic Wind for Effect Handlers* (OOPSLA 2025) is the
principled answer and has not been connected to Wasm. **Memory management and cancellation are the
same problem: a suspended stack you cannot prove dead is a suspended stack you cannot reclaim.**

## 3. The four cross-cutting tensions

| Tension | Poles | Who is where |
|---|---|---|
| **Relocatable vs. addressable** | copy/shrink stacks freely ↔ allow interior pointers | OCaml/Go/Loom vs. C/C++/Wasm shadow stack. libmprompt escapes it with virtual memory; Effekt with stable prompts; *Virtualizing Continuations* with a software MMU |
| **Fixed vs. dynamic sizing** | no runtime management, guaranteed waste ↔ management overhead, right-sized | fixed-4 KB (WasmFX) vs. resize (OCaml, Go, Effekt) vs. overcommit (libmprompt) vs. segment (libseff) |
| **One-shot vs. multi-shot** | stack *is* the continuation ↔ must be able to duplicate it | everyone one-shot; Effekt-LLVM shows copy-on-refcount>1 is a viable middle |
| **Dynamic vs. lexical handlers** | modular composition, runtime search ↔ static resolution, needs scoping discipline | Wasm/OCaml/Koka vs. Effekt/Lexa. Wasm's post-MVP "named handlers" moves toward the middle |

## 4. Concrete openings

Ordered roughly by effort.

1. **Measure the gap.** Extend `benchfx` (or `effect-handlers-bench`) with a memory-oriented
   benchmark: sweep live suspended continuations from 10³ to 10⁷, sweep call-stack depth, report
   bytes/continuation and RSS. Compare WasmFX-in-Wasmtime, Asyncify, JSPI, native threads,
   goroutines, OCaml fibers, Loom. **There is no such table today and everyone would cite it.**
2. **Right-sizing / size hints.** Add a producer-supplied stack-size hint (or a toolchain analysis
   over shadow-stack frame sizes) and measure how much of the 55.5 → 13.4 MB gap it closes. Low
   risk, plausibly most of the gap.
3. **Grow-in-place for Wasm.** Port the libmprompt gstack scheme into Wasmtime's continuation
   stacks — the WasmFX paper's own suggested next step. Then the harder half: can the *shadow*
   stack get the same treatment inside a Memory64 linear memory?
4. **Freeze/thaw for the engine stack.** Loom-style copy-out-on-suspend, sized to live frames. The
   engine knows Wasm frame layouts. Also yields `cont.clone`/multi-shot for free, and would be the
   first multi-shot Wasm implementation.
5. **Shadow-stack splitting.** A toolchain pass partitioning locals into "must live in linear
   memory (address taken)" and "can live in engine locals", minimizing the linear-memory footprint
   of a suspended coroutine.
6. **Bring `dynamic-wind` to Wasm.** Connect Voigt/Schuster/Brachthäuser (OOPSLA 2025) to
   `resume_throw` + continuation deallocation. Semantics, implementation, and the
   memory-reclamation argument in one.
7. **Tail-resumptive handlers in Wasm.** A way to mark or detect them so no continuation object is
   ever built. Named in the WasmFX paper as future work; the biggest known performance hole.

### Wasmtime-specific, ranked by difficulty

| # | Opportunity | Difficulty | Evidence it matters |
|---|---|---|---|
| 1 | **Pool + recycle continuation stacks** — reuse `unix_stack_pool.rs` and its keep-resident/decommit policy | low — the code exists | 187.73× → 2.76× on `c10m` |
| 2 | **Free continuations.** Nothing is ever reclaimed; even a `Returned`/`Trapped` continuation holds its 2 MiB VA forever | low–medium | open on #10248 |
| 3 | **Right-size the stack** per `cont.new` instead of the global `async_stack_size` | medium | WasmFX's 55.5 vs 13.4 MB was *entirely* fixed-size stacks |
| 4 | **Grow-in-place (libmprompt gstacks)** | medium | named by the WasmFX paper as its own next step |
| 5 | **Freeze/thaw (Loom-style)** | high | no Wasm engine has done it |
| 6 | **Shadow stack** — untouched, and it is the part that actually needs the memory | high | the genuinely open research problem |
| 7 | **Tail-resumptive handlers** — no mechanism at proposal or implementation level | medium | biggest known perf hole |
| 8 | **Handler-search caching** — `search_handler` is an uncached nested loop | medium | libseff: lookup dominates beyond depth ≈3 |

Two mundane ones the source itself flags: share the `switch` temp stack slot across a function,
and restore DWARF for the continuation trampoline.

## 5. People and venues

**Edinburgh (Lindley, Hillerström, Emrich)** — WasmFX, the Wasmtime implementation, libseff,
`benchfx`, benchmark-suite governance. *This group is the Wasm stack-switching effort.*
**Tübingen (Brachthäuser, Schuster)** — Effekt, lexical handlers, compilation, stack runtimes.
**Waterloo (Yizhou Zhang, Cong Ma)** — Lexa, tunneling, *Virtualizing Continuations*.
**OCaml Labs / Tarides / IIT Madras (Sivaramakrishnan, Dolan, White)** — OCaml 5, Eio.
**Microsoft Research (Leijen)** — Koka, libhandler, libmprompt, evidence passing.
**Bytecode Alliance** — Wasmtime, Cranelift, the pooling allocator.

Venues: PLDI, OOPSLA, ICFP, POPL for language work; the **WebAssembly Workshop (WAW)**, the
**Wasm CG Stacks subgroup**, and Dagstuhl seminars for systems work. `effect-handlers.org` and
`wasmfx.dev` aggregate talks.
