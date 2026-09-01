# Two runtimes at code level: OCaml 5 and Wasmtime

Condensed from `fx-research` notes 04 (OCaml) and 09 (Wasmtime source walkthrough).
These are the two "how a real system actually does it" data points.

---

# Part I — OCaml 5

**Primary source:** Sivaramakrishnan, Dolan, White, Kelly, Jaffer, Madhavapeddy.
*Retrofitting Effect Handlers onto OCaml.* PLDI 2021. Shipped in **OCaml 5.0 (Dec 2022)**;
new effect *syntax* in **5.3**. This is the paper everyone else benchmarks against, and its
stack design is the closest existing thing to what "cheap suspended stacks" should look like.

## 1. Design constraints they set themselves

1. **Backwards compatibility** — existing code keeps working, including code assuming a call
   returns exactly once.
2. **Performance profile preserved** — code that does *not* use handlers must not slow down.
   Achieved: **mean <1% overhead on a 54-program macro suite** (Coq, Cubicle, AltErgo, menhir,
   irmin, cpdf, decompress…). 32 of 54 under 5%; 8 over 10%.
3. **Tooling compatibility** — `gdb`/`perf`/DWARF backtraces must still work across
   non-contiguous stacks. Almost nobody else takes this on, and it forced real work.

## 2. Fibers

The program stack is a **linked list of heap-allocated stack segments ("fibers")**. Each handled
computation runs in its own fiber; a delimited continuation *is* a fiber plus its parent chain.

Layout (bottom → top): `handler_info` (parent pointer + `clos_hval`/`clos_hexn`/`clos_heffect`)
· context block (2 words for DWARF/GC across callbacks) · top-level exn handler · return pc ·
**OCaml frames (variable, initially 16 words)** · red zone (default 16 words) · footer (saved
exception pointer, saved stack pointer).

- **Allocation:** plain `malloc`, freed when the handled computation returns. A **stack cache of
  recently freed stacks** speeds allocation. Not GC-managed — see §4.
- **Growth = resize, not segment.** An overflow check in every function prologue compares `rsp`
  against a threshold in `Caml_state`; on overflow the **whole fiber is copied to a new area of
  double the size**. In Farvardin & Reppy's taxonomy this is **resize** per fiber, with fibers
  linked together.
- **Sound only because OCaml never generates pointers into the stack.** *"Since OCaml does not
  generate pointers into the stack, the two `fiber_info` fields are the only ones that need to
  be updated when fibers are moved."* Copy the bytes, patch two words, done. **Compare the Wasm
  shadow stack, where this is exactly what you cannot do.**
- **Red zone as a code-size optimization.** The overflow check is elided for leaf functions whose
  frame fits the red zone. Cost on OCaml text-section size: **+19%** vs stock with a 16-word red
  zone, **+30%** with none; 32 words buys nothing further. **The overflow checks are the single
  biggest cost of the whole design, and it is a code-size cost, not a time cost.**
- **Switching is nearly free** because *stock OCaml has no callee-saved registers* — switching is
  save/load of the exception pointer and stack pointer. The paper calls this "a fortuitous design
  choice in stock OCaml".
- **External C calls run on the system stack**; **effects cannot propagate across C frames**,
  deliberately, because "managing C frames as part of the continuation is a complex endeavour".
  *(Same reasoning that makes multi-shot hard in Wasm engines with heterogeneous stacks.)*

## 3. The cost model everybody cites

Cycle-accurate Intel PT tracing, 10 iterations + 3 warm-ups. Calibration: idle NUMA-local memory
load latency = **93.2 ns**.

| Step | What it is | Time |
|---|---|---|
| a→b | allocate a new fiber and switch to it | **23 ns** (dominated by `malloc`) |
| b→c | perform the effect, reach the handler | **5 ns** |
| c→d | resume the continuation | **11 ns** |
| d→e | return from the fiber and free it | **7 ns** |

**Read this as: a suspend/resume round trip is ~16 ns, but *creating* a fiber is 23 ns and
allocation dominates it.** That ratio is the whole argument for stack caches, pools, and smaller
initial stacks — the same conclusion Wasmtime reached from the other direction (no-pool `c10m`
was 68× worse).

Other headline comparisons: handlers installed but never performed vs idiomatic non-tail calls,
**10.02×**; the same via a concurrency monad, **67.09×**. Generator over a depth-25 binary tree
(2²⁶ switches): 2.76× slower than hand-written selective-CPS, monad 8.69×. Chameneos: OCaml
fastest, monad 1.67×, **Lwt 4.29×**. Attaching a GC finaliser to every captured continuation
costs **4.1×** (generator) / **2.1×** (chameneos). Exceptions cost no more than stock.

