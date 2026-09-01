# Optimizing Stack Switching with Stack Compression

Goal statement for the project. Written 2026-08-31 against the pinned submodules — Wizard
`4a539337` (2026-08-20) and Wasmtime `d8a0da6d66` (2026-08-28). Every `path:line` below was
checked at those commits; if a submodule moves, re-check before quoting.

Companion documents: [`../lit-review/`](../lit-review/) holds the literature in depth,
[`../RUNNING.md`](../RUNNING.md) how the suites run, [`../CLAUDE.md`](../CLAUDE.md) the map.

---

## 1. The goal

**Make a suspended WebAssembly continuation cost memory proportional to what it holds, not to
a fixed reservation chosen at creation — without giving back the switching speed the engines
have already won.**

Stack switching (the `stack-switching` proposal: `cont.new` / `resume` / `suspend` / `switch` /
`resume_throw` / `cont.bind`) gives Wasm stackful coroutines: a computation can suspend from any
call depth and be resumed later. The way every engine implements this is the obvious one — each
continuation gets its own native stack, and a switch is a swap of stack pointers. That makes
switching fast (Wasmtime's inline switch is a handful of `mov`s and an indirect `jmp`;
Wizard's `resume` is ~10 instructions) and it makes memory the problem:

- **A stack is allocated at a fixed size, at `cont.new`, before anything is known about how deep
  the computation will go.** Wizard: 512 KiB. Wasmtime: 2 MiB. The WasmFX prototype: 4 KiB —
  and even that was enough to make WasmFX use **55.5 MB against 13.4 MB** for a hand-written
  state machine on 10 000 live coroutines, a 4× gap the authors attribute *entirely* to the
  per-coroutine stack: *"most continuations require little stack memory."*
- **The stack is held for as long as the continuation is suspended**, however little of it is
  live. A generator parked between two yields holds a few frames' worth of state and a whole
  stack's worth of reservation.
- **Nobody measures it.** No paper reports bytes per suspended continuation and no benchmark
  sweeps the number of live suspended continuations as a parameter
  ([`06-openings.md`](../lit-review/06-openings.md) §2a). The two places memory *was* reported
  (WasmFX, Loom) are the two places the headline result turned out to be about memory.

The thesis, then: the fixed-size-stack-per-continuation choice dominates the memory cost of
stack switching, the cost is unmeasured, and it can be attacked in the engine. We do the work in
**Wizard** (the research vehicle: stack switching in every tier, small Virgil codebase, and the
compression scaffolding is already upstream — §4.9) and compare against **Wasmtime** (the
production reference, whose implementation is the best-documented in the literature).

The two engines currently fail in opposite directions, and that is useful: **Wizard pools and
recycles stacks but never sizes them; Wasmtime neither pools nor frees.**

---

## 2. What "stack compression" means here

The literature has no term of art for this ([`05-stack-memory.md`](../lit-review/05-stack-memory.md)).
We use "stack compression" for any technique that reduces the memory attributable to a
*suspended* continuation below its fixed reservation. It is a ladder, ordered by how much
mechanism each rung needs and by what it buys:

| Rung | Technique | What shrinks | Needs relocation? | Where it exists |
|---|---|---|---|---|
| 0 | **Pool and recycle** stacks | allocation cost, not size | no | Wizard (done); Wasmtime async fibers only |
| 1 | **Right-size at `cont.new`** — size classes, producer hints, or profile | virtual reservation | no | nowhere for Wasm; the cheapest unclaimed win |
| 2 | **Decommit** untouched pages on recycle/suspend (`madvise`) | resident memory | no | Wasmtime's *fiber* pool has it; neither engine's continuations do |
| 3 | **Reserve large, commit lazily, grow in place** (libmprompt gstacks) | resident memory, and removes the guess | no | libmprompt; named by the WasmFX paper as its own next step |
| 4 | **Freeze/thaw** — on suspend, serialize the live frames into a right-sized heap object and release the stack; on resume, re-materialize onto a pooled stack | *everything*: bytes ∝ live frames | yes, but by re-materialization rather than raw copy | JVM Loom (frames copied verbatim); Wizard has the scaffolding (§4.9) |
| — | **Policy**: eager (every suspend) vs lazy (on age, pool pressure, or GC) | decides who pays | — | Loom thaws lazily; Go shrinks at GC |

Rungs 1–3 keep the stack where it is; rung 4 is the one that reaches Loom's "a few hundred
bytes per virtual thread". Rung 4 is also the one whose *time* cost is real — O(live frames)
on each compress and decompress — so the project is about the trade between rung 4's memory
and its time, and about a policy that makes switch-heavy workloads pay nothing.

The scope is the **engine stack**. The linear-memory shadow stack that C/C++/Rust toolchains
use for address-taken locals is a real and larger problem (it is most of WasmFX's 4 KiB), but
it lives in the toolchain, is addressable from Wasm, and cannot be moved by the engine
([`05-stack-memory.md`](../lit-review/05-stack-memory.md) §1, §4). We note where results bear
on it and otherwise leave it out. This is also why the OCaml suites matter to us: `wasm_of_ocaml`
targets WasmGC, so OCaml programs keep essentially no linear-memory shadow stack and the engine
stack is the whole story.

---

## 3. Research questions, hypotheses, deliverables

### Questions

- **RQ1 — Measure.** What does a suspended continuation cost today, in Wizard and Wasmtime, as a
  function of (a) the number of live suspended continuations, (b) the depth of the captured
  stack, and (c) how long it stays suspended? Which wall is hit first — resident memory, virtual
  address space, or the kernel's VMA limit?
- **RQ2 — Compress.** For frame re-materialization in Wizard (rung 4): what is the frozen size
  of a typical continuation, and what is the compress/decompress cost per frame and per value?
  Where is the break-even yield frequency at which freezing costs more time than the memory it
  saves is worth?
- **RQ3 — Policy.** Can a lazy policy (freeze only continuations that stay suspended past a
  threshold, or only under pool pressure) deliver the rung-4 memory result on the many-live-
  continuations workloads (`c10m`, `skynet`, parked generators) while leaving the switch-heavy
  ones (`sieve`, `suspend_resume`, `state`) at rung-0 speed?
- **RQ4 — Generality.** Does re-materialization survive Wizard's realities — mixed interpreter
  and SPC frames in one continuation, the tagged value stack, GC roots, traps and exceptions
  unwinding through a thawed stack — and does it give `cont.clone`/multi-shot for free, as a
  copy-based design should?

### Hypotheses

- **H1.** On Wizard today an idle suspended continuation costs 512 KiB of virtual space, three
  VMAs, and one to two resident 4 KiB pages; the VMA limit (`vm.max_map_count` = 65530 on this
  machine, ≈ 21 800 stacks) is reached long before RAM. On Wasmtime it costs 2 MiB + 4 KiB of
  virtual space and is never reclaimed.
- **H2.** The frozen representation of a shallow coroutine is in the low hundreds of bytes
  (Loom's figure), i.e. one to two orders of magnitude below a resident page and three below
  the reservation.
- **H3.** Compressing is cheaper than allocating: serializing a few frames costs less than the
  `mmap`+`mprotect` pair that `cont.new` costs today without a pool (68× on `c10m`), so a
  design that returns stacks to a hot pool and re-materializes on resume is time-neutral for
  shallow continuations and only loses on deep, frequently-switching ones.
- **H4.** A lazy policy recovers nearly all of the memory of the eager one on workloads with
  many parked continuations, because parked continuations are by definition the ones not
  switching.

### Deliverables

1. **A memory benchmark that does not exist yet** — sweep live suspended continuations from
   10³ upward and captured depth, report bytes per suspended continuation, peak and steady-state
   RSS, VMA count, and time per `cont.new`/`suspend`/`resume`. Runs on Wizard (all modes),
   Wasmtime, and an Asyncify baseline. Slots into `benchfx`'s shape.
2. **Rung 4 in Wizard**: the x86-64 `readFramesFromStack` / `writeFramesToStack` that upstream
   left as stubs (§4.9), a compressed-continuation identity that survives releasing the stack,
   and at least one policy. Rungs 1–2 as cheap ablations along the way.
3. **An evaluation** across `fiber-c`/`benchfx` (`c10m`, `sieve`, `skynet`, `state`,
   `suspend_resume`, `scheduler`), the OCaml effects suites through `wasm_of_ocaml`, and the
   new sweep, against Wizard-as-is, Wasmtime-as-is, the `v3-int` tier (a heap-sized baseline),
   Asyncify, and a hand-written state machine.
4. **The write-up**: bytes-per-continuation tables, the time/memory trade curve, the policy
   result, and what the engine-stack result implies for the shadow stack.

### Non-goals

Shadow-stack splitting in the toolchain; changes to Wasmtime beyond what a fair comparison needs;
browsers/JSPI; handler-search caching and tail-resumptive handler elision (time-side problems,
real but separate — [`06-openings.md`](../lit-review/06-openings.md) §4 items 7–8).

---

## 4. Wizard today — the research vehicle

Virgil source under `dependencies/wizard-engine/`. Stack switching runs in every x86-64 mode (`int`, `jit`,
`spc`, `lazy`, `dyn`) on the same stack type and the same allocator; the `v3-int` tier is a
separate, heap-based build. `--ext:stack-switching` implies `gc` and `exception-handling`
(`src/engine/Extension.v3:39-42`). `benchmark/fiber-c/config.yml:15` drives it as
`--ext:stack-switching --ext:gc --stack-size=65536 --mode=jit`.

### 4.1 The stack object

`class X86_64Stack` (`src/engine/x86-64/X86_64Stack.v3:9-42`) holds a native `mapping`, the two
stack pointers `vsp` and `rsp`, the entry `func`, `parent_rsp_ptr`, `params_arity`,
`return_results`, `state_`, and `next_stack` (the free-list link), plus the tier-independent
`parent`, `cont_bottom` and `version: u64` from `WasmStack` (`src/engine/WasmStack.v3:207-218`).
A `size` field is kept but never read after construction.

The constructor:

```virgil
mapping = Target.mmap_reserve(size, Mmap.PROT_READ | Mmap.PROT_WRITE);
var redzone_start = (size >> 1) & ~(PAGE_SIZE - 1u);      // one page, mid-mapping
Target.redzones_add(mapping, redzone_start, PAGE_SIZE);   // mprotect PROT_NONE
clear();
if (valuerep.tagged) RiGc.registerScanner(this, X86_64Stack.scan);
```

One private anonymous `mmap` per stack (`src/engine/x86-64/Mmap.v3:11-25`, so pages are
committed lazily by the kernel) and one `mprotect` of a single 4 KiB guard page
(`src/engine/x86-64/Redzones.v3:69-79`). **The guard page is in the middle because one mapping
holds two stacks growing toward each other**: the tagged *value stack* grows up from the start
(`vsp`), the *native frame stack* grows down from the end (`rsp`) — `clear()` sets
`vsp = range.start; rsp = range.end` (`X86_64Stack.v3:336-345`; diagram at `:975-1004`). One
guard catches both overflows. Consequences:

- Usable space is `size − 4 KiB`, split roughly 50/50 and **fixed at construction**. At the
  512 KiB default: 256 KiB of values (8 192 slots) and 252 KiB of frames. At `fiber-c`'s
  64 KiB: 32 KiB / 1 024 slots and ~28 KiB / ~250 frames.
- Every stack costs **three VMAs** (values, guard, frames). With `vm.max_map_count = 65530`
  that caps live stacks at roughly **21 800** regardless of RAM.
- A value slot is **32 bytes** (`Tagging(tagged=true, simd=true)`: 16-byte payload + 16-byte tag,
  `src/engine/Tagging.v3:6-8`, `X86_64Target.v3:21`); a native frame is 104 bytes + 8 of return
  address in both the fast interpreter and SPC (`src/engine/x86-64/X86_64Frames.v3:7-41`).
- Overflow detection is guard-page only; neither compiler emits limit checks.

### 4.2 Sizing

Exactly one production allocation site: `X86_64Stack.new(EngineOptions.STACK_SIZE.get())` in
`allocStackBatch` (`X86_64Stack.v3:1013`). `DEFAULT_STACK_SIZE = 512u * 1024u`, exposed as
`--stack-size`, documented as the "*Initial* stack size" — nothing grows
(`src/engine/EngineOptions.v3:8-9`). The constructor accepts any size (the offsets computation in
`src/engine/x86-64/V3Offsets.v3:17` builds an 8 KiB one), with a practical floor around 12 KiB
because of the mid-mapping guard. **Size is never varied per continuation and never recorded
usefully per stack.**

### 4.3 Pooling — `X86_64StackManager` (`X86_64Stack.v3:1007-1043`)

```virgil
component X86_64StackManager {
    var cache: X86_64Stack;                                   // singly linked via next_stack
    def allocStackBatch() {
        for (i < StackTuning.stackCacheSize) {                // = 8, src/engine/Tuning.v3:75-77
            var curr = X86_64Stack.new(EngineOptions.STACK_SIZE.get());
            curr.next_stack = cache; cache = curr;
        }
    }
    def getFreshStack() -> X86_64Stack { if (cache == null) allocStackBatch(); /* pop */ return result.clear(); }
    def recycleStack(stack: X86_64Stack) { stack.next_stack = cache; cache = stack; }
}
```

- A batch is **eight separate `mmap`s**, not one region. `stackCacheSize` is a compile-time
  `def`, not an option.
- `recycleStack` is exported as `Target.recycleWasmStack` (`X86_64Target.v3:20`) but the real
  recycling is **in machine code**: the return-parent stub pushes a finished stack onto `cache`
  through the field's absolute address, on both normal return and throw paths
  (`X86_64Stack.v3:864-873`). Any multi-class pool has to patch that stub or route recycling
  through a runtime call.
- `clear()` resets fields only. **No zeroing, no `madvise`, no decommit** (`madvise` does not
  appear anywhere under `src/engine`). A recycled stack keeps its high-water-mark RSS forever.
- The cache is **unbounded and never drained**; as a component field it is a permanent GC root,
  so **pooled stacks are never unmapped**. There is no accounting of how many exist.
- On `mmap`/`mprotect` failure the target retries once after `forceGC()` and then `fatal`s
  (`X86_64Target.v3:147-161`).

This is rung 0 done well (it is the optimization worth 68× on `c10m`) and nothing above it.

### 4.4 Continuation values

Two representations, chosen at build time (`build.sh:70-97`; `--boxed-continuation` flips
`FeatureDisable.unboxedConts`). Default is **unboxed**:
`type Continuation(stack: WasmStack, version: u64) #unboxed`
(`src/engine/continuation/UnboxedContinuation.v3`), with `isUsed = stack.version != version` and
`setUsed = stack.version++`. On the value stack it occupies one 32-byte slot (tag `CONTREF`,
stack pointer at +0, version at +8, `X86_64Stack.v3:593-600`); in registers, an XMM. The boxed
alternative is a heap object whose `stack` is nulled on use. Both files expose
`getStoredObject` / `fromStoredObject` under the comment "Stack compression."
(`UnboxedContinuation.v3:39-41`, `BoxedContinuation.v3:42-44`) — the hook through which a
continuation can name something other than a live stack.

The unboxed representation *is* `(stack pointer, version)`, so a compressed continuation must
keep the `X86_64Stack` object (or go through `getStoredObject`) as its identity after the
512 KiB mapping is released.

### 4.5 Lifecycle, instruction by instruction

| Instruction | Path | What happens to the stack |
|---|---|---|
| `cont.new` | **runtime call** in every tier (`X86_64MacroAssembler.v3:921`, `X86_64Interpreter.v3:2474-2483`) → `Runtime.CONT_NEW` (`src/engine/Runtime.v3:360-371`) | `Target.newWasmStack().reset(func)` — **a full stack leaves the pool immediately**, before the continuation has run an instruction |
| `resume` | **inline machine code**, no runtime call: validate-and-consume (null check, version compare, increment — `MacroAssembler.v3:376-401`), copy args to the child's value stack, chain child to parent (parent `CALL_CHILD`, child `RUNNING`, `*(child.cont_bottom.parent_rsp_ptr) = parent.rsp` — `MacroAssembler.v3:407-424`), then `mov rsp,[stack.rsp]; pop; jmp` (`:425-431`). Fast-int `X86_64Interpreter.v3:2495-2535`, SPC `SinglePassCompiler.v3:1452-1514` | — |
| return | return-parent stub (`X86_64Stack.v3:810-881`): copy results to parent's `vsp`, null `parent`/`parent_rsp_ptr`, **push stack onto `cache`**, `curStack = parent`, `pop rsp; ret` | recycled |
| `suspend` | **runtime call** `runtime_handle_suspend` (`src/engine/x86-64/X86_64Runtime.v3:138-170`): `unwindStackChain` searches parents for a handler (`Runtime.v3:393-405`), marks the suspender `SUSPENDED`, detaches it, pushes payload + a fresh `(stack, version)` onto the handler's stack; a stub then switches `rsp` (`X86_64Interpreter.v3:2652-2661`, `SinglePassCompiler.v3:1541-1552`) | **held, fully allocated**, for as long as it is suspended |
| `switch` | **runtime call** `runtime_handle_switch` (`X86_64Runtime.v3:174-215`): consume target, mark self `SUSPENDED`, splice target's `cont_bottom` under the current parent | held |
| `resume_throw` | **runtime call** `runtime_resume_throw_ref` (`X86_64Runtime.v3:117-133`): unwind the continuation's own frames; if handled, the handler stack becomes `RESUMABLE` and the ordinary resume follows; if unhandled, rethrow on the current stack | if unhandled, **left for GC**, not recycled |
| abandoned (unreachable while suspended) | **no hook**. The stack's GC scanner is weak and `Mapping` registers `range.unmap` as a finalizer (`Mmap.v3:23`) | `munmap`ed at the **next Virgil GC** — but a 512 KiB mapping exerts no Virgil-heap pressure, so a program that abandons continuations grows VA and VMA count until some heap allocation happens to trigger a collection, or `mmap` fails and forces one |

Two things stand out for this project. First, **the memory hold starts at `cont.new`, not at
first resume**, and lasts across every suspension. Second, on the *time* side, Wizard's
`suspend`/`switch`/`cont.new` go through a Virgil runtime call followed by a stub — exactly the
nested-host-call shape that Emrich & Hillerström found costs four return-address mispredictions
per switch in Wasmtime's prototype (§8). That is not our problem to fix, but it is a measurement
confound: Wizard's switch times will not be Wasmtime's, and any compression work must be
charged against Wizard's own baseline.

### 4.6 States and tiers

`StackState = EMPTY | SUSPENDED | CALL_CHILD | RESUMABLE | RUNNING | RETURNING | THROWING`
(`WasmStack.v3:245-253`). `reset(func)` → `SUSPENDED` if the function takes parameters, else
`RESUMABLE`; `bind` → `RESUMABLE` at arity 0; resume → parent `CALL_CHILD`, child `RUNNING`;
suspend/switch → self `SUSPENDED`; handled `resume_throw` → `RESUMABLE`. The return-parent stub
does not write state, so a pooled stack sits in `cache` still marked `RUNNING` until
`getFreshStack().clear()`. `RETURNING`/`THROWING` are used only by `V3Interpreter`. Traps
unwind across the whole chain (`X86_64Stack.v3:160-170`).

All x86-64 modes share `X86_64Stack` and `X86_64StackManager` (`X86_64Target.v3:19-20`). The
fast interpreter and SPC use identical 104-byte frames and `walk` recognizes both
(`X86_64Stack.v3:146-149`), so **one continuation can hold mixed interpreter and SPC frames and
OSR tier-up works across a suspend** — any re-materialization design must handle both frame
kinds. The `v3-int` tier (`src/engine/v3/V3Target.v3`) is a separate build in which the stack is
a heap `ArrayStack<Value>` with linked `V3Frame`s, a one-element `cached_stack`, and a
trampoline loop; it has no fixed size at all and is the natural "unbounded, heap-sized" baseline.

### 4.7 GC and what pins a stack in place

`X86_64Stack.scan` (`X86_64Stack.v3:496-517`) walks `[range.start, vsp)` in 32-byte slots,
reads each tag byte and reports references, then walks the frames and re-scans each frame's
`wasm_func`/`func_decl`/`instance`/`accessor` slots (`X86_64Interpreter.v3:89-123`,
`X86_64SinglePassCompiler.v3:1220-1228`). **Everything is addressed absolutely**: frames store
absolute `vfp`/`vsp` pointers into the same mapping (`X86_64Frames.v3:10-11`),
`parent_rsp_ptr` points into the child's mapping, the return-parent slot holds the parent's
absolute `rsp`, and heap `X86_64FrameAccessor` objects cache an absolute `sfp`. Virgil's
collector is a copying semispace GC, so the small `X86_64Stack` *objects* move but the mappings
never do.

A raw `memcpy` relocation or shrink would therefore need pointer fixups in every frame. Upstream
chose the other route — re-materialize frames logically rather than copy bytes — which is §4.9.

### 4.8 Overflow

SIGSEGV on the guard page → Virgil's handler on its `sigaltstack` → `handleSignal`
(`X86_64Interpreter.v3:126-151`, `X86_64SinglePassCompiler.v3:1248-1277`) →
`RedZones.isInRedZone` → `curStack.handleOverflow` (`X86_64Stack.v3:323-334`) → the
`STACK_OVERFLOW_STUB` (`:950-973`) raises `TrapReason.STACK_OVERFLOW` and returns into the
return-parent stub. No growth, no relocation: exhausting a continuation's half-stack is a trap.

### 4.9 The compression scaffolding already upstream

Upstreamed from this project (PRs #547 unboxed continuations, #598 larger stack cache, #623
stack hierarchy helpers, #625 platform-independent compression; 2026-01 to 2026-05):

- `src/engine/compression/Compression.v3`:
  `WasmFrameData(func, pc, ret_addr, vals)`, `RelocatableFrame(data, is_spc, bytecode_ip)`,
  `CompressionStrategy<C>` with `compress(Range<RelocatableFrame>) -> C` /
  `decompress(C) -> Array<RelocatableFrame>`, `CompressedStack` (`size()`, `name()`, `trace`),
  and `component StackCompression` whose `compressStack(stack)` is
  `packed.compress(Target.readFramesFromStack(stack))` and whose `decompressStack(to, from)` is
  `Target.writeFramesToStack(to, decompressFrames(from))`.
- `NaiveCompressionStrategy.v3` and `PackedCompressionStrategy.v3` — the packed form writes one
  tag byte plus a LEB-encoded payload per value and side-tables references (and continuations,
  as `(stored object, version)`), so a frame costs a header plus a few bytes per live value.
- `test/unittest/CompressionTest.v3` (532 lines) round-trips both strategies over synthetic
  frames only.
- **The target halves are stubs**: `Target.readFramesFromStack` / `writeFramesToStack` are
  empty, marked `TODO[sc]: … real impl lands with the x86-64 backend`
  (`X86_64Target.v3:163-167`; `V3Target.v3:46-50`). `X86_64Frames.v3:281` carries an
  `XXX: refactor — used by stack compression` on the frame-value accessor that the reader will
  need.

So the shape of rung 4 in Wizard is decided — **freeze = read frames → pack → release stack;
thaw = take pooled stack → write frames → resume** — and what remains is the x86-64 reader and
writer (interpreter *and* SPC frames), the continuation identity across freeze, the policy, and
the measurement. A related hint in `SinglePassCompiler.v3:1475` ("not necessary to store the
entire value stack to memory" on resume) says SPC currently spills the whole value stack at
switch points, which is convenient for a reader that expects state in memory.

### 4.10 Knobs

`--stack-size` (`EngineOptions.v3:9`); `StackTuning.stackCacheSize = 8` (compile-time,
`Tuning.v3:76`); `--boxed-continuation` (build); `--mode=`; `--trace-stack` and `Debug.stack`.
Not exposed: batch size, pool bound, guard size or placement, any decommit policy. No comment in
the stack code mentions grow, shrink, or bounding the pool.

### 4.11 Per-continuation cost today

| | Virtual | Resident (idle, shallow) | Objects | VMAs | Reclaimed when |
|---|---|---|---|---|---|
| Wizard, default | 512 KiB | 1–2 pages (4–8 KiB) touched at the two ends, plus whatever ran; **never decommitted** | one small Virgil `X86_64Stack` | 3 | returned → pool (never unmapped); abandoned → next GC |
| Wizard, `fiber-c` config | 64 KiB | same | same | 3 | same |

---

## 5. Wasmtime today — the comparison point

Rust source under `dependencies/wasmtime/`. Full walkthrough in
[`04-runtimes.md`](../lit-review/04-runtimes.md) Part II; what follows is what matters for
memory, re-verified at `d8a0da6d66`. The implementation was upstreamed from `wasmfx/wasmfxtime`
in two steps: the runtime in #10388 (2025-06) and the inline Cranelift lowering in #11003
(2025-09).

### 5.1 The allocation path

`cont.new` is the **only** stack-switching instruction that leaves compiled code
(`crates/cranelift/src/func_environ/stack_switching/instructions.rs:1245-1272` → builtin
`cont_new`, `crates/environ/src/builtin.rs:157` → `vm::stack_switching::cont_new`,
`crates/wasmtime/src/runtime/vm/stack_switching.rs:313-362`) and it lands here:

```rust
/// Allocates a new continuation. Note that we currently don't support
/// deallocating them. Instead, all continuations remain allocated
/// throughout the store's lifetime.
pub fn allocate_continuation(&mut self) -> Result<*mut VMContRef> {
    // FIXME(frank-emrich) Do we need to pin this?
    let mut continuation = Box::new(VMContRef::empty());
    let stack_size = self.engine.config().async_stack_size;
    let stack = crate::vm::VMContinuationStack::new(stack_size)?;
    continuation.stack = stack;
    let ptr = continuation.deref_mut() as *mut VMContRef;
    self.continuations.push(continuation);
    Ok(ptr)
}
```
(`crates/wasmtime/src/runtime/store.rs:2133-2146`; the field is
`continuations: Vec<Box<VMContRef>>` — "*Contains all continuations ever allocated throughout
the lifetime of this store*", `store.rs:466-469`.)

`VMContinuationStack::new` (`crates/wasmtime/src/runtime/vm/stack_switching/stack/unix.rs:89-121`)
rounds the size up to a page, `mmap`s `size + page` anonymous `MAP_PRIVATE` with no
permissions, then `mprotect`s everything above the lowest page `READ|WRITE`. So:

- **Size**: `Config::async_stack_size`, default `2 << 20` = **2 MiB** (`config.rs:188, 301`), plus
  a 4 KiB guard page. There is no continuation-specific knob; the async-fiber knob does double
  duty. (`-W async-stack-size=N`; passing only `-W max-wasm-stack=N` derives `N + 512 KiB`.)
- **Commit**: `MAP_PRIVATE` without `MAP_NORESERVE` (the linear-memory `Mmap` type uses it; this
  code calls `rustix` directly). Pages are demand-faulted, so resident cost is only what is
  touched, but each stack counts 2 MiB toward the kernel's commit charge.
- **Two allocations per continuation**: a heap `Box<VMContRef>` (152 bytes) and the mapping.
- **Payload buffers live inside the stack**: `VMContRef.args.data` and `values.data` point into
  the continuation's own mapping (`stack_switching.rs:229-242`).

### 5.2 Pooling, freeing, reclamation: none

- The only writer of `continuations` is the `push` above; the only other reader is the GC root
  tracer. Nothing removes an element. **No reuse, no free list, no bound.**
- `Drop for StoreOpaque` (`store.rs:2425-2460`) does not mention continuations; the `Vec` drops
  with the store and only then does `VMContinuationStack::drop` (`unix.rs:308-320`) `munmap`.
  A `Returned` or `Trapped` continuation keeps its 2 MiB until the store dies; the return path
  clears only the `args` header (`instructions.rs:1858-1860`).
- Continuation references are **not GC-managed**: `HeapTopType::Cont => bail_bug!(...)`
  (`vm/gc/gc_ref.rs:466`), `Val::ContRef` rejected by the embedder API, contrefs in struct
  fields `TODO(#10248)`. There is no collector that could reclaim a dropped `cont`.
- The `Trap::StackOverflow`-style pooling limits (`total_stacks`) bound **async fibers only**.
  `benchmark/fiber-c/config.yml:6` passes `total-stacks=<STACK_POOL_SIZE>` (10 000 for `c10m`, 2 000 for
  `sieve`, 6 for `skynet`) — that configuration was written for the `wasmfxtime` fork, whose
  continuation pool was never upstreamed. On upstream at this commit it does not affect
  continuations.

**The pool that is not wired up.** `crates/wasmtime/src/runtime/vm/instance/allocator/pooling/unix_stack_pool.rs`
carves one reserved region into `total_stacks` slots with a `PROT_NONE` guard at the bottom of
each (`:35-88`), indexes them with a `SimpleIndexAllocator`, and on release runs `zero_stack`
(`:146-209`): memset the top `async_stack_keep_resident` bytes, queue the rest for decommit.
The divergence is exactly `store.rs:2141` — `VMContinuationStack::new(stack_size)` where
`self.engine.allocator().allocate_fiber_stack()` would use the pool. Vestiges of the fork's pool
remain (`VMContinuationStack::from_raw_parts`, `VMContRef::detach_stack`, and
`VMContRef::empty()`'s doc "*Used to create VMContRefs when initializing pooling allocator*")
with **zero callers**. Tracking issue #10248 lists "unify stack switching with fiber stacks and
the pooling allocator" as open.

### 5.3 Continuation object and one-shot check

`VMContRef` (`stack_switching.rs:204-248`; offsets in `crates/environ/src/vmoffsets.rs:545-689`):
`common_stack_information` (64 B: `VMStackLimits`, `state`, `handlers` array,
`first_switch_handler_index`) · `parent_chain: VMStackChain` (16 B; `Absent` /
`InitialStack` / `Continuation`) · `last_ancestor` · `revision: usize` · `stack` (24 B:
`top, len, allocator`) · `args` · `values` — **152 bytes**, heap-boxed, separate from the
mapping. The Wasm-level `(ref $ct)` is the fat pointer `VMContObj { contref, revision }`, an
`i128` in Cranelift; every consumer loads `revision`, traps on mismatch with
`TRAP_CONTINUATION_ALREADY_CONSUMED`, and stores `revision + 1`. States: `Fresh, Running,
Parent, Suspended, Returned, Trapped`.

### 5.4 Switching

Everything except `cont.new` is inline Cranelift IR ending in the `stack_switch` CLIF
instruction (`cranelift/codegen/meta/src/shared/instructions.rs:981`). The control context is 24
bytes at the top of each stack — `{rsp @0, rbp @8, rip @16}`
(`cranelift/codegen/src/isa/x64/inst/stack_switch.rs:31-37`) — placed so the saved RBP sits next
to the saved RIP and a naïve frame-pointer walk crosses from a continuation into its parent for
free. The x64 emission (`cranelift/codegen/src/isa/x64/inst/emit.rs:550-645`) is, for each of
`rsp` and `rbp`, `mov tmp,[load+off]; mov [store+off],reg; mov reg,tmp`, then
`mov tmp1,[load+16]; lea tmp2,[rip+resume]; mov [store+16],tmp2; jmp tmp1` — **eight `mov`s,
one `lea`, one indirect `jmp`** (the "six `mov`s" in [`04-runtimes.md`](../lit-review/04-runtimes.md)
counts only the SP/FP exchange). The instruction is declared to clobber every register, so
regalloc2 spills only what is live across it; the payload rides in `rdi`.

Around it: `resume` (`instructions.rs:1300-1866`) checks the revision, stores arguments into the
callee's buffers, splices chains, swaps the four stack-limit words between `VMStoreContext` and
the parent's `VMStackLimits`, writes the handler tag list into a **stack slot of the resumer's
frame**, then switches on the *last ancestor's* control context and dispatches the returned
`ControlEffect` (Return = 0 is the fast path) via `brif` + `br_table`. `suspend`
(`:1900-1972`) runs `search_handler` (`:768-923`) — a doubly-nested CLIF loop, outer over the
parent chain, inner over each stack's handler list, comparing `*mut VMTagDefinition` — then
breaks the chain and switches. `switch` (`:1974-2225`) copies the target's 24-byte context
through a temporary slot first. Fresh stacks enter through the naked trampoline
`wasmtime_continuation_start` (`stack/unix/x86_64.rs:39-92`).

### 5.5 Limits, overflow, GC, gating

- Wasm stack overflow is a **prologue check** against `VMStoreContext.stack_limit`, not the guard
  page. `cont_new` sets
  `stack_limit = max(sp − max_wasm_stack, top − stack_size)` (`stack_switching.rs:346-355`),
  so with defaults Wasm code gets 512 KiB of the 2 MiB and host calls made from inside a
  continuation get the rest. If host code actually reaches the guard page, the signal handler
  does not recognize continuation guard ranges (only `async_guard_range`, set by the fiber
  machinery) and **the process dies** (`sys/unix/signals.rs:158-186`).
- GC (`store/gc.rs:797-834`) iterates the **entire `continuations` vector every collection** and
  frame-pointer-walks each `Suspended` one from its saved `rip`/`rbp`
  (`traphandlers/backtrace.rs:139-190`) with ordinary stack maps — an O(all continuations ever
  allocated) cost per GC that the never-freed vector makes unbounded. Nothing depends on a fixed
  *size*; everything depends on a fixed *address* while suspended. `cont.bind` arguments are not
  traced (a `FIXME`), so GC values are disallowed there.
- The `stack-switching` Cargo feature is on by default, the Wasm feature is **off by default**
  (`Config::wasm_stack_switching` / `-W stack-switching=y`), requires `function-references` and
  `exceptions`, Cranelift only, and effectively **x86-64 Linux only** (macOS passes config
  validation but `control_context_size` accepts only `(X86_64, Linux)`,
  `instructions.rs:13-20`). Enabling it **disables compiler inlining**
  (`config.rs:2705-2716`). Pulley and Winch have no support, so there is no interpreter
  implementation.

### 5.6 What constrains change, and what does not

- **Absolute pointers into the stack are everywhere**: the payload buffers, the control
  context's saved `rsp`/`rbp`, every frame's `rbp` chain, `VMStackLimits`, and the parent's
  handler list and payload slots whose addresses are visible to the child. Relocating a
  suspended stack means relocating all of them, and any segmentation breaks the frame-pointer
  walking that both the backtracer and the trampoline design rely on.
- **Per-continuation sizing is otherwise one line**: `allocate_continuation` is the single call
  site, `VMContinuationStack::new` takes any page multiple, `stack_limit` is derived from it, and
  the `cont_new` libcall already sees the funcref and arities — the natural hook for a size
  choice.
- Lazy commit is already what the kernel provides; the missing pieces are `MAP_NORESERVE`, any
  reuse or decommit, and freeing on `Returned`/`Trapped`.

### 5.7 Per-continuation cost today

| | Virtual | Resident (idle, shallow) | Objects | Reclaimed when |
|---|---|---|---|---|
| Wasmtime, default | **2 MiB + 4 KiB** | pages touched: the top page (control context + args) plus whatever ran; never decommitted | `Box<VMContRef>` 152 B | **store drop only** |

---

## 6. Side by side

| | **Wizard** `4a539337` | **Wasmtime** `d8a0da6d66` |
|---|---|---|
| Stack size | 512 KiB default, `--stack-size`; `fiber-c` uses 64 KiB | 2 MiB, `async_stack_size` (an async-fiber knob) |
| Per-continuation sizing | no | no |
| Layout | one mapping, values up from bottom, frames down from top, **guard page mid-mapping**, 50/50 fixed | frames only (values in registers/frame), control context at top, guard page at bottom |
| Pooling | yes: unbounded free list, batches of 8 mmaps, recycled from machine code on return | **none**; a complete fiber-stack pool exists one module over, unused |
| Freeing | pooled stacks never unmapped; abandoned suspended stacks unmapped at next Virgil GC (heap-blind) | **never**, until the `Store` drops; not GC-managed |
| Decommit / zeroing | none | none for continuations (`keep_resident` policy exists for fibers) |
| Where the hold begins | `cont.new` | `cont.new` |
| Continuation value | unboxed `(stack ptr, version)` in a 32-byte tagged slot; `version` on the stack object | fat pointer `(VMContRef*, revision)` as `i128`; 152-byte heap object |
| One-shot check | version compare + increment, inline | revision compare + increment, inline |
| `resume` | inline (~10 instructions after checks) | inline; `stack_switch` = 8 `mov` + `lea` + `jmp` |
| `suspend` / `switch` | **runtime call** for handler search + relink, then a stub | inline CLIF, nested-loop `search_handler` |
| `cont.new` | runtime call | libcall (the only one) |
| Overflow | SIGSEGV on mid-mapping guard → trap; no limit checks | prologue limit check → trap; guard page hit by host code kills the process |
| GC roots on suspended stacks | tagged value-stack scan + frame walk; absolute pointers throughout | FP walk from saved `rip`/`rbp` with stack maps; absolute pointers throughout |
| Tiers | every tier; mixed int/SPC frames in one continuation; `v3-int` is a heap-based baseline | Cranelift only, x86-64 Linux; no interpreter |
| Compression scaffolding | `src/engine/compression/` + `getStoredObject` hooks; x86-64 reader/writer stubbed | none |
| First wall on a live-continuation sweep (estimate) | `vm.max_map_count` at ~21.8k stacks (3 VMAs each) | address space / commit charge at 2 MiB each, and ~32k stacks by VMA count (2 each); the GC scan of `continuations` grows without bound |

---

## 7. What the literature says about stack memory

Condensed from [`05-stack-memory.md`](../lit-review/05-stack-memory.md) and
[`01-background.md`](../lit-review/01-background.md); the full argument and the numbers'
provenance are there.

**One invariant governs the whole design space.** *You may relocate a stack if and only if
nothing outside it holds a pointer into it — or you can find and rewrite every such pointer.*
OCaml can copy-and-double fibers because the compiler never generates interior pointers (only
two words to patch). Go copies *and shrinks* goroutine stacks because the runtime knows every
frame layout and rewrites the pointers. Loom freezes frames into heap `StackChunk`s because JVM
frames are GC-described. C, C++, and Wasm's linear-memory shadow stack cannot move. A Wasm
*engine* stack is not addressable from Wasm and is movable in principle — but both engines above
address it absolutely from their own runtime structures, so today it is not movable in practice.
Every workaround in the literature is the same shape: a **stable indirection** — Effekt's
prompts, Loom's chunk handles, Ma/Jung/Zhang's software MMU, Wasm's fat-pointer revision counter.
Wizard's `getStoredObject` and its `(stack, version)` continuation are already that indirection.

**The five strategies, with the numbers that matter:**

| Strategy | Example | Cost evidence |
|---|---|---|
| Fixed-size contiguous | WasmFX prototype 4 KiB; Wizard 512 KiB; Wasmtime 2 MiB | 55.5 MB vs 13.4 MB at 10k coroutines (Phipps-Costin et al. 2023) |
| Resizable contiguous (copy-and-double) | OCaml 5 (16 words initial), Go (2 KB), Effekt | OCaml: +19–30 % text size for the overflow checks; Farvardin & Reppy: *"resize is the better choice because of its space efficiency"* |
| Segmented | libseff, Go/Rust formerly | hot split 11× at zero work, gone by ~13 FLOPs; **recycling segments vs freeing: 3–34×** |
| Reserve-and-commit-on-demand | libmprompt gstacks: reserve 8 MiB, commit 4 KiB | 2025 Edinburgh study: kernel overcommit is the best general balance; batch commit over-allocates |
| Heap frames (CPS) | Manticore `cps` | fastest on continuation benchmarks, slower sequentially, invisible to debuggers |

**Copy-out-on-suspend is the closest thing to actual compression**: Loom's `freeze`/`thaw`
(frames copied verbatim into a heap chunk on yield, copied back lazily on mount, chunk reused in
place when it fits) takes a virtual thread to "a few hundred bytes"; Go's `shrinkstack` halves a
stack at GC when live use is under a quarter. Both depend on exact frame metadata — which a Wasm
engine has, because it already emits GC stack maps and (in Wizard) can walk and describe every
frame.

**Allocation dominates.** OCaml: creating a fiber costs 23 ns against 5/11/7 ns for
perform/resume/return. Wasmtime: no pool → pool is 187.73× → 2.76× on `c10m`. libseff: recycling
is 3–34×. *If you are making stack switching fast, you are mostly making stack allocation fast* —
so a compression design that puts an allocation back on the resume path has lost before it
starts.

**The measurement gap** ([`02-benchmarking.md`](../lit-review/02-benchmarking.md) §4–5): almost
every results table is wall-clock only; `hyperfine` does not measure memory; continuation size is
never a swept parameter; the checklist we adopt is to sweep handler depth, captured-continuation
size and **number of live suspended continuations**, report peak and steady-state RSS and bytes
per suspended continuation, separate the four resumption categories, include a no-continuations
control, and distinguish create / first resume / suspend / resume / dispose / grow costs.

**Microbenchmarks mislead about control-flow features** — Asyncify beats WasmFX 3–4× on
microbenchmarks and loses ~90× on tail latency at saturation in a real HTTP server
([`03-wasm-stack-switching.md`](../lit-review/03-wasm-stack-switching.md) §4). Memory is the
same kind of property: invisible in a switch-latency microbenchmark, decisive at 10 000 live
connections.

---

## 8. Lessons from the WasmFX Wasmtime work

Sources: Emrich & Hillerström, *Continuing Stack Switching in Wasmtime*, WAW 2025 — the 2-page
talk proposal (`dhil.net/research/papers/wasmfxtime-waw2025.pdf`) and the 16-slide deck
(`effect-handlers.org/talks/wasmfx-waw2025.pdf`; its "Bonus slides" section is empty in the
public PDF) — read alongside Phipps-Costin et al., OOPSLA 2023, and Hillerström's *Benchmarking
WasmFX* (May 2024), both summarized in [`03-wasm-stack-switching.md`](../lit-review/03-wasm-stack-switching.md).

### What they did

1. **Prototype by libcall.** Every stack-switching instruction became a libcall into Rust that
   drove the existing `wasmtime-fiber` API (hand-written `wasmtime_fiber_switch` assembly that
   pushes all callee-saves). No Cranelift changes. This was enough to build `fiber-c`, `benchfx`,
   and the Waeio HTTP server and to evaluate the *proposal* before committing to codegen.
2. **Sketch the native design.** One new CLIF instruction,
   `stack_switch(source_control_ctx, dest_control_ctx, payload)`, acting on pointers to
   *control contexts* `(SP, FP, IP, …)` whose layout is platform-dependent — "a minimal addition
   to Cranelift: only does what cannot be expressed already", after Dolan, Muralidharan & Gregg's
   **SWAPSTACK** (TACO 2013).
3. **No big bang.** They forked `wasmtime-fiber`, adapted it step by step, introduced a *third,
   intermediate* stack layout, and stripped each libcall down until only `cont.new` needed the
   runtime — the fiber layout (saved SP at top, frames, caller-saves, IP/FP/callee-saves) turned
   out to be a natural fit for the `stack_switch` layout (control context at top, frames, saved
   registers managed by the register allocator).
4. **"Symmetric asymmetry."** The primitive is *symmetric* (no caller/callee relation); the
   proposal is *asymmetric* (`resume` establishes parent/child). All of the administrative logic
   — chain maintenance, handler installation, states — moved out of the runtime into generated
   code around the symmetric primitive.

### What they measured

The single commit enabling native switching (x64 Linux, AMD Ryzen 3900X): `c10m` **1.49×**,
`sieve` **2.61×**, `skynet` **1.72×**, `state` **4.48×**, `suspend_resume` **5.97×**. The
explanation is micro-architectural: the libcall path made every switch a nest of four frames
(`libcalls::raw::resume` → `catch_unwind_and_longjmp0` → `libcalls::resume` →
`wasmtime_fiber_switch`), and after the switch the `ret`s unwinding those frames on the *other*
stack no longer match the `call`s the CPU's return-address predictor recorded — **four
guaranteed mispredictions per stack-switching operation.** From the earlier Stacks-subgroup
talk: **stack pooling is worth 187.73 → 2.76 on `c10m`**, framed as "safe stacks" (`mmap`ed,
guard pages, pooled, with reserved-but-uncommitted pages above the guard as "a suggestive scheme
for stack growing").

### What it means for this project

- **Keep compression off the switch path, or make it inline.** A compress/decompress step
  implemented as a nested host call on every `suspend`/`resume` reintroduces exactly the RAS
  pathology that cost Wasmtime up to 6×. Two acceptable shapes: (i) *lazy* — freeze from a place
  that is already a runtime excursion or off the hot path (a GC pass, pool-pressure handling, a
  continuation that has sat suspended past a threshold), so the switch itself stays a
  pointer swap; (ii) *inline* — if freezing must happen at suspend, the frame reader should run
  as a flat loop, not a stack of calls, and thaw should be a bulk write followed by the ordinary
  resume stub. Wizard's `suspend` is already a runtime call (§4.5), which makes (i) cheap to
  bolt on and means the baseline already pays the penalty the design must not worsen.
- **Never put an allocation back on resume.** Their 68× pooling result and OCaml's 23 ns fiber
  creation say the same thing. Thaw must take a stack from a hot pool (Wizard has one) and the
  frozen buffer should be recycled, Loom-style, when the continuation is re-frozen into the same
  size.
- **The stack layout is part of the switch, not incidental to it.** Both engines put the
  control context at the top of the stack so that frame-pointer walking crosses stacks for free,
  and both use it for GC and backtraces. A re-materialized stack has to reproduce that layout
  exactly — which is one reason "write frames onto a fresh pooled stack and rebuild the
  return-parent slots" is a better plan than "copy bytes somewhere else".
- **Stage it.** Measure first (their libcall prototype existed to evaluate, not to ship), then
  the smallest change that moves the number (rungs 1–2 are one-line changes in both engines),
  then the real design, with the layout migrated incrementally rather than rewritten.
- **Their benchmark set spans the trade-off we care about**, which is why we keep it: `c10m`
  (10 M coroutines, 10 000 live, one yield each, shallow) is where compression pays; `sieve`
  (8 100 coroutines, many yields) and `suspend_resume` are where it costs; `skynet` (10 M
  coroutines, only 6 active, deep) tests depth; `state` tests handler dispatch. Hand-written
  state machine and Asyncify are the memory and time baselines respectively.
- **Their memory claim is our hypothesis.** *"The fixed-sized system stacks induce allocation
  burden that may be unnecessary: experiments in other languages have found that most
  continuations require little stack memory"* — stated, never measured, never acted on upstream.

---

## 9. Design space for Wizard

Ordered by effort; each is an ablation point for the evaluation, not an either/or.

1. **Decommit on recycle (rung 2).** `madvise(MADV_DONTNEED)` the touched range of a stack when it
   returns to the pool, optionally keeping the top page resident. `SYS_madvise` is in
   `rt/x86-64-linux/LinuxConst.v3:84`; there is no wrapper in `Mmap.v3`. Bounds resident memory
   of *pooled* stacks; does nothing for *suspended* ones. Also bound the pool.
2. **Size classes (rung 1).** Multiple `cache` heads by size; choose at `cont.new` from a hint,
   a per-function profile, or the callee's static frame size. Requires routing the machine-code
   recycle (`X86_64Stack.v3:864-873`) through a size-aware path. Cheap, and it measures how much
   of the gap is the *reservation* rather than the residency.
3. **Movable guard / reserve-large (rung 3).** Keep one mapping but reserve more than needed and
   place the guard adaptively, so the 50/50 split stops being a hard limit and overflow becomes
   a grow-in-place event handled in the existing SIGSEGV path. Independent of compression;
   worth doing because the fixed split is the other half of the sizing guess.
4. **Freeze/thaw (rung 4) — the main line.** Implement `X86_64Target.readFramesFromStack`
   (walk `[range.start, vsp)` and the frame chain; emit a `RelocatableFrame` per frame with its
   live values, PC/`bytecode_ip`, `is_spc`) and `writeFramesToStack` (take a pooled stack,
   rebuild value slots, frames, `parent_rsp_ptr`/return-parent slots and the resume entry so the
   ordinary `resume` stub works unchanged). Store the `PackedCompressedStack` on the
   `X86_64Stack` object (or behind `getStoredObject`) so the `(stack, version)` identity survives
   and the one-shot check keeps working; release the mapping to the pool. Thaw on `resume`, from
   the runtime call that `resume` does *not* currently make — so either `resume` grows a
   "frozen?" branch that calls out, or the frozen stack object carries a stub `rsp` that traps
   into the thaw path. Handle both frame kinds and the GC scan of a frozen continuation
   (references are already side-tabled by the packed strategy).
5. **Policy.** Eager (freeze at every suspend) as the memory-optimal reference; lazy variants —
   age-based (freeze continuations suspended for more than *k* switches or *t* ms), pressure-
   based (freeze when the pool would otherwise batch-allocate), GC-based (freeze during the
   collector's scan, when it is already walking the frames). H4 says the lazy ones get almost
   all the memory for almost none of the time.
6. **`cont.clone`.** Once a continuation can be a packed frame array, cloning is copying the
   array. Not a goal, but the first multi-shot Wasm implementation would fall out, and it is
   worth measuring because multi-shot is what every one-shot design excludes from comparison.

Things the design must not break: mixed interpreter/SPC frames in one continuation and OSR
across a suspend (§4.6); the tagged value-stack scan and `FrameAccessor` objects holding
absolute `sfp`s (§4.7); traps and `resume_throw` unwinding through a thawed stack; the
`many_stacks.wast` regression (999 live suspended continuations).

---

## 10. Evaluation plan

**Axes.** Live suspended continuations (10² … as far as each engine goes); captured depth
(frames per continuation, 1 … 10³); yield frequency (work per switch); suspension lifetime.

**Metrics.** Bytes per suspended continuation = ΔRSS / N at steady state, plus peak RSS, virtual
size, VMA count (`/proc/<pid>/maps`), and the wall at which each configuration fails (and how:
trap, `mmap` failure, OOM). Time per `cont.new`, first `resume`, `suspend`, `resume`, dispose,
freeze, thaw. Tail latency where a server-shaped workload exists. Report the four resumption
categories separately ([`01-background.md`](../lit-review/01-background.md) §1).

**Workloads.** (a) A new "park *N* continuations at depth *d*" microbenchmark, in C via
`fiber-c` so it runs on every engine, and in OCaml via `wasm_of_ocaml --effects=native`.
(b) `benchfx`: `c10m`, `sieve`, `skynet`, `state`, `suspend_resume`, `scheduler`, plus the
`*_switch` variants. (c) `benchmark/benches/multicore/multicore-effects/` — `effect_throughput_*`
(one-shot tail and zero-shot), `algorithmic_differentiation` (one-shot non-tail through deep
handlers), `eratosthenes` (dynamically-shaped handler stack) — and `benchmark/macro-benches/` for a
no-continuations control. The OCaml suites currently run only on the reference interpreter
([`../RUNNING.md`](../RUNNING.md)); getting `wasm_of_ocaml` output onto Wizard (GC + `try_table`
+ stack switching, and a host shim for its imports) is an early task, not an assumption.

**Systems.** Wizard `--mode=jit` and `--mode=spc` at each rung; Wizard `v3-int` as the
heap-sized bound; Wasmtime as-is (`-W stack-switching`, and `async-stack-size` swept as its
only knob); Asyncify (`wasm-opt --asyncify`) as the no-native-stack baseline; the hand-written
state machine where `benchfx` has one.

**Method** ([`02-benchmarking.md`](../lit-review/02-benchmarking.md) §3): engine versions pinned
to hashes; one correctness run first, failures reported as `≡` / `OOM` / `—` rather than
dropped; ≥ 20 runs or ≥ 6 s with one warm-up, arithmetic mean and relative standard deviation;
whole-process measurement with what is inside it stated; geomeans only over benchmarks both
systems ran; every optimization also reported *disabled* (ablation); negative results published.
The reference interpreter is used only as the semantics oracle for generated code — its clock is
virtual and its switch costs ~1 900× native.

---

## 11. Risks and open questions

- **The VMA ceiling may be the story.** If `vm.max_map_count` (three VMAs per Wizard stack) is
  the first wall, rung 4's memory result is secondary to "how many mappings"; one-region pools
  (Wasmtime's fiber pool shape, libmprompt's gpool) become part of the design.
- **Reclamation is GC-bound and heap-blind** in Wizard: abandoned continuations wait for a Virgil
  collection that their own mappings never trigger. A memory sweep must distinguish "held by
  design" from "held until GC", and a freeze policy that runs at GC inherits the same blindness.
- **Freezing SPC frames** may need more than the interpreter's frame description if SPC keeps
  state in registers across a suspend; the `SinglePassCompiler.v3:1475` note suggests it does
  not today, and that could change under optimization.
- **Time-side confounds.** Wizard's runtime-call `suspend` and Wasmtime's inline one differ by
  the RAS penalty before any compression is added; cross-engine *time* comparisons need that
  gap characterized first. `benchfx`'s Wasmtime configuration was written for the fork and its
  `total-stacks` does nothing for continuations upstream.
- **What the producer knows.** Compiled generators and async functions often have statically
  boundable stack depth; there is no size hint in the proposal. If rung 1 closes most of the gap
  cheaply, the interesting result may be a proposal-level hint rather than an engine mechanism.
- **The shadow stack stays open.** An engine-stack result for C-sourced `benchfx` programs
  leaves the per-coroutine linear-memory region untouched; the OCaml/WasmGC programs are where
  the engine result is the whole result. Say which is which in every table.

---

## Appendix A — where the code is

```
dependencies/wizard-engine/ (4a539337)
  src/engine/x86-64/X86_64Stack.v3        :9    class X86_64Stack (layout, ctor, scan, stubs)
                                          :1007 component X86_64StackManager (pool)
                                          :864  return-parent stub recycles into cache
  src/engine/Tuning.v3                    :75   StackTuning.stackCacheSize = 8
  src/engine/EngineOptions.v3             :8    DEFAULT_STACK_SIZE = 512 KiB, --stack-size
  src/engine/WasmStack.v3                 :207  version; :245 StackState
  src/engine/x86-64/X86_64Target.v3       :19   newWasmStack/recycleWasmStack; :163 TODO[sc] stubs
  src/engine/x86-64/X86_64Runtime.v3      :117  resume_throw; :138 suspend; :174 switch
  src/engine/Runtime.v3                   :360  CONT_NEW; :393 unwindStackChain
  src/engine/continuation/*.v3                  (stack, version) / boxed; getStoredObject
  src/engine/compression/*.v3                   RelocatableFrame, strategies, StackCompression
  src/engine/x86-64/{Mmap,Redzones,X86_64Frames}.v3
  test/unittest/CompressionTest.v3 · test/regress/ext:stack-switching/many_stacks.wast

dependencies/wasmtime/ (d8a0da6d66)
  crates/wasmtime/src/runtime/store.rs                       :2133 allocate_continuation; :466 continuations Vec
  crates/wasmtime/src/runtime/vm/stack_switching.rs          :204 VMContRef; :313 cont_new
  crates/wasmtime/src/runtime/vm/stack_switching/stack/unix.rs :89 mmap; :1-59 layout
  crates/wasmtime/src/runtime/vm/instance/allocator/pooling/unix_stack_pool.rs  (fibers only)
  crates/wasmtime/src/runtime/store/gc.rs                    :797 trace_wasm_continuation_roots
  crates/cranelift/src/func_environ/stack_switching/instructions.rs  :768 search_handler; :1245 cont.new; :1300 resume; :1900 suspend; :1974 switch
  cranelift/codegen/src/isa/x64/inst/{stack_switch.rs,emit.rs:550}
  crates/wasmtime/src/config.rs                              :301 async_stack_size; :2705 inlining refusal

benchmark/fiber-c/config.yml                        engine flags for benchfx
```

## Appendix B — sources

- Phipps-Costin, Rossberg, Guha, Leijen, Hillerström, Sivaramakrishnan, Pretnar, Lindley.
  *Continuing WebAssembly with Effect Handlers.* OOPSLA 2023. — the 55.5 / 13.4 MB result and
  the "most continuations require little stack memory" statement.
- Emrich & Hillerström. *Continuing Stack Switching in Wasmtime.* WAW 2025, paper and slides. —
  the staging, `stack_switch`, the 6× and the four mispredictions.
- Hillerström. *Benchmarking WasmFX.* Wasm Stacks subgroup, May 2024. — pooling 68×, safe vs
  unsafe stacks, the HTTP tail-latency result.
- Sivaramakrishnan et al. *Retrofitting Effect Handlers onto OCaml.* PLDI 2021. — fiber cost
  model, copy-and-double, the no-interior-pointers argument.
- Farvardin & Reppy. *From Folklore to Fact.* PLDI 2020. — resize beats segment on space.
- Alvarez-Picallo, Freund, Ghica, Lindley. *Effect Handlers for C via Coroutines.* OOPSLA 2024;
  Yu, *Evaluate the Stack Management in Effect Handlers using libseff*, 2025. — segment
  recycling 3–34×, overcommit comparison.
- Leijen & Sivaramakrishnan, libmprompt; OpenJDK Loom; Go contiguous stacks. — the grow-in-place,
  freeze/thaw, and shrink-at-GC designs.
- Full list with links: [`../lit-review/bibliography.md`](../lit-review/bibliography.md).
