# WebAssembly stack switching

Condensed from `fx-research` note 03.

## 1. Why Wasm needs it

Core Wasm has a single, structured, **non-addressable** value stack and no way to capture or
reify it. Every source-language feature that needs to suspend — async/await, generators,
coroutines, lightweight threads, actors, first-class continuations — must otherwise be
simulated by whole-program transformation:

- **Asyncify** (Binaryen, Zakai 2019): a global CPS/state-machine transform. Instrumented
  functions pay runtime cost *and* code size. WasmFX measured Asyncify binaries at
  **9.2 KB vs 0.8 KB** on a coroutine microbenchmark, and TinyGo output at **597 KB vs 156 KB**.
- **Per-language state machines**: each async function heap-allocates its frame plus a resume
  state machine. Not compositional — "what colour is your function".
- **JSPI**: engine-level, but only bridges the JS/Wasm boundary; not a general intra-Wasm
  control mechanism.

## 2. The proposal

**Paper:** Phipps-Costin, Rossberg, Guha, Leijen, Hillerström, Sivaramakrishnan, Pretnar,
Lindley. *Continuing WebAssembly with Effect Handlers.* OOPSLA 2023.

**Proposal:** <https://github.com/WebAssembly/stack-switching> — champions Francis McCabe and
Sam Lindley. Reached **Phase 2 in August 2024**, now at **Phase 3 (Implementation)**. It did
**not** make WebAssembly 3.0 (2026).

```wat
(tag $yield (param i32) (result i32))   ;; control tags generalise exception tags
(type $ct (cont $ft))                   ;; continuation heap type over a function type
```

| Instruction | Meaning |
|---|---|
| `cont.new $ct` | make a suspended continuation from a func ref |
| `resume $ct hdl*` | run it under a handler table; establishes **parent–child** |
| `suspend $tag` | suspend to the nearest enclosing handler for `$tag` |
| `switch $ct $tag` | **symmetric** peer-to-peer switch, no handler round-trip |
| `resume_throw $ct $e hdl*` | cancel: raise an exception at the suspension point |
| `resume_throw_ref $ct hdl*` | same, with an `exnref` |
| `cont.bind $ct $ct'` | partial application; **no allocation** (slots preallocated at `cont.new`) |

### Design choices that matter

- **Asymmetric (handler-based) by default, symmetric as an optimization.** `resume` establishes
  a caller/callee relation that composes with call semantics, exceptions and traps "with no
  special plumbing". But a scheduler doing `task1 → scheduler → task2` costs **two** switches;
  `switch` collapses that to one ("bag of stacks").
- **"Sheep handlers".** Handling is coupled to resumption rather than to a separate `handle`
  construct: deep-like (the body is always wrapped in *some* handler) but shallow-like (the
  handler can differ on each resume). Benefits: concise handler tables (tag → label via
  `br_table`), and **handlers are in 1:1 correspondence with active continuations**, which makes
  the stack-segment implementation uniform.
- **No return clause** — you wire the join point up explicitly.
- **One-shot (affine) continuations, dynamically checked.** Resuming twice traps. Follows
  OCaml 5. Rationale: *"One-shot continuations admit direct and efficient implementations of
  continuations as stacks in which it is never necessary to copy the stack."* An affine type
  system was considered and rejected as too much burden on producers and validators.
