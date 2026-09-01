# lit-review/ — effect handlers, stack switching, and stack memory

Condensed from [`fx-research`](https://github.com/) (assembled 2026-08-26, local clone at
`../fx-research`), which holds the long-form literature notes. This is the working subset:
the facts, numbers, and open problems that bear on benchmarking stack switching in this repo.

## Reading order

| | File | What's in it |
|---|---|---|
| 1 | [01-background.md](01-background.md) | Vocabulary, the four-way continuation taxonomy, the implementation families, the lineage |
| 2 | [02-benchmarking.md](02-benchmarking.md) | The two benchmark suites, methodology worth copying, what the field measures badly |
| 3 | [03-wasm-stack-switching.md](03-wasm-stack-switching.md) | The proposal, its design choices, implementation status, `benchfx` results |
| 4 | [04-runtimes.md](04-runtimes.md) | OCaml 5 fibers and Wasmtime's implementation, at code level |
| 5 | [05-stack-memory.md](05-stack-memory.md) | The relocation invariant, five strategies, collected cost numbers, the Wasm design space |
| 6 | [06-openings.md](06-openings.md) | The five gaps and concrete project openings |
| — | [bibliography.md](bibliography.md) | Every source, with links |

If you read two: **02** for methodology, **05** for the memory problem.

## The short version

**The measurement gap is the opportunity.** Essentially every results table in the
effect-handler literature is wall-clock only. The two places memory *was* reported are the two
places the headline result turned out to be about memory: WasmFX at **55.5 MB vs 13.4 MB** for
a hand-written state machine, and Loom's virtual threads at "a few hundred bytes". Nobody
reports **bytes per suspended continuation**, and no benchmark sweeps *number of live suspended
continuations* as a parameter.

**The WasmFX authors named the problem themselves.** Their 4× memory penalty was attributed
entirely to allocating a fixed 4096-byte stack per coroutine — *"most continuations require
little stack memory."*

**One invariant governs the whole design space:** you may relocate a stack only if nothing
holds a pointer into it. That is why OCaml can copy-and-double freely (the compiler never
generates interior pointers), why Go can copy *and shrink* goroutine stacks, why Loom can
freeze frames into right-sized heap chunks — and why C, C++, and Wasm's linear-memory
**shadow stack** cannot. Every workaround in the literature is the same shape: a **stable
indirection** (Effekt's prompts, Loom's chunk handles, Zhang's software MMU, Wasm's
fat-pointer revision counters).

**Allocation dominates.** OCaml: creating a fiber costs 23 ns against 5/11/7 ns for
perform/resume/return. Wasmtime: stack pooling is worth **68×** on `c10m`. libseff: segment
recycling is worth **3–34×**. If you are making stack switching fast, you are mostly making
stack *allocation* fast.

**Microbenchmarks mislead about control-flow features.** Asyncify beats WasmFX 3–4× on
microbenchmarks and loses **~90×** on tail latency at saturation in a real HTTP server. OCaml's
effect version loses on throughput to Lwt and Go and wins on tail latency. The interesting
property of stack switching is latency and composability, not throughput.

**Upstream Wasmtime has no stack compression of any kind.** Every `cont.new` `mmap`s a fresh
**2 MiB** stack (the host-async `async_stack_size` knob doing double duty), nothing is pooled,
and *nothing is ever freed until the store is dropped*. The sophisticated
keep-resident/decommit pooling that already exists for async fiber stacks is not wired up to
continuations. Details in [04-runtimes.md](04-runtimes.md).

## Key numbers

| Measurement | Value | Source |
|---|---|---|
| OCaml: allocate fiber + switch to it | **23 ns** (allocation-dominated) | Sivaramakrishnan et al. 2021 |
| OCaml: perform → handler | 5 ns | ” |
| OCaml: resume continuation | 11 ns | ” |
| OCaml: return + free fiber | 7 ns | ” |
| OCaml: initial fiber frame area | 16 words | ” |
| OCaml: text-size cost of overflow checks | +19% (16-word red zone) / +30% (none) | ” |
| WasmFX prototype stack size | **4096 B** per coroutine | Phipps-Costin et al. 2023 |
| WasmFX vs bespoke state machine (10k coroutines) | **55.5 MB vs 13.4 MB** | ” |
| Wasmtime `c10m`: no stack pool vs pool | **68×** slower | Hillerström 2024 |
| Wasmtime: native switching vs libcall | up to **6×** | Emrich & Hillerström 2025 |
| Wasm stack switch: branch mispredicts | **4 guaranteed per switch** (libcall impl.) | ” |
| Upstream Wasmtime stack per `cont.new` | **2 MiB**, never freed | wasmtime `83d1cf7` |
| libseff: recycled vs freed segments (hot split) | **3–34×** | Alvarez-Picallo et al. 2024 |
| libseff: hot split worst case | 11× (gone by ~13 FLOPs of real work) | ” |
| Asyncify vs WasmFX: tail latency @80K req/s | **742 ms vs 8 ms** | Hillerström 2024 |
| Go initial goroutine stack | 2 KB | Go runtime |
| libmprompt gstack: committed / reserved | 4 KiB / 8 MiB | libmprompt |
| Disabling the RAS in ordinary code | 1.02–1.07× | Farvardin & Reppy 2020 |
| (calibration) idle NUMA-local memory load | 93.2 ns | Sivaramakrishnan et al. 2021 |

## How this connects to the repo

- **`benchmark/fiber-c/`** is not merely similar to the Wasm benchmarking effort — it *is* the source
  language of [`benchfx`](https://github.com/wasmfx/benchfx), the suite described in
  [02-benchmarking.md](02-benchmarking.md) §2. Its `examples/*.c` are the microbenchmarks whose
  numbers appear in [03-wasm-stack-switching.md](03-wasm-stack-switching.md) §4.
- **`benchmark/benches/multicore/multicore-effects/`** maps onto the four-way resumption taxonomy in
  [01-background.md](01-background.md) §1 — see the table there. It is the OCaml-side
  counterpart to `benchfx`.
- **The measurement gap is directly actionable here.** Both suites in this repo run on the
  reference interpreter (see [`../RUNNING.md`](../RUNNING.md)), which is a semantics oracle
  rather than a timing instrument — but *memory* per suspended continuation is exactly the axis
  the literature leaves open, and it is measurable on a real engine.
