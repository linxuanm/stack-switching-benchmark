# Background: vocabulary, taxonomy, and the implementation families

Condensed from `fx-research` notes 01 (Brachthäuser) and 05 (continuations background).

## 1. The taxonomy that decides everything

Classify a benchmark by **how the captured continuation is used**, not by what it is called.
This is the axis that predicts who wins any results table.

| | resumed | implementable as |
|---|---|---|
| **zero-shot** | never | exception / stack unwind |
| **one-shot, tail** | once, in tail position | inline the handler; no capture at all |
| **one-shot, non-tail** | once, later | **stack switching**; never copy |
| **multi-shot** | many times | copy stacks, or heap-allocate frames (CPS) |

Almost every implementation paper's results reduce to "fast in 1–3, lose in 4", or the
reverse. **If you publish numbers, report per-category, not just a geomean.**

### Where this repo's benchmarks land

| Program (`benchmark/benches/multicore/multicore-effects/`) | Category |
|---|---|
| `effect_throughput_val.ml` | handler installed, never performed — measures frame setup/teardown only |
| `effect_throughput_perform.ml` | one-shot, tail (perform → `continue k` immediately) |
| `effect_throughput_perform_drop.ml` | zero-shot (continuation abandoned; measures disposal) |
| `rec_eff_{fib,tak,ack,evenodd,motzkin,sudan}.ml` | handler installed per recursive call, never triggered |
| `rec_seq_*.ml` | the no-handler baselines to subtract |
| `algorithmic_differentiation.ml` | one-shot, non-tail through deep handlers |
| `eratosthenes.ml` | dynamically-shaped handler stack (defeats static shape analysis) |

Note the gap: **no multi-shot**, because OCaml 5 is one-shot only (multi-shot needs
`ocaml-multicont`, which clones fibers). This is the same exclusion that flatters one-shot
designs across the whole literature.

## 2. Vocabulary

**Delimited vs. undelimited.** `call/cc` captures the whole rest of the program; delimited
control (`shift`/`reset`, effect handlers) captures only up to a delimiter. Undelimited
continuations **do not compose**, which is why nobody designs for them any more — Kiselyov's
*An argument against call/cc* is the canonical statement, and WasmFX cites it as the reason
for going delimited.

**Multi-prompt.** Multiple distinguishable delimiters. Handler *tags* are essentially prompts;
a "named handler" is a *generative* prompt.

**Deep vs. shallow handlers.** Deep (Plotkin & Pretnar): the handler is automatically
reinstalled around the resumption. Shallow (Kammar et al.): it isn't. Wasm's design is a
hybrid — **"sheep handlers"**: always wrapped in *some* handler (deep-like), but the handler
may differ on each `resume` (shallow-like).

**Dynamic vs. lexical scoping of handlers.** Dynamic (Eff, Koka, OCaml, Wasm): `perform` walks
the handler stack looking for a matching tag. Lexical (Effekt, Lexa, Zhang & Myers'
"tunneling"): the handler is a capability value in scope. **This determines whether handler
search is a runtime cost at all.**

**Stackful vs. stackless coroutines.** Stackful = own runtime stack, can suspend from arbitrary
call depth, costs a stack. Stackless (C++20, Rust `async`, JS generators) = compiled to a state
machine, no stack, but suspension points must be statically visible through the *whole* call
chain — the "function colouring" problem. **Stack switching exists to give stackful semantics
without a per-coroutine OS stack.**

## 3. The key empirical study

**Farvardin & Reppy, *From Folklore to Fact*, PLDI 2020.** The only apples-to-apples
comparison: same source language (SML via Manticore), same pipeline, same LLVM backend, same
runtime, six strategies — `contig`, `resize`, `segment`, `hybrid`, `linked`, `cps`.

Conclusions the whole community now cites:

- *"If one's primary concern is sequential performance without advanced control-flow
  mechanisms, then `contig` (or possibly `resize`) is clearly the best choice."*
- **`resize` beats `segment` on space** — *"a resizing stack is the better choice because of
  its space efficiency. The segmented stack is not space efficient because the segment size is
  constant and constrained by the efficiency of the overflow and underflow handlers."*
  **This is the single most important sentence in the literature for a stack-compression
  project.**