GC evidence for stack-allocated frames: on `ack`, major collections were 0 (stock) / 1 (effects)
/ **112 (monad)**.

**HTTP/1.1 server** (httpaf + libev vs Lwt and Go 1.13 at `GOMAXPROCS=1`, `wrk2`, 1000
connections): throughput plateaus ~30k req/s for all three; at 2/3 load **the effects version has
the best tail latency**. Same shape as WasmFX vs Asyncify — the effect-handler version wins on
latency, not throughput.

Bonus: OCaml can produce **backtraces for suspended continuations**, so you can snapshot the
stack of every in-flight request. Lwt and Async structurally cannot.

## 4. Deliberate limitations

- **One-shot only.** Resuming twice raises `Continuation_already_resumed`. The *formal
  semantics* in the paper allows multi-shot by copying fibers; the implementation drops it.
  Multi-shot is available as a library, `ocaml-multicont`, which clones fibers — **several
  cross-language comparisons of "OCaml multi-shot" are really measuring that library, not a
  native capability.**
- **Continuations must be resumed exactly once, by convention, or you leak.** Fibers are
  `malloc`'d and freed on return, so an abandoned continuation leaks the stack *and* any
  sockets/fds it holds. The escape hatch is `Gc.finalise` calling `discontinue k Unwind`, but
  that costs 2–4×, so it is **not** on by default. *This is precisely the problem `resume_throw`
  exists for in Wasm.*
- **No effect types.** Unhandled effects raise `Effect.Unhandled` at the perform site.
- **No effects across C frames**, signal handlers, finalisers, or GC alarms.

## 5. DWARF across segmented stacks

Worth reading if you ever have to make a stack-switching engine debuggable. The trick: emit DWARF
bytecode at the entry to an effect-handler block that **follows the `parent_fiber` pointer and
dereferences `saved_sp`** to compute the caller's CFA. Residual limitation, and it is `perf`'s
fault: `perf` *dumps* the user call stack at sample time rather than unwinding, so it only
captures the current fiber.

---

# Part II — Wasmtime

Read from `bytecodealliance/wasmtime` at commit **`83d1cf7`**; line references are to that
commit, and the two load-bearing ones below (`store.rs:2137`, `config.rs:301`) were re-checked
against the `dependencies/wasmtime/` submodule's pinned commit `d8a0da6d66` and still hold.

**Bottom line:** the instruction set is fully implemented and tested for x86-64 Linux under
Cranelift, and the code generation is genuinely good — the whole switch lowers to one three-word
context exchange plus an indirect jump, with handler dispatch as a `br_table`. **There is no
stack compression of any kind, and memory is the weakest part.**

## 1. Support status

`stack-switching` is **Tier 3**: not phase 4, tests 🚧, unfinished, unfuzzed, no API, no C API.
*"Currently the implementation is only for x86_64 Linux."*

- `Config::wasm_stack_switching` — **off by default**; requires `function_reference_types` and
  `exceptions`.
- The target gate is explicit: `control_context_size()` returns `24` for `(X86_64, Linux)` and
  `wasm_unsupported!` otherwise.
- **Winch** has no support (a *faux feature* purely so `cfg` blocks compile). **Pulley** — the
  portable interpreter — has none either. Since continuations are an actual machine-level
  SP/FP/IP exchange, they cannot work in an interpreter without a separate design. **So there is
  no interpreter implementation of stack switching in Wasmtime.**
- **No GC integration**: storing a `contref` in a GC struct hits `stack_switching_unsupported()`.
- Tests: `tests/all/stack_switching.rs` (1391 lines) plus **46 `.wast` files**.

## 2. Runtime representation

**`VMContRef`** holds common stack information (limits, state, handler list), the `parent_chain`,
a `last_ancestor` shortcut pointer, a `revision` counter, the stack, and two payload buffers.
Field offsets are cross-checked against `VMOffsets` by `offset_of!` unit tests — that is how the
Rust struct and the Cranelift-generated loads stay in sync.

