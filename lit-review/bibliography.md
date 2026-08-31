# Bibliography

Everything cited in these notes. **✓** = read in full when the source notes were written.

## Core reading (start here)

- **Phipps-Costin, Rossberg, Guha, Leijen, Hillerström, Sivaramakrishnan, Pretnar, Lindley.
  *Continuing WebAssembly with Effect Handlers.* OOPSLA 2023.** ✓
  <https://arxiv.org/abs/2308.08347> · <https://wasmfx.dev>
- **Sivaramakrishnan, Dolan, White, Kelly, Jaffer, Madhavapeddy. *Retrofitting Effect Handlers
  onto OCaml.* PLDI 2021.** ✓ <https://arxiv.org/abs/2104.00250>
- **Farvardin & Reppy. *From Folklore to Fact: Comparing Implementations of Stacks and
  Continuations.* PLDI 2020.** ✓ <https://kavon.farvard.in/papers/pldi20-stacks.pdf>
- **Hillerström. *Benchmarking WasmFX.* Wasm Stacks subgroup, May 2024.** ✓
  <https://dhil.net/research/talks/wasmfx-stacks2024-05.pdf>
- **Emrich & Hillerström. *Continuing Stack Switching in Wasmtime.* WAW 2025.** ✓
  <https://dhil.net/research/papers/wasmfxtime-waw2025.pdf> ·
  slides <https://effect-handlers.org/talks/wasmfx-waw2025.pdf>

## WebAssembly