- **`linked` should always be avoided** in favour of `cps`; mutability of linked frames is a
  curse, not a benefit.
- `cps` is by far the simplest runtime to build, fastest on continuation benchmarks, slower
  sequentially, and **incompatible with debuggers**.

Micro-architectural findings worth remembering:

- **RAS.** Replacing `ret` with `pop; jmp` costs the stack strategies only **1.02×–1.07×** in
  *ordinary* code. But Wasmtime measured **4 guaranteed mispredictions per stack switch** in
  switch-heavy code. Both are true; they describe different workloads.
- **Cache-locality folklore is mostly wrong.** L1 D-cache read miss rates: contig 8.6% /
  resize 7.8% / segment 7.8% / hybrid 7.8% / **linked 15.2%** / cps 9.8%. The much-repeated
  "CPS has terrible locality" claim is a small effect; `linked` is the real offender.
- **FFI through a stack-switching shim**: 2.5–2.98× on a pathological benchmark, but only
  **1.01–1.05×** on a realistic one.
- *"We found it very difficult to implement efficient segmented stacks!"* — segment size, how
  much to copy on overflow, and stack-cache size are all tunable and all interact.

## 4. Four families of handler implementation

1. **CPS / monadic translation.** *Evidence passing* (Xie, Brachthäuser, Hillerström, Schuster
   & Leijen, ICFP 2020) passes a vector of handler evidence so the handler is statically known
   — this enables **tail-resumptive handlers to be inlined with no capture at all**, and is how
   Koka is fast. Also iterated CPS + lift inference (Schuster et al., PLDI 2022).
2. **Whole-program specialization.** Eff's rewrite rules (Karachalias, Pretnar et al.,
   OOPSLA 2021); zero-cost handlers by staging. Later papers repeatedly find these rules
   *often fail to fire*, which flatters Eff's competitors.
3. **Stack switching in the compiler/runtime.** **Lexa** (Ma, Ge, Lee & Zhang, OOPSLA 2024) —
   compiles lexical handlers straight to stack switching. **Effekt's LLVM backend** — see §5.
   **libseff** (OOPSLA 2024) — mutable coroutines, segmented stacks, usable *from* C.
   **libmprompt/libmpeff** (Leijen & Sivaramakrishnan). **cpp-effects** (OOPSLA 2022).
   **Virtualizing Continuations** (Ma, Jung & Zhang, PLDI 2026) — parallel-shot continuations
   via **virtual addresses + a software MMU** in the runtime, directly attacking "stack copying
   invalidates references into the stack".
4. **JIT.** Gaißert, Bolz-Tereick & Brachthäuser (OOPSLA 2025) — meta-tracing over a common
   bytecode for Eff/Effekt/Koka.

## 5. Effekt / Brachthäuser: what to steal

His line runs from *how do we type effects ergonomically* (Effekt, capabilities, boxes, Scala
capture checking) → *how do we compile them to a stack* (CPS with lift inference → regions →
Lexa-style stack switching) → *how do we make the stack fast*.

The core commitment is **lexical handlers + capability passing**: `handle` binds a capability
(a first-class object with the operation as a method) which is *passed* to the computation, so
`do op()` is a plain method call. Handler search becomes static.

| | Dynamic handlers | Lexical / capability handlers |
|---|---|---|
| Finding the handler | runtime search over handler stack | static; capability is a value |
| Effect polymorphism | needs effect variables / row types | falls out of ordinary term-level passing |
| Accidental handling | possible (nested handler shadows) | impossible (lexical scoping) |
| Cost model | search + dispatch | direct call + one stack switch |

**The one to read: Muhcu, Schuster, Steuwer & Brachthäuser, *Multiple Resumptions and Local
Mutable State, Directly*, ICFP 2025.** It argues directly against the folklore that multi-shot
and stack switching are incompatible.

- Runtime is a **meta stack**: a linked list of stack segments, each delimited by a **prompt**.
- **Stable prompts.** Prompts are separately allocated and stable; capabilities and references
  point at the *prompt*, not the stack. This indirection is what makes it safe to copy or
  realloc a stack. Cost: one extra indirection on local mutable state — worst case ≈1.9× on a
  state-only tight loop, **<2%** on real benchmarks, because LLVM removes most of it.