**`VMContObj`** — the Wasm-level `(ref $ct)` value — is a **fat pointer**
`{ contref, revision }`, i.e. two pointer-sized words, packed at the CLIF level as
`(revision << ptr_bits) | contref`. **This is exactly the sequence-counter scheme the WasmFX
paper proposed:** every consuming instruction checks the witness against the object's counter
and increments it; a mismatch traps with `TRAP_CONTINUATION_ALREADY_CONSUMED`. That is how
**one-shot linearity is enforced dynamically**, and it lets the physical `VMContRef` be reused
across suspensions without allocating a fresh object each time.

**`VMStackChain`** is a three-variant enum (`Absent` | `InitialStack` | `Continuation`) with
discriminants shared with the compiler. Two invariants: the store's chain is always zero-or-more
`Continuation`s terminated by `InitialStack`, and a suspended continuation is **never** in it;
and for the *currently running* stack the live limits are in `VMStoreContext` while the stack's
own copy is stale (the reverse for parents and suspended continuations).

**States:** `Fresh` → `Running` → (`Parent` | `Suspended`) → `Returned` | `Trapped`. `Fresh` is
the only state in which `cont.bind` may add arguments.

Payload and handler buffers are `VMHostArray<T>` whose **`data` always points into the
continuation's own stack**, not the heap.

## 3. The stack and the CLIF instruction

The stack's top holds saved RIP / RBP / RSP (the **control context**, 24 bytes), then an args
capacity and args buffer, then usable space down to a `PROT_NONE` guard page. For an *active*
continuation the control context holds the PC/RSP/RBP of the **parent**; for a *suspended* one,
the values at the point of suspension.

**Frame-pointer walking works by construction** — the layout deliberately puts the saved RBP
adjacent to the saved RIP, so a naïve FP-chain walk crosses from a continuation into its parent
for free. (DWARF CFI for the trampoline is a **TODO**, unlike OCaml 5, which went to considerable
trouble here.)

The Cranelift instruction is `stack_switch(store_context_ptr, load_context_ptr, in_payload0)`,
marked `.other_side_effects().can_load().can_store().call()`. Layout on x64 is
`{ sp: +0, fp: +8, ip: +16 }` — chosen so a control context can sit *inside* a frame-pointer
chain — with the payload register fixed to **`rdi`** so both sides agree without a calling
convention. Emission:

```asm
;; for offset in { rsp@+0, rbp@+8 }:
mov  tmp1, [load_context_ptr + offset]      ; load new
mov  [store_context_ptr + offset], reg      ; save old
mov  reg, tmp1                              ; install new
mov  tmp1, [load_context_ptr + 16]          ; target IP
lea  tmp2, [rip + resume]                   ; our resume point
mov  [store_context_ptr + 16], tmp2         ; save it
jmp  tmp1
resume:
```

**That is the entire stack switch: six `mov`s, one `lea`, one indirect `jmp`.** No register
save/restore is emitted — the instruction is declared to clobber everything, so **regalloc2
spills only what is actually live across it**, which is strictly better than `wasmtime-fiber`'s
pessimistic push of all callee-saves. This is the **SWAPSTACK** design; it is symmetric at the
CLIF level even though the Wasm proposal is asymmetric.

## 4. Optimizations present

Ranked by what they buy:

1. **Native switching, no libcall** — the whole point of the rewrite; up to **6×**, and it
   removes the 4 RAS mispredicts per switch.
2. **Register saving delegated to regalloc2.**
3. **Alias regions (TBAA).** Stack switching declares two disjoint abstract regions
   (`vmcontref_region`, `continuation_stack_memory_region`), which is what lets redundant-load
   elimination and store-to-load forwarding clean up the long chains of little loads/stores these
   instructions generate. A debug assertion enforces 100% tagging.
4. **Stack-slot reuse for payload/handler buffers** — a function with many `resume`s pays for
   *one* buffer each, not one per site. (`switch`'s temp control-context slot is a noted
   exception: it is per-instruction, per a TODO.)
5. **Handler dispatch as `br_table`** — the suspending side computes the index during
   `search_handler` and passes it in the payload word; the resuming side does one jump-table
   branch.
6. **Handler-list partitioning** — suspend handlers before switch handlers, plus a boundary
   index, so `search_handler` scans only the relevant half.