- **Proposal:** <https://github.com/WebAssembly/stack-switching> ·
  [Explainer](https://github.com/WebAssembly/stack-switching/blob/main/proposals/stack-switching/Explainer.md)
  — **Phase 3**, champions McCabe & Lindley
- Lindley. *Stack switching for Wasm.* Wasm CG, Feb 2025. ✓
  <https://effect-handlers.org/talks/stack-switching-wasmcg-feb2025.pdf>
- *Iris-WasmFX: Modular Reasoning for Wasm Stack Switching.* Draft, Nov 2025.
  <https://homepages.inf.ed.ac.uk/slindley/papers/iris-wasmfx-draft-november2025.pdf>
- Pinckney, Guha et al. *Wasm/k.* 2020.
- Zakai. *Pause and Resume WebAssembly with Binaryen's Asyncify.* 2019.
  <https://kripken.github.io/blog/wasm/2019/07/16/asyncify.html>
- V8. *Introducing the WebAssembly JavaScript Promise Integration API.* <https://v8.dev/blog/jspi>
  · *JSPI has a new API* <https://v8.dev/blog/jspi-newapi>

**Code**
- Wasmtime upstream: <https://github.com/bytecodealliance/wasmtime> — walkthrough in
  [04-runtimes.md](04-runtimes.md) read at commit `83d1cf7` ✓
- Fork: <https://github.com/wasmfx/wasmfxtime> · tracking issues
  [#10248](https://github.com/bytecodealliance/wasmtime/issues/10248),
  [#9465](https://github.com/bytecodealliance/wasmtime/issues/9465)
- C fiber library: <https://github.com/wasmfx/fiber-c> — **a submodule of this repo**
- Effect-based I/O: <https://github.com/wasmfx/waeio>
- Benchmarks: <https://github.com/wasmfx/benchfx>

## OCaml

- Sivaramakrishnan et al. *Retrofitting Parallelism onto OCaml.* ICFP 2020.
  <https://arxiv.org/abs/2004.11663>
- Manual: <https://ocaml.org/manual/5.5/effects.html>
- `effects-examples`: <https://github.com/ocaml-multicore/effects-examples>
- `ocaml-multicont` (multi-shot): <https://github.com/dhil/ocaml-multicont>
- Eio: <https://github.com/ocaml-multicore/eio> ·
  `awesome-multicore-ocaml`: <https://github.com/ocaml-multicore/awesome-multicore-ocaml>
- *Dynamic Wind for OCaml Effect Handlers with Escaping Continuation Support.* SLE 2025.
  doi:10.1145/3806383.3815525

## Brachthäuser & the Effekt group (Tübingen)

Index: <https://pl.cs.uni-tuebingen.de/publications/> · <https://effekt-lang.org>

**The ones that matter here**
- **Muhcu, Schuster, Steuwer, Brachthäuser. *Multiple Resumptions and Local Mutable State,
  Directly.* ICFP 2025.** ✓ <https://pl.cs.uni-tuebingen.de/publications/muhcu2025multiple.pdf>
- **Gaißert, Bolz-Tereick, Brachthäuser. *Tracing Just-in-Time Compilation for Effects and
  Handlers.* OOPSLA 2025.** ✓ <https://pl.cs.uni-tuebingen.de/publications/gaissert2025tracing.pdf>
- **Voigt, Schuster, Brachthäuser. *Dynamic Wind for Effect Handlers.* OOPSLA 2025.** ✓
  <https://pl.cs.uni-tuebingen.de/publications/voigt2025dynamic.pdf> ·
  artifact <https://github.com/se-tuebingen/oopsla-2025-artifact-finalizers>
- **Müller, Schuster, Starup, Ostermann, Brachthäuser. *From Capabilities to Regions.*
  OOPSLA 2023.** ✓ <https://pl.cs.uni-tuebingen.de/publications/mueller23lift.pdf>

**Language design**
- Brachthäuser, Schuster, Ostermann. *Effect Handlers for the Masses.* OOPSLA 2018.
- —. *Effekt: Capability-Passing Style…* JFP 2020. ✓
- —. *Effects as Capabilities.* OOPSLA 2020.
- Brachthäuser, Schuster, Lee, Boruch-Gruszecki. *Effects, Capabilities, and Boxes.* OOPSLA 2022. ✓
- Leijen & Brachthäuser. *Taming Control-flow through Linear Effect Handlers.* HOPE 2018.

**Compilation**
- Schuster, Brachthäuser, Ostermann. *Compiling Effect Handlers in Capability-Passing Style.*
  ICFP 2020. ✓ · *Zero-cost Effect Handlers by Staging.* TR 2019.
- —. *All About That Stack: A Unified Treatment of Regions and Control Effects.* 2021.
- Schuster et al. *A Typed CPS Translation for Lexical Effect Handlers.* PLDI 2022 ·
  *Region-based Resource Management and Lexical Exception Handlers in CPS.* ESOP 2022.
- Müller et al. *Back to Direct Style: Typed and Tight.* OOPSLA 2023.
- Schuster et al. *Compiling Classical Sequent Calculus to Stock Hardware.* OOPSLA 2025 ·
  Lutze et al. *The Simple Essence of Monomorphization.* OOPSLA 2025.

**Types / capture tracking (the Scala arm)**
- Xie, Brachthäuser, Hillerström, Schuster, Leijen. *Effect Handlers, Evidently.* ICFP 2020.
- Boruch-Gruszecki et al. *Capturing Types.* TOPLAS 2023 · Odersky et al. *Safer Exceptions for
  Scala.* 2021 · Lee et al. *Qualifying System F<:.* OOPSLA 2024 · Lutze, Madsen et al. *With or
  Without You: Programming with Effect Exclusion.* ICFP 2023.

## Other efficient handler implementations

- Ma, Ge, Lee, Zhang. *Lexical Effect Handlers, Directly.* OOPSLA 2024 (**Lexa**).
  <https://cs.uwaterloo.ca/~yizhou/papers/lexa-oopsla2024.pdf> · <https://github.com/lexa-lang/lexa>
- **Ma, Jung, Zhang. *Virtualizing Continuations.* PLDI 2026.** doi:10.1145/3808289
- *Lexical Effect Handlers: Fast by Design, Correct by Proof.* SPLASH 2025.
- Zhang & Myers. *Abstraction-Safe Effect Handlers via Tunneling.* POPL 2019 · Zhang,
  Salvaneschi, Myers. *Handling Bidirectional Control Flow.* OOPSLA 2020.
- **Alvarez-Picallo, Freund, Ghica, Lindley. *Effect Handlers for C via Coroutines.* OOPSLA 2024
  (libseff).** ✓ <https://homepages.inf.ed.ac.uk/slindley/papers/libseff.pdf>
- Ghica, Lindley et al. *High-Level Effect Handlers in C++.* OOPSLA 2022.
- Leijen. *libhandler*; Leijen & Sivaramakrishnan. **libmprompt / libmpeff**:
  <https://github.com/koka-lang/libmprompt>
- Xie & Leijen. *Generalized Evidence Passing for Effect Handlers.* ICFP 2021.
- Karachalias, Pretnar et al. *Efficient Compilation of Algebraic Effect Handlers.* OOPSLA 2021.
- *Optimize Effect Handling for Tail-resumption with Stack Unwinding.* SLE 2025.

## Stacks and continuations

- Hieb, Dybvig, Bruggeman. *Representing Control in the Presence of First-Class Continuations.*
  PLDI 1990 · Bruggeman, Waddell, Dybvig. *…One-Shot Continuations.* PLDI 1996.
- Clinger, Hartheimer, Ost. *Implementation Strategies for First-Class Continuations.* HOSC 1999.
- **Dolan, Muralidharan, Gregg. *Compiler Support for Lightweight Context Switching.* TACO 2013
  (SWAPSTACK).** doi:10.1145/2400682.2400695
- Flatt & Dybvig. *Compiler and Runtime Support for Continuation Marks.* PLDI 2020.
- Appel. *Compiling with Continuations.* CUP 1992.
- Kiselyov. *An argument against call/cc.*
  <https://okmij.org/ftp/continuations/against-callcc.html>
- *Continuations: What Have They Ever Done for Us? (Experience Report).*
  <https://arxiv.org/abs/2408.17001>

## Benchmarking

- **`effect-handlers/effect-handlers-bench`** —
  <https://github.com/effect-handlers/effect-handlers-bench>
- Dagstuhl Seminar 21292, *Scalable Handling of Effects* (incl. benchmarking-chair governance):
  <https://drops.dagstuhl.de/storage/04dagstuhl-reports/volume11/issue06/21292/DagRep.11.6.54/DagRep.11.6.54.pdf>
- Marr, Daloze, Mössenböck. `are-we-fast-yet`. 2016.
- `hyperfine` <https://github.com/sharkdp/hyperfine> · `wrk2` <https://github.com/giltene/wrk2>

## Stack memory

- **Yu. *Evaluate the Stack Management in Effect Handlers using the libseff C Library.*
  Edinburgh, Nov 2025.** ✓ <https://arxiv.org/abs/2512.03083>
- Go: *Contiguous stacks* design doc ·
  <https://blog.cloudflare.com/how-stacks-are-handled-in-go/>
- Loom: *Fibers and Continuations for the JVM*
  <https://cr.openjdk.org/~rpressler/loom/Loom-Proposal.html> · JEP 444
- LLVM segmented stacks — <https://llvm.org/docs/SegmentedStacks.html>
- Compressed-stack *data structures* (different topic, related trade):
  <https://arxiv.org/abs/1706.04708>

## Theory

- Plotkin & Pretnar. *Handlers of Algebraic Effects.* ESOP 2009 / LMCS 2013.
- Kammar, Lindley, Oury. *Handlers in Action.* ICFP 2013 · Hillerström & Lindley. *Shallow Effect
  Handlers.* APLAS 2018.
- Hillerström, Lindley, Longley. *Asymptotic Speedup via Effect Handlers.* JFP 34 (2024).
  <https://arxiv.org/abs/2007.00605>
- Forster, Kammar, Lindley, Pretnar. *On the Expressive Power of User-Defined Effects.*
- Gunter, Rémy, Riecke. *A Generalization of Exceptions and Control in ML-like Languages.*
  FPCA 1995.
- Hillerström. *Foundations for Programming and Implementing Effect Handlers.* PhD thesis,
  Edinburgh 2021. <https://www.dhil.net/research/papers/thesis.pdf> — Appendix A is a
  comprehensive survey of first-class control operators.