- **No GC dependency.** Deliberately designed so plain reference counting works: cycles are
  impossible because a continuation is marked dead the instant it is resumed. **But** the
  no-cycles property costs a fresh continuation object on every `suspend`/`cont.bind`. The
  alternative — reuse the object — needs a **fat pointer: (object pointer, 64-bit sequence
  counter)**, with mismatch ⇒ linearity violation ⇒ trap. The trade is left to the engine and is
  semantically transparent. *(Wasmtime took the fat-pointer option — see
  [04-runtimes.md](04-runtimes.md) §2. Note this is exactly the "stable identity, movable
  object" pattern that recurs throughout [05-stack-memory.md](05-stack-memory.md).)*

### Discussed but not in the MVP

- **Named handlers** (`resume_with` / `suspend_to`) — multi-prompt delimited control with
  generative prompts. Post-MVP per Lindley's Feb-2025 CG talk.
- **Barriers** — a block that bars suspension across its boundary, for legacy code.
- **Multi-shot** via `cont.clone`. Explicitly flagged as hard for engines using **heterogeneous
  stacks mixing Wasm and C++ frames, which cannot easily be moved or copied**.
- **Tail-resumptive handlers.** No facility to identify or inline them; acknowledged as the
  single biggest missing optimization hook — and it is the one that matters most in every
  high-level handler implementation.

## 3. Implementation status

| Component | Status |
|---|---|
| Reference interpreter | ✓ full instruction set |
| **Wasmtime** | ✓ upstreamed from `wasmfx/wasmfxtime`; `Config::wasm_stack_switching` **off by default**, x86-64 Linux only. Tracking: [#10248](https://github.com/bytecodealliance/wasmtime/issues/10248), [#9465](https://github.com/bytecodealliance/wasmtime/issues/9465) |
| Wizard | ✓ |
| Binaryen, wasm-tools | ✓ |
| Formal spec | ✓ SpecTec; **WasmCert** mechanised soundness proof |
| Separation logic | *Iris-WasmFX* (draft, Nov 2025) |
| Browsers | not yet; the plan is to adapt existing **JSPI** infrastructure |

Wasmtime's tracking issue lists as **not yet done**: `resume.throw`, continuation
**deallocation**, GC integration, Windows/Pulley, Winch, restricting hostcalls from
continuation stacks, and — the interesting one — **unifying stack switching with the existing
fiber stacks and the pooling allocator**.

### The staging lesson (Emrich & Hillerström, WAW 2025)

1. **Prototype**: interpret each instruction as a **libcall** into Rust calling the existing
   `wasmtime-fiber` API. No Cranelift changes.
2. **Native**: add one platform-independent CLIF instruction **`stack_switch(source_ctx,
   dest_ctx, payload)`** over pointers to *control contexts*, modelled on **SWAPSTACK** (Dolan,
   Muralidharan & Gregg, TACO 2013). Note it is **symmetric** at the CLIF level even though the
   Wasm-level proposal is asymmetric — the parent/child bookkeeping moves into generated code.
3. Migrate the stack layout in steps, stripping libcalls until only `cont.new` needs the runtime.

**Result: up to ~6×** from the single commit enabling native switching — `c10m` 1.49×,
`sieve` 2.61×, `skynet` 1.72×, `state` 4.48×, `suspend_resume` **5.97×**.

**Why so large.** The libcall path made every switch a nest of calls, and stack switching breaks
the CPU's **Return Address Stack** predictor: the `ret`s on the resumee stack no longer match
the `call`s the RAS recorded. They measured **4 guaranteed branch mispredictions per stack
switching operation** in the prototype. *Any stack-switching cost model that ignores the RAS is
wrong.*

## 4. What `benchfx` actually measures

From Hillerström, *Benchmarking WasmFX* (Wasm Stacks subgroup, May 2024). Run-time ratio, lower
is better, Asyncify = 1.00:

| Benchmark | Shape | Asyncify | WasmFX base | WasmFX dev | Binary size |
|---|---|---|---|---|---|
| **prime sieve** | actor-style, 8100 coroutines, many yields, **shallow** | 1.00 | 5.31 | 3.25 | 41 KB vs 39 KB |
| **c10m** | HTTP-server sim, 10 M coroutines, 10 000 concurrent, one yield each, **shallow** | 1.00 | 3.87 | 2.76 | 9.1 KB vs **723 B** (12.7×) |
| **c10m + I/O in hot loop** | as above, with a real I/O call | 1.00 | 1.41 | 1.38 | — |
| **skynet** | nested tree concurrency, 10 M coroutines, only 6 active, **deep** | 1.00 | 4.18 | 3.25 | 9 KB vs **327 B** (27.5×) |
| **hello world** | 2 coroutines, print and yield | 2.95 | **1.00** | **1.00** | 33 KB vs 24 KB |

Three things to take from this table:

1. The axes varied deliberately are **number of live coroutines**, **call-stack depth**, and
   **yield frequency** — plus a variant with real I/O to check whether switching cost matters
   once you do actual work. It mostly doesn't: **3.87 → 1.41**.
2. Asyncify wins on raw switch time precisely because it never touches a real stack; WasmFX wins
   hugely on **binary size** (up to 27×) and on **tail latency under load**.
3. `hello world` — few coroutines, frequent yields — is the one case where WasmFX wins outright,
   because Asyncify's instrumentation tax is paid on every call.

### The stack-pooling result

| `c10m` | run-time ratio |
|---|---|
| Asyncify | 1.00 |
| WasmFX dev, **stack pool** | 2.76 |
| WasmFX dev, **no pool** | **187.73** |

**Pooling stacks is worth ~68× on this workload.** The talk frames the underlying choice as
**unsafe stacks** (`malloc`'d, no guard page ⇒ undetected overflow silently corrupts the heap)
versus **safe stacks** (`mmap`'d, guard pages per stack, stack pools for reuse, and
reserved-but-uncommitted pages above the guard page as a "suggestive scheme for stack
growing"). That last is the `libmprompt` idea: reserve address space, commit on demand, grow in
place, never relocate.

### Macrobenchmark: HTTP/1.1 server

Built on **Waeio**, `picohttpparser` for parsing, **`wrk2`** as load generator
(`-t4 -c1000 -R{40,60,80}000 -d60s`):

| | peak req/s | max latency @40K | @60K | @80K |
|---|---|---|---|---|
| Asyncify | 79 587 | 6.6 ms | 14.89 ms | **742 ms** |
| WasmFX (base) | 88 116 | 6.0 ms | 7.6 ms | 16 ms |
| WasmFX (dev) | 88 270 | 6.3 ms | 6.3 ms | **8 ms** |

Throughput differs by ~11%, but **tail latency at saturation differs by ~90×**. The
microbenchmarks would have told you Asyncify was 3–4× faster. **This is the strongest argument
in the whole literature for macrobenchmarking control-flow features.**

## 5. The memory result

OOPSLA'23 evaluation — 10 000 concurrent coroutines, 10 M total, C compiled with clang-14
`-O3`, stacks allocated with mimalloc rather than mmap so all three schemes match:

| | binary | wall time | **peak memory** |
|---|---|---|---|
| WasmFX | 0.8 KB | 2700 ms | **55.5 MB** |
| Asyncify | 9.2 KB | 700 ms | 54.1 MB |
| Bespoke hand-written state machine | 0.9 KB | 140 ms | **13.4 MB** |

The paper's own reading: *"The primary reason for the space efficiency [of the bespoke version]
is that it does not allocate 4096 bytes stack for each coroutine."* And in future work: *"the
fixed-sized system stacks induce allocation burden that may be unnecessary: experiments in
other languages have found that most continuations require little stack memory."*

**This is the stack-compression thesis statement, made by the WasmFX authors themselves.** A
4 KB minimum per suspended continuation is 4 GB at a million coroutines.

### The two stacks — where most confusion lives

1. The **engine/native stack** holding Wasm frames and locals. Not addressable from Wasm, so
   relocatable in principle — except engines interleave host/C++ frames on it (which is also why
   multi-shot is hard).
2. The **shadow stack in linear memory**, which C/C++/Rust toolchains use for any address-taken
   local, `alloca`, or large aggregate. It *is* addressable, pointers into it are
   indistinguishable from any other `i32`, and therefore it **cannot be moved or compacted**.
   Every coroutine needs its own shadow-stack region, and **that region is what the 4 KB is
   really about.**

The design space splits by which stack you attack; the shadow stack is both the bigger problem
and the harder one. See [05-stack-memory.md](05-stack-memory.md) §4.

## 6. Neighbouring mechanisms

- **JSPI** — `WebAssembly.Suspending` / `promising`, **phase 4**, shipping in Chrome. Uses the
  JS/Wasm boundary as the suspension delimiter. It already gives V8 machinery for multiple Wasm
  stacks, which is why the CG expects browsers to build core stack switching on top of it.
- **Component Model async** — `stream`/`future`/task in WASI 0.3; needs the same capability,
  currently implemented in Wasmtime with fibers.
- **Wasm/k** (Pinckney, Guha et al. 2020) — the earlier attempt at first-class continuations for
  Wasm 1.0; single untyped control tag, doesn't compose with typed function references or
  exceptions.
- **Exception handling** — `exnref` and its interaction with `resume_throw` is where
  cancellation and finalizer semantics live.