- **Garbage-free reference counting** (Perceus-style) on the meta stack. Frames carry
  **sharer and eraser functions** invoked when a stack is copied or freed. Refcount 1 ⇒ resume
  in place (constant time); refcount > 1 ⇒ **copy the stack**.
- **Stack growth = reallocate and double**, amortized O(1) — sound only because of the prompt
  indirection.
- **Zero-shot is not free**: exceptions must traverse the stack to erase it, linear in frames.
  This is why they lose on `product-early`.
- Results (geomean): faster than OCaml 5 by 2.2×, Eff 3.2×, Koka 10.2×; slower than
  Effekt-MLton by 1.25× and Lexa by 1.29×.

Transferable lessons: (1) lexical handlers make handler search go away; (2) **the prompt
indirection is the enabling trick for moving stacks** — anything holding a raw pointer *into* a
stack prevents copy, shrink, realloc, and relocation; (3) **frame-level sharer/eraser
descriptors** are the metadata you need to copy or destroy a frame, the same role as GC stack
maps; (4) amortized doubling avoids hot split, but only because of (2); (5) **refcount-1 fast
path** is the general shape of "one-shot is free, multi-shot is copy-on-write".

Also load-bearing: **Dynamic Wind for Effect Handlers** (Voigt/Schuster/Brachthäuser,
OOPSLA 2025) — the principled account of what runs when a suspended stack is cancelled or
resumed again. Wasm's `resume_throw` and OCaml's `discontinue` are the primitive versions of
the same question.

## 6. Lineage

- **Hieb, Dybvig & Bruggeman, PLDI 1990** — stack segments; the origin of "capture = split the
  stack".
- **Bruggeman, Waddell & Dybvig, PLDI 1996** — one-shot continuations give you segmented stacks
  with no copying. Cited by both OCaml 5 and WasmFX as the ancestor.
- **Dolan, Muralidharan & Gregg, TACO 2013** — **SWAPSTACK**: a symmetric primitive plus the
  compiler/ABI support to make it cheap. **The direct ancestor of Cranelift's `stack_switch`.**
- **Flatt & Dybvig, PLDI 2020** — continuation marks; stack inspection that survives
  first-class continuations. Relevant to keeping backtraces working.
- **Appel, *Compiling with Continuations* (1992)** — the heap-allocated-frames tradition.

## 7. Theory worth knowing

- **Expressiveness.** In an untyped setting, effect handlers, monadic reflection, and delimited
  control **macro-express each other** (Forster, Kammar, Lindley & Pretnar). The choice among
  them is engineering, not power.
- **Asymptotic speedup.** For the *generic count* problem, a language with handlers admits an
  implementation asymptotically faster than **any** implementation in the pure base language
  (Hillerström, Lindley & Longley, JFP 2024). Handlers buy complexity, not just ergonomics.
- **Verification.** WasmFX has a paper soundness proof, a mechanised **WasmCert** proof, and a
  **SpecTec** spec; *Iris-WasmFX* (draft, Nov 2025) adds modular separation-logic reasoning.

## 8. Where these ideas ship

| System | Mechanism | Note |
|---|---|---|
| **OCaml 5** | fibers = `malloc`'d resizable stack segments, one-shot | [04-runtimes.md](04-runtimes.md) |
| **Java / Loom** | virtual threads; frames **frozen** into `StackChunk` heap objects on yield, **thawed** lazily | the canonical "compress the stack into the heap" design |
| **Go** | goroutines: **abandoned segmentation in Go 1.3** for contiguous copying stacks; start 2–8 KB, grow by copying, **shrunk during GC** | rewrites interior pointers during the copy |
| **Erlang/BEAM** | per-process heap+stack, tiny initial size, GC'd | the existence proof for millions of processes |
| **Rust / C++20 / JS / C#** | stackless state machines | no stack cost, but function colouring |
| **Chez / Racket** | stack segments + continuation marks | multi-shot, and it works |
| **WebAssembly** | `stack-switching` proposal, one-shot | [03-wasm-stack-switching.md](03-wasm-stack-switching.md) |