7. **Return as the zero-cost fast path** — `CONTROL_EFFECT_RETURN_DISCRIMINANT == 0`, so one
   `brif` on the raw word distinguishes return from everything else; trap-vs-suspend is
   discriminated only on the slow path. (A source TODO wonders whether suspension should be the
   fast path instead, "as I hypothesise suspensions occur more often than normal returns in a
   stack-switching application".)
8. **`last_ancestor` shortcut** — chain splicing on `resume`/`switch` is O(1) rather than a walk.
9. **Fat-pointer revision counters** avoid allocating a continuation object per suspension.

**Notable absences:** no tail-resumptive handler optimization; **no inline caching or memoization
of handler search**; no `cont.clone`/multi-shot.

`search_handler` is the only unbounded loop in the design — a **doubly-nested loop entirely in
CLIF**, outer over the parent chain, inner over that stack's handler list, comparing
`*mut VMTagDefinition` pointers. This is exactly the O(handler-stack-depth) cost that libseff
measured and that lexical designs compile away.

## 5. Memory — the real finding

```rust
/// Allocates a new continuation. Note that we currently don't support
/// deallocating them. Instead, all continuations remain allocated
/// throughout the store's lifetime.
pub fn allocate_continuation(&mut self) -> Result<*mut VMContRef> { … }
```

Backed by `continuations: Vec<Box<VMContRef>>`, commented *"Contains all continuations ever
allocated throughout the lifetime of this [store]"*. So per `cont.new`:

| | |
|---|---|
| `VMContRef` | one `Box` (individual `malloc`) |
| stack | one **`mmap` of `async_stack_size + page_size`**, `PROT_NONE` then `mprotect` RW |
| default `async_stack_size` | **2 MiB** |
| pooling / reuse / freeing | **none / none / none, until the store is dropped** |

**It is less catastrophic than "2 MiB × N" suggests, and the reason matters:** the mapping is
anonymous and Linux commits lazily, so *resident* memory per suspended continuation is roughly
the pages actually touched. **Wasmtime today gets its memory efficiency from kernel overcommit**
— precisely the strategy the 2025 Edinburgh study found to be the best general balance.

But three costs are real and unbounded:

- **2 MiB of address space per continuation, never reclaimed** — ~500 continuations per GiB of
  VA, plus one VMA per stack, and the kernel's `max_map_count` (65530 default) becomes a hard
  ceiling on live continuations.
- **Touched pages are never returned.** A continuation that ran deep once keeps its RSS forever.
- **One `mmap` + `mprotect` pair per `cont.new`**, with no pool to amortize it — against
  Wasmtime's own measurement that `c10m` is 187.73× slower without a stack pool.

### The contrast one directory over

Wasmtime *already has* `pooling/unix_stack_pool.rs` for `wasmtime-fiber` stacks used by `async`
support: one big `Mmap` carved into fixed-size slots with guard pages, indices from a
`SimpleIndexAllocator`, and on release a `zero_stack` policy that keeps
`async_stack_keep_resident` bytes warm and `madvise`s the rest away. **None of this is wired up
to continuations.** That is exactly the "unify stack switching with fiber stacks and the pooling
allocator" item on tracking issue #10248.

### Is there any stack compression?

**No.** Grepping the tree for `compress` finds only GC stack maps dividing slot offsets by 4,
32-bit compressed GC references, zstd for the module cache, and MPK guard-region "compression".
There is no copy-out-on-suspend, no shrinking, no segmentation, no right-sizing, and no size
hint from the producer. **A continuation's stack is allocated once at `cont.new`, at a size
chosen by a global config knob that was designed for host async fibers, and never changes.**

## 6. Where to look

```
crates/wasmtime/src/runtime/vm/stack_switching.rs          VMContRef, VMContObj, VMStackChain, cont_new
  …/stack_switching/stack/unix.rs                          mmap, stack layout, initialize, fiber_start
  …/stack_switching/stack/unix/x86_64.rs                   wasmtime_continuation_start trampoline
crates/wasmtime/src/runtime/store.rs:2137                  allocate_continuation  <- the memory problem
crates/wasmtime/src/runtime/vm/traphandlers/backtrace.rs:302  trace_through_continuations
crates/cranelift/src/func_environ/stack_switching/instructions.rs
    :13    control_context_size (x86_64-linux gate)        :1154  search_handler
    :1287  cont.bind            :1310  cont.new            :1407  resume / resume_throw
    :1901  suspend              :1977  switch
  …/stack_switching/control_effect.rs                      payload encoding
  …/stack_switching/fatpointer.rs                          revision fat pointer
cranelift/codegen/meta/src/shared/instructions.rs:981      CLIF stack_switch definition
cranelift/codegen/src/isa/x64/inst/emit.rs:547             the six movs and a jmp
tests/all/stack_switching.rs, tests/misc_testsuite/stack-switching/*.wast
```
