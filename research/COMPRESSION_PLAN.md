# Stack compression for Wizard: techniques, heuristics, and how to evaluate them

**Version 1 — 2026-08-31.** A plan, not a report. It says what kinds of stack compression Wizard
can implement, in what order, with what policy, and how each step will be judged. It builds on
[`GOAL.md`](GOAL.md) (the thesis and the rung ladder, §2 and §9 there),
[`COMPILER_DIFF.md`](COMPILER_DIFF.md) (the time-side baseline: what a `suspend`/`resume`/`switch`
costs in Wizard's SPC today), and the literature notes in [`../lit-review/`](../lit-review/) —
extended here with the primary sources those notes summarize (Loom's freeze/thaw code, Go's
stack policy code, libmprompt's configuration, the Edinburgh 2025 libseff study, Farvardin &
Reppy's parameters, V8's growable stacks) and with the upstream state of Wizard's own
compression work. Sources are listed in §7; numbers are quoted with their source at the point of
use. Pinned submodules as before: Wizard `4a539337`, Wasmtime `d8a0da6d66`.

**Terminology.** *Compression* here means anything that makes a *suspended* continuation cost
less memory than the fixed reservation it was created with (GOAL.md §2). *Freeze/thaw* means
Loom-style copy-out of live frames into a right-sized heap object and re-materialization onto a
stack on resume. *Parked* means suspended and not resumed for a while; *trim* means decommitting
the untouched part of a mapping; *right-sizing* means choosing the reservation.

---

## 0. Summary

1. **Where Wizard is.** A pool of fixed 512 KiB stacks (three VMAs and one mid-mapping guard page
   each; the pool is unbounded and never decommits) and, upstream, a platform-independent
   compression layer (`RelocatableFrame` + a packed encoding) whose x86-64 reader/writer is in an
   open PR. That PR is the *mechanism* — read every frame's values into `Value` arrays, pack them,
   write them back onto an empty stack — with **no trigger, no policy, no release of the mapping,
   and no resume-side integration** yet. That is what "naive" means and it is the right starting
   point: it is exactly Loom's *slow path*, before any of Loom's fast paths.
2. **What the literature says to do, in order.** Every mature system did the cheap things first:
   pool (Wizard: done), decommit on recycle (Wasmtime's fiber pool, libmprompt), size from
   observation rather than a constant (Go 1.19's adaptive initial stack; OCaml's size buckets),
   grow in place under a reservation (libmprompt, kernel overcommit — the best general balance in
   the 2025 libseff study), and only then move frames (Go's shrink-at-GC; Loom's freeze/thaw,
   whose whole design is about making the copy *lazy*: reuse the chunk, thaw a few frames at a
   time behind a return barrier, budget ≈100–150 ns per operation). Nobody freezes eagerly on every
   suspend and nobody measures bytes per suspended continuation; both are the openings.
3. **The ladder for Wizard** (§3): R0 bound and account the pool → R1 lazy stack allocation at
   `cont.new` and right-sizing by size class with an adaptive default → R2 trim parked and pooled
   stacks with `madvise` → R3 reserve-large / commit-lazily with a movable guard, one region for
   many stacks to escape the VMA ceiling → **R4 freeze/thaw** (the main line), first eager and
   whole-stack, then *chunk reuse* on re-freeze and *lazy thaw* of the top frames → R5 frame-level
   savings (dead-slot elision, tag-free packing, `cont.clone` as a by-product).
4. **Heuristics** (§4): freeze from places that are already off the hot path — the runtime call
   that `suspend`/`switch` already make, pool-pressure handling, and the GC's stack walk — and
   never from an inline `resume`; decide per suspension by (a) how much a freeze saves
   (reservation, which is constant per stack, minus what a trim already saved), (b) how much it
   costs (live frames and values, known at the suspend point), and (c) how likely an early resume
   is (a per-suspend-site counter of "resumed within *k* switches", learned like Go learns its
   starting stack size). The recommended default is **lazy: freeze at GC and under pool pressure,
   with age and per-site back-off** — H4 in GOAL.md predicts it recovers nearly all of the memory
   for almost none of the time.
5. **Evaluation** (§5): the repo's suites establish the time baseline and the *shapes* (c10m,
   skynet, sieve, generators, schedulers) but none of them sweeps live suspended continuations,
   depth, or parked duration, and none reports memory; a new **park sweep** benchmark in three
   forms (C via fiber-c, pure `.wat`, OCaml) supplies those axes, plus a freeze/thaw
   microbenchmark, a scheduler with a park-time distribution, and adversarial and correctness
   workloads. Every rung is a flag so every number comes with its ablation. Success criteria are
   stated as numbers in §5.7.

---

## 1. Where Wizard is

### 1.1 The stack today (unchanged from GOAL.md §4)

`X86_64Stack` (`wizard-engine/src/engine/x86-64/X86_64Stack.v3:9-42`): one anonymous private
mapping per stack (`Mmap.v3:11-25`), size `EngineOptions.STACK_SIZE` (512 KiB default,
`EngineOptions.v3:8-9`; 64 KiB in `fiber-c/config.yml`), one guard page `mprotect`ed at the
middle so that the tagged value stack grows up from the start and native frames grow down from
the end (`X86_64Stack.v3:31-37`, diagram at `:975-1004`). Consequences that matter here:
**three VMAs per stack** (values / guard / frames), a **fixed 50/50 split**, and a per-value cost
of **32 bytes** on the value stack (16-byte tag, 16-byte payload) plus **104 bytes** per native
frame (`X86_64Frames.v3:7-41`). `X86_64StackManager` (`:1007-1043`) keeps an unbounded free
list refilled eight at a time (`Tuning.v3:75-77`); `clear()` resets fields only (`:336-345`) —
no zeroing, no `madvise` (Virgil exposes `SYS_madvise`, `rt/x86-64-linux/LinuxConst.v3:84`, but
`Mmap.v3` has no wrapper). Pooled stacks are never unmapped; abandoned suspended stacks are
unmapped by a mapping finalizer at the next Virgil GC (`Mmap.v3:23`), which their own 512 KiB
never trigger. The one-shot identity is the unboxed pair `(X86_64Stack, version)`
(`continuation/UnboxedContinuation.v3:4`), with `getStoredObject`/`fromStoredObject` (`:39-41`)
as the hook through which a continuation can name something other than a live stack.

The GC scans a stack by walking its tagged value slots and then its frames (`X86_64Stack.scan`,
`:496-517`), registered per stack object (`:40`). Everything on a stack is addressed absolutely
— `vfp`/`vsp` in frames, `parent_rsp_ptr`, return-parent slots (GOAL.md §4.7) — so a raw copy
would need fixups; re-materialization does not.

### 1.2 The compression scaffolding, and the open PR

Upstream (`src/engine/compression/`, from PRs #547/#598/#623/#625):

- `WasmFrameData(func, pc, ret_addr, vals: Array<Value>)` and
  `RelocatableFrame(data, is_spc, bytecode_ip)` (`Compression.v3:6-10`) — a frame as *values*, not
  bytes. `CompressionStrategy<C>` with `compress`/`decompress`; `CompressedStack` with `size()`.
- `NaiveCompressionStrategy` (keeps the `RelocatableFrame` array) and
  `PackedCompressionStrategy` (`PackedCompressionStrategy.v3`): per frame a `FrameHeader(func, pc,
  is_spc, ret_addr, bytecode_ip, n_vals)`, per value one tag byte plus a LEB payload, references
  side-tabled into `refs: Array<Object>`, continuations as `(stored object, version)`. So a packed
  `i32` costs 2–6 bytes instead of 32; a reference costs a byte plus one array slot.
- `StackCompression.compressStack(stack) = packed.compress(Target.readFramesFromStack(stack))`,
  `decompressStack(to, from) = Target.writeFramesToStack(to, decompressFrames(from))`
  (`Compression.v3:43-55`). At the pinned commit both target halves are `TODO[sc]` stubs
  (`X86_64Target.v3:163-167`, `V3Target.v3:46-50`).

**PR #647 "x86-64 Stack Compression"** (titzer/wizard-engine, open, marked ready for review on
2026-08-31; this is the WIP the task refers to, read here from its public diff): implements those
two stubs in an `X86_64Compression` component — `readFrames` walks the stack with a frame
collector, reverses to bottom-first, and for each frame records the function, the resume `pc`
(interpreter frames: `bytecode_offset` into `cur_bytecode`; SPC frames: recovered from the return
address), the return address, and every value between `vfp` and `vsp` as a `Value`;
`writeFrames` requires an `EMPTY` destination and rebuilds, per frame, the 104-byte native frame
(`setFrameContext`/`setSpcFrameContext`), the value slots, and the return address, clearing
`inlined_instance` so no stale GC root survives. Both frame kinds are handled and round-trip
tests (566 lines) include survival across a GC. What it deliberately does **not** contain:
where compression is triggered, what happens to the mapping of a compressed stack, how a
compressed continuation is resumed, and any policy. Those are what this document plans.

### 1.3 What "naive" costs, so the plan has a baseline

If the PR's mechanism were wired in eagerly — freeze on every `suspend`, thaw on every `resume`,
whole stack, through `Value` arrays — then per suspension the engine would: walk the frames
(Wizard's `walk` resolves each return address through `RiRuntime.findUserCode` and, for SPC
frames, `lookupTopPc` — the same lookup COMPILER_DIFF §7.1 measured at **501 instructions** per
frame inside `runtime_handle_suspend`), box every value into a `Value` (heap allocation per
frame's `Array<Value>`), LEB-encode into a `DataWriter`, allocate the packed arrays, and on
resume decode, allocate `Value`s again, take a stack from the pool, and rebuild the frames.
Against today's `suspend` (≈1 600 instructions, 179 ns per round trip with `resume`,
COMPILER_DIFF §3) that is plausibly another few hundred instructions *per frame*, i.e. a 2–5×
slowdown of the switch path on shallow continuations, and heap garbage on every switch — the
exact pattern that already crashes the interpreter's GC under switch pressure
(COMPILER_DIFF §5.5). Memory: a parked continuation drops from a 512 KiB reservation and 1–2
resident pages to a few hundred bytes (§3.5 estimates). So the naive plan buys the whole memory
result and pays a large, *avoidable* time cost; §3–4 are about keeping the first and removing
the second.

---

## 2. What the literature offers, distilled for decisions

The lit-review already has the survey ([`05-stack-memory.md`](../lit-review/05-stack-memory.md),
[`01-background.md`](../lit-review/01-background.md) §3, [`06-openings.md`](../lit-review/06-openings.md)).
This section is what the *primary sources* say that bears on a design decision for Wizard, in
the order the decisions come up.

### 2.1 Sizing: fixed is a guess, so learn the size

- **WasmFX** (Phipps-Costin et al. 2023): 4 KiB fixed per coroutine → 55.5 MB vs 13.4 MB for a
  hand-written state machine at 10 000 live coroutines; *"most continuations require little
  stack memory."* The bespoke number is the floor to aim at: ≈1.3 KB per connection including
  application state.
- **Go** (`runtime/stack.go`): minimum stack `stackMin = 2048`; since Go 1.19 the *initial* size
  is adaptive — after each GC, `gcComputeStartingStackSize` sets the next starting size to the
  average scanned stack size plus the guard, clamped to `[fixedStack, maxstacksize]`, enabled by
  `debug.adaptivestackstart`; the release note's justification is *"avoid some of the early stack
  growth and copying needed in the average case in exchange for at most 2x wasted space on
  below-average goroutines."* This is the precedent for **sizing from observation with a bounded
  waste factor**.
- **OCaml 5** (multicore design doc): fibers start at `caml_fiber_wsz` = 32 words, double on
  overflow, and are recycled through a **cache with per-size buckets** — a size-class pool.
- **Folly fibers**: fixed-size pooled stacks with guard pages, plus `recordStackEvery` — fill a
  fiber's stack with a magic pattern and later search for the high-water mark. A production
  precedent for **profile-guided sizing** of coroutine stacks.
- **Farvardin & Reppy 2020**: `resize` starts at 8 KB *"chosen empirically by first finding the
  smallest size such that a larger initial size yielded no benefit for the deeply-recursive ack
  benchmark"*; `segment` uses 64 KB segments and copies at most four frames or one-eighth of a
  segment on overflow; `contig` needed 128 MB to run everything. Their verdict: *"The segmented
  stack is not space efficient because the segment size is constant and constrained by the
  efficiency of the overflow and underflow handlers. Whereas we can pick a small initial size for
  a resizing stack."*

### 2.2 Commit management: reservation is cheap, residency is what to manage

- **libmprompt** (`include/mprompt.h`, `mp_config_t`): a gstack reserves `stack_max_size` = 8 MiB
  and commits `stack_initial_commit` = one page; `stack_grow_fast` grows *"by doubling (to up to
  1MiB at a time) instead of per-page"*; `stack_gap_size` = 64 KiB of no-access gap between
  stacks; `stack_cache_count` = 4 gstacks cached per thread; `stack_reset_decommits` chooses
  between *resetting* a cached stack's memory and a *full decommit*; `stack_use_overcommit`
  (Linux) *"disables gpools and fast stack growing"*; gpools carve up to 256 GiB of address space
  so that many stacks share one reservation. The cache-then-reset-or-decommit choice is exactly
  the trim decision in §3.3.
- **Wasmtime's fiber pool** (`pooling/unix_stack_pool.rs`, not wired to continuations): one
  reserved region, fixed slots with `PROT_NONE` guards, and on release `zero_stack` keeps
  `async_stack_keep_resident` bytes warm and `madvise`s the rest away (lit-review 04 §5).
- **Yu 2025** (libseff, Edinburgh): kernel overcommit is *"the best general balance"*; its cost is
  paid at first touch, not at switch — plain switch latency 1 µs (fixed, segmented) vs 5 µs
  (kernel overcommit) vs 44 µs (user-level overcommit) in their harness, converging to 3.7–4.0 ms
  per 10 000 iterations once work is added; dynamic expansion 115 µs (kernel) vs 3 700 µs
  (segmented). Its stated limitations are the ones to design around: *batch commit "may waste too
  much RAM when actual usage is low or partial"* and SIGSEGV+`mprotect` commit is
  *non-deterministic under concurrency*. Wizard is single-threaded and already uses a SIGSEGV
  path for the guard page, so the second does not bite; the first is why trimming must be measured
  in resident pages, not requested bytes.

### 2.3 Growth: grow in place if you can, copy if you may, segment only if you must

- **Copy-and-double** works when nothing points into the stack (OCaml: two words to patch; Go:
  the runtime rewrites every interior pointer because it has every frame's layout). Wizard's
  engine stack is addressed absolutely by its own runtime structures, so a *raw* copy needs
  fixups; re-materialization (§3.5) sidesteps them.
- **Segmented** stacks pay the hot split: libseff measured 11× at zero work, gone by ≈13 FLOPs, and
  **recycling segments rather than freeing them is worth 3–34×**. **V8 nonetheless chose
  segmented stacks for JSPI** ("growable stacks": *"we would like to support applications with
  millions of suspended coroutines; this is not possible if each stack is 1MB in size"*; on
  overflow *"a builtin allocates a new stack segment and evacuates overflowed frame there with
  incoming params"*, growing until `--stack-size`). The difference from libseff is that V8 starts
  small and splits rarely; the hot split is a microbenchmark problem when segments are large and
  recycled. For Wizard, segmentation would break the contiguous tagged value stack and the
  frame-pointer-free `walk`; it is considered and rejected in §3.8.
- **Reserve and commit lazily** (libmprompt, kernel overcommit) is the only growth strategy
  compatible with absolute addresses, which is why it is R3 and why R3 does not depend on R4.

### 2.4 Shrinking and moving frames: Go and Loom

- **Go `shrinkstack`** (`runtime/stack.go`): at a GC safe point, if the goroutine uses less than a
  quarter of its stack (`used >= avail/4 → return`), allocate half the size and copy, never below
  2 KiB; blocked while in a syscall, at an async safe point (imprecise maps), or while parking on a
  channel. **Shrink decisions are taken when the collector is already looking at the stack** and
  use a hysteresis (¼ used → ½ size) so shrink and grow do not alternate.
- **Loom freeze/thaw** (`hotspot/share/runtime/continuationFreezeThaw.cpp`): frames are copied
  *verbatim* into a heap `StackChunk`; the **fast path** requires all frames compiled and a chunk
  that needs no GC barriers — then *"frames simply copied, and the bottom-most one is patched"*;
  the chunk is **reused in place** when it has room and is not in GC mode, otherwise a new chunk
  is allocated (young generation, no barriers; old generation triggers relativization of derived
  pointers). **Thaw is lazy**: below a `threshold = 500` words the whole chunk is thawed, above it
  *one frame at a time*, the thawed frame's return address patched to a **return barrier**
  (`cont_returnBarrier`) that thaws the next frame on return. The stated budget: *"An ordinary
  and well-behaved server application would likely call these operations many thousands of times
  per second on every core … The amortized budget for each of those two operations is
  ~100-150ns."* Interpreted frames take the slow path where internal pointers are relativized.
  Footprint: JEP 444 describes virtual-thread stacks as heap stack-chunk objects that grow and
  shrink; third-party measurements put a parked virtual thread in the high hundreds of bytes
  (§7). Three transferable rules: **reuse the chunk on re-freeze**, **thaw lazily behind a
  barrier**, **keep a per-operation budget and design to it**.
- **Chez/Dybvig lineage** (Hieb, Dybvig & Bruggeman 1990; Bruggeman, Waddell & Dybvig 1996):
  capture splits the stack into segments with underflow frames; one-shot continuations never copy.
  The underflow frame is the same idea as Loom's return barrier and Farvardin & Reppy's
  underflow handler — a stub at the bottom of a partially materialized stack that fetches the
  rest on demand. That is the mechanism for lazy thaw in §3.6.

### 2.5 Representation and identity

- **Stable indirection** is the universal enabler (Effekt's prompts, Loom's chunk handles,
  Wasm's fat-pointer revision, Ma/Jung/Zhang's virtual handler IDs in *Virtualizing
  Continuations*, PLDI 2026, where `resume` copies and `resume_final` is the destructive
  fast path). Wizard's `(stack object, version)` pair already is that indirection: the object
  stays put in the Virgil heap, only what it *holds* changes.
- **Refcount-1 in place, copy on share** (Muhcu et al., ICFP 2025): one-shot resumption is
  free, multi-shot is a copy of a frame array. With a packed frame array, `cont.clone` is an
  array copy plus a fresh version — the by-product noted in GOAL.md §9.6.
- **Frame descriptors are the price of moving frames** (Farvardin & Reppy: the stack walker and
  the return-address→layout hash lookup were the runtime's bottleneck; Loom: oop maps and
  frame sizes). Wizard already has them: `FrameAccessor`, `lookupTopPc`, `frame_var_tags`, the
  tagged slots. The cost is that they are *slow to consult* (501 instructions per SPC frame for
  the pc lookup); §3.5 caches what a freeze needs per frame.

### 2.6 What none of them measure

No source reports bytes per suspended continuation as a function of how many are live or how deep
they are (lit-review 02 §4, 06 §2a); the benchmark checklist from lit-review 02 §5 (sweep depth,
size, and live count; report peak and steady RSS; separate the four resumption categories;
include a no-continuation control) is adopted wholesale in §5.

---

## 3. The ladder for Wizard

Each rung is a separately switchable mechanism (a flag, so §5 can ablate it), states what it
shrinks, what it costs, what it needs from the engine, and what would make it fail. Rungs R0–R3
keep every stack where it is; R4–R5 move frames. R3 and R4 are independent of each other and
both are worth having: R3 removes the *sizing guess* for running and short-parked stacks, R4
removes the *reservation* for long-parked ones.

### 3.1 R0 — Pool accounting and bounds (prerequisite)

*What:* count mapped, pooled, running, suspended and frozen stacks; bound the pool (return
mappings above a high-water mark to the OS, or decommit them — R2) instead of keeping every stack
ever allocated; expose the counts as `Metrics` so every later number is measurable from inside
the engine.
*Cost:* none on the switch path (the pool is touched at `cont.new` and return).
*Needs:* a few counters in `X86_64StackManager` and the return-parent stub's recycle path
(`X86_64Stack.v3:864-873` pushes onto `cache` from machine code; the bound check can stay in the
runtime because it only has to be *eventually* enforced, e.g. at `allocStackBatch` or at GC).
*Why first:* the "abandoned continuations wait for a GC their mappings never trigger" problem
(GOAL.md §11) means a memory benchmark cannot distinguish held-by-design from held-until-GC
without this accounting. Also the place to add a `--stack-pool-max` knob.

### 3.2 R1 — Right-sizing: lazy allocation, size classes, adaptive default

*What, in three steps:*
1. **Allocate no stack at `cont.new`.** A fresh continuation is a function reference plus bound
   arguments (`cont.bind` stores them); it needs a stack only at first `resume`/`switch`. Represent
   a fresh continuation as a stack object in state `SUSPENDED` with `mapping == null` and the
   bound values in a small array — the same "frozen shell" representation R4 uses, so this step is
   R4's representation arriving early with zero frames. Workloads that create many continuations
   before running them (`skynet`'s tree, `sieve`'s filter chain, any actor spawn loop) stop
   paying a 512 KiB reservation and a pool refill per creation.
2. **Size classes.** Several free-list heads keyed by size (e.g. 16 KiB, 64 KiB, 512 KiB); pick a
   class at first resume from (a) an explicit hint if one ever exists at the proposal level
   (there is none today — lit-review 06 §2d), (b) a per-function profile (the max depth observed
   the last time this function ran as a continuation body, recorded at return or at freeze), or
   (c) the adaptive default below. Overflow of a too-small class becomes a grow event handled by
   R3 (grow in place) or, without R3, by freeze-and-thaw-onto-the-next-class (R4 makes a
   relocating grow free).
3. **Adaptive default, Go-style.** Keep the running average of *live bytes at suspend/return* (the
   walk already computes it in R4; without R4, `rsp`/`vsp` distance is enough) and choose the
   smallest class ≥ average + slack, clamped, recomputed at GC as Go does. Bounded waste: at most
   one class step above the average.

*Cost:* one branch at first resume; none on later switches. *Needs:* the machine-code recycle
path to become size-aware (it can simply push onto a per-stack-object class head, since the
object knows its size), the guard page placed relative to the class size, and `many_stacks.wast`
(999 live continuations) to keep passing. *Risk:* a wrong small class costs an overflow trap
today (no growth); R1 must therefore ship with either R3 or R4's relocating grow. *Expected
effect:* the reservation per continuation drops 8–32×, the *resident* footprint does not change
(pages are already committed lazily) — R1 is the VMA and address-space rung, and the ablation
that measures how much of the gap is reservation rather than residency.

### 3.3 R2 — Trim: decommit what a stack no longer touches

*What:* `madvise(MADV_DONTNEED)` (or `MADV_FREE`) the pages of a stack that are not live:
(a) on **recycle**, everything except the top page of each half (Wasmtime's `keep_resident`
shape), and (b) on **park**, everything outside `[range.start, vsp)` ∪ `[rsp, range.end)` — a
suspended continuation keeps exactly its live pages resident. No frame moves; addresses stay
valid; the next touch re-faults a zero page.
*Cost:* one syscall per trim (≈1–2 µs) plus page faults on resume for pages that were trimmed —
so **park-time trim must be lazy** (age or GC, §4), never on every suspend of a hot generator.
Recycle-time trim is cheap to make eager if the pool is hot-capped (keep the *N* most recently
used stacks untrimmed).
*Needs:* an `Mmap.advise` wrapper; the high-water marks (`vsp`, `rsp` at park; for recycle, the
stack's max extent, which needs either a cheap probe or a per-stack `max_vsp/min_rsp` updated at
runtime calls — not on every call, so it is approximate; libmprompt and Wasmtime simply trim a
fixed policy amount).
*Expected effect:* resident bytes per *parked* continuation fall to the live pages (≥ 2 × 4 KiB
because the two halves live on different pages); per *pooled* stack to ≤ 8 KiB. This is the rung
that makes "resident memory ∝ live frames" true at page granularity; R4 makes it true at byte
granularity. It is also the cheapest rung to implement and the one most likely to be "enough"
for workloads whose parked continuations are shallow but numerous (c10m).

### 3.4 R3 — Reserve large, commit lazily, grow in place; one region for many stacks

*What:* replace "512 KiB mapping with a guard in the middle" by "a large reservation (e.g.
8 MiB, libmprompt's `stack_max_size`) of which a small initial region is committed, with the
guard page *movable*": on a guard fault, if the reservation has room, `mprotect` the guard away,
commit the next chunk (doubling up to a cap, libmprompt's `stack_grow_fast`), re-place the guard,
and return from the signal — a grow-in-place event, not a trap. The two halves of Wizard's
layout (values up, frames down) each get their own reservation and guard, which also removes the
fixed 50/50 split. Optionally, allocate stacks from **one large reservation** carved into slots
with computed addresses (libmprompt's gpool, Wasmtime's fiber pool) so that the VMA count no
longer grows three per stack; note that `mprotect`ed guards still split VMAs, so the win is
bounded — measure `/proc/self/maps` before deciding.
*Cost:* nothing on the switch path; a page fault per first touch of each page (already true) and a
signal round trip per *growth step* (rare; the Edinburgh study's 115 µs per expansion under
kernel overcommit is the order of magnitude, Wizard's own SIGSEGV path is the mechanism).
*Needs:* `RedZones` to support moving a zone; the overflow handler (`X86_64Stack.v3:323-334`) to
distinguish "grow" from "overflow"; `Mmap.protect` already exists. Address space: 8 MiB × 10 000
live stacks = 80 GiB of *reservation*, fine on x86-64 (`MAP_NORESERVE` to stay clear of the
commit charge).
*Risk:* reservation size becomes the new guess, but a harmless one; `vm.max_map_count` remains a
ceiling unless the single-region variant is used.
*Expected effect:* removes the sizing guess and the overflow trap for *running* continuations and
lets R1 pick aggressively small initial commits. Does nothing for parked residency (R2) or
reservation-per-parked-continuation (R4).

### 3.5 R4 — Freeze/thaw: the main line

*What:* on freeze, read the frames (PR #647's `readFrames`), pack them (`PackedCompressionStrategy`),
store the packed object on the stack object, and **release the mapping to the pool**; on thaw,
take a mapping from the pool (right class, R1), `writeFrames`, and hand it to the ordinary
resume path. Concretely, in Wizard's terms:

- **Identity.** The `X86_64Stack` object *is* the continuation's identity (every `(stack, version)`
  value in tables, locals, and other frozen stacks points at it — packed conts store
  `(getStoredObject, version)` already). So the object stays; it gains a `frozen: CompressedStack`
  field and `mapping = null`. Its `version` and `state_` keep working unchanged, so the one-shot
  check in the inline `resume` (COMPILER_DIFF §4.1: `cmp [stack+8], version`) needs no change.
- **Mapping hand-over.** The pool holds stack *objects*, and the return-parent stub pushes objects
  from machine code, so the least intrusive release is to wrap the mapping in a fresh pool
  object (or keep a separate free list of mappings behind `getFreshStack`). Either way a freeze
  returns *one whole reservation* to the pool — the saving is the full 512 KiB (or class size)
  plus its three VMAs, regardless of how much was live.
- **Trigger points** (all already runtime excursions, so no new call boundary on the hot path):
  `runtime_handle_suspend`/`runtime_handle_switch` for eager or age-based freezing of the
  *suspending* stack; `allocStackBatch` for pool-pressure freezing of the *oldest parked* stacks;
  the GC scan (`X86_64Stack.scan` is invoked per stack per collection) for GC-time freezing — the
  collector is already walking the frames, and a frozen stack's roots are the packed `refs`
  array, which the collector traces as an ordinary heap object, so **a frozen stack needs no
  custom scan at all** (its scanner returns immediately when `mapping == null`).
- **Resume path.** The inline SPC `resume` copies arguments into `[child.vsp]` before switching
  (COMPILER_DIFF §4.1, `emit_cont_mv`); for a frozen child that address is gone. Add one test on
  the fast path — load `frozen`, `test`, `jne slow` — before the argument copy; the slow path
  calls `runtime_thaw(stack)`, which allocates, writes frames, restores `vsp`/`rsp` and the
  return-parent/enter slots (`reset`-like), and returns; the fast path then continues unchanged.
  `switch` and `resume_throw*` already run in the runtime and thaw there. The interpreter's
  resume path is a runtime call too. Cost on the fast path: 2–3 instructions.
- **Both frame kinds** are handled by the PR; SPC frames keep state in memory at switch points
  (`SinglePassCompiler.v3:1475`; COMPILER_DIFF §4.1 shows `emitSaveAll` before every
  suspend/switch), which is the property that makes `Value`-level reading complete. Any future
  SPC optimization that keeps values in registers across a suspend would have to be told to
  spill (as it must for the GC anyway).
- **Fresh continuations** (R1.1) are the zero-frame case of the same representation:
  `frozen = { func, bound args }`, thawed by `reset(func)` + `bind`.
- **Traps, exceptions, cancellation.** `resume_throw` into a frozen continuation: thaw, then the
  existing `contStack.throw` walk (`X86_64Runtime.v3:117-133`). A frozen continuation that is
  abandoned is reclaimed by the ordinary GC (no mapping to finalize) — which is the answer to
  GOAL.md §11's "held until GC" problem for *frozen* stacks, and one more reason to freeze at GC.
- **Multi-shot** falls out: `cont.clone` = copy the packed object into a new stack object with
  version 0. Not a goal; cheap to expose behind a flag for §5's multi-shot comparison.

*The costs, and the three Loom optimizations that cut them:*

1. **Freeze cost** ∝ frames × (walk + pc lookup + value boxing + encoding). Cache per frame what
   the walk recomputes: `lookupTopPc` is 501 instructions per SPC frame today because it binary
   searches a pc map from a return address — a return-address→(pc, frame layout) cache (a small
   hash keyed by return address, like Farvardin & Reppy's) makes repeated freezes of the same
   sites O(1). Avoid `Array<Value>` boxing by packing straight from the tagged slots (the tag byte
   *is* the `Value` tag; the payload is 16 bytes) — the PR's `Value` path is the correct
   *reference* implementation, the byte path is the fast one.
2. **Re-freeze reuse** (Loom's chunk reuse): a continuation that cycles suspend→resume→suspend
   at the same site with the same depth produces the same packed shape; keep the previous packed
   buffer on the stack object and overwrite in place when it fits (no allocation, no GC pressure).
   This is what turns "freeze on every suspend" from a garbage generator into a memcpy.
3. **Lazy thaw** (Loom's threshold + return barrier): thaw only the top *k* frames (Loom: the whole
   chunk below 500 words, otherwise one frame at a time); leave an **underflow stub** as the
   bottom frame's return address which, when returned into, thaws the next batch. Wizard already
   has exactly this kind of stub — the return-parent stub is a return address that does runtime
   work — so an "underflow stub" is a sibling of it. Benefit: a deep parked continuation (skynet,
   treesum at depth 25) resumes in time proportional to what it touches, and a continuation that
   re-suspends before touching its deep frames never thaws them (they stay packed, and re-freeze
   is a no-op for them — *incremental freeze*).

*Expected effect (estimates to be replaced by §5 measurements):* a parked continuation costs the
stack object (~150 bytes), a `FrameHeader` (~40 bytes) per frame, and 2–17 bytes per live value
(LEB) plus 8 per reference — **a shallow continuation with a handful of values is in the
100–400 byte range**, i.e. Loom's "few hundred bytes" and two orders of magnitude below a
resident page, three below the reservation. The time cost, with the three optimizations, should
be a small multiple of the values touched; without them, hundreds of instructions per frame.

### 3.6 R4′ — Partial freeze and lazy thaw as separate knobs

Lazy thaw (above) and *partial freeze* (freeze only frames below the top *k*, keep the top *k*
live on a small stack) are independent switches with different targets: lazy thaw helps deep
continuations that resume rarely; partial freeze helps continuations that alternate between
"resume, do a little, suspend" (generators) — their top frame stays hot and only the cold prefix
is packed once. Both are Loom's design; both are measured separately in §5.

### 3.7 R5 — Frame-level savings (after R4 works)

- **Dead-slot elision.** At a suspend point the compiler knows which locals and operands are live
  (SPC has `frame_var_tags` and the abstract stack state; the interpreter has the same
  information from validation). Packing only live slots shrinks the packed frame and, more
  importantly, drops dead references so the GC does not retain garbage through parked
  continuations (a real leak class in Loom's early days).
- **Tag-free packing.** The 32-byte tagged slot is Wizard's *runtime* representation; the packed
  form already has a tag byte per value; a per-frame type vector (from the function's signature
  and validation types at the pc) would let values be stored raw (4/8/16 bytes) with no tags —
  ≈2× on the packed size, at the cost of more decoder work.
- **Shared prefixes.** Continuations created by the same parent at the same site (skynet's tree)
  share their bottom frames only under multi-shot; under one-shot semantics there is nothing to
  share. Not worth doing until `cont.clone` exists.

### 3.8 Considered and rejected for Wizard

- **Segmented engine stacks** (V8's growable stacks, libseff): incompatible with Wizard's
  contiguous tagged value stack and its guard-page overflow detection; would need prologue checks
  in both tiers (OCaml paid +19–30 % text for those) and a hot-split story. R3's grow-in-place
  gives the same "start small" property without moving or splitting anything.
- **Raw byte copy of the stack** (Go/OCaml-style memcpy with fixups): every frame stores
  absolute `vfp`/`vsp`, `parent_rsp_ptr` points into another mapping, accessor objects cache
  absolute `sfp`s (GOAL.md §4.7); re-materialization is strictly simpler and already written.
- **Compressing the shadow stack.** Out of scope for the engine (GOAL.md §2); the OCaml/WasmGC
  suites are where an engine-stack result is the whole result.
- **A separate "compressed stack" heap type visible to Wasm.** Unnecessary: the `(stack, version)`
  pair already hides the representation.

---

## 4. Heuristics: when and where to compress

The mechanism (§3.5) is policy-free. This section is the policy: what the engine can know at a
suspension, what a freeze is worth, and which decision procedure to ship as the default.

### 4.1 What Wizard can know at a suspension, cheaply

| Signal | How cheap | Where it comes from |
|---|---|---|
| The **suspend site** (function, `pc`) and **tag** | free | `runtime_handle_suspend`/`switch` receive `instance` and `tag_id`; the site `pc` is the parent's handler lookup key already computed |
| **Live bytes** of the suspending stack | two subtractions | `vsp − range.start` (values), `range.end − rsp` (frames) |
| **Frame count / value count** | a walk | only computed when a freeze actually runs |
| **Age**: switches or time since suspension | one global counter increment per switch; `rdtsc` (a pregen stub exists) | stored on the stack object at suspend; compared by whoever sweeps |
| **Resume-distance history per site** | one EWMA update per resume | `d_site` = switches between this site's suspends and their resumes; the analogue of Go learning its starting stack size and of an inline cache learning a receiver |
| **Pool pressure** | free | `getFreshStack` finds `cache == null` and is about to `allocStackBatch` (8 mmaps) |
| **GC epoch** | free | `X86_64Stack.scan` runs once per live stack per collection; "parked at two consecutive GCs" is Go's hysteresis in Wizard's terms |
| **Fresh vs resumed** | free | `state_ == SUSPENDED && func != null && no frames` — freezing costs nothing (R1.1) |
| **Pinned** (cannot freeze) | during the walk | the walk meets a frame `RiRuntime.findUserCode` does not recognize as Wasm (a host re-entry inside the continuation), or a `FrameAccessor` is outstanding for a frame (a probe/debugger holds an absolute `sfp`) — the same rule as Loom's pinning on native frames |

Not available and not worth building: knowledge of *who* holds the continuation (a table slot, a
local, another frozen stack) — the GC knows, the policy does not need to.

### 4.2 What a freeze is worth: the cost model

Per suspended continuation, per unit time parked:

- **Saved by R2 (trim)**: resident pages outside the live range — everything but the ≥2 pages
  the live halves sit on. Cost: one `madvise` (≈1–2 µs) and a page fault per page re-touched.
- **Saved by R4 (freeze)** on top of R2: the reservation `R` (512 KiB or the R1 class) and its
  three VMAs, the remaining 2+ resident pages, and the stack object's mapping pressure; retained:
  the packed bytes `B` (hundreds). Cost: `C_f = a_f + b_f·frames + c_f·values` to freeze and
  `C_t = a_t + b_t·frames + c_t·values` to thaw, both paid once per park–resume cycle, plus any
  page faults the thawed stack takes.

A freeze at a site with mean resume distance `d` (switches between suspend and resume) adds
`(C_f + C_t)/d` to the average cost of each switch at that site. With `C_x` the cost of a plain
switch, the constraint "compression must not slow hot switching by more than `ε`" is

    freeze at a site only if  d_site ≥ d* = (C_f + C_t) / (ε · C_x)

Numbers to calibrate `d*` (to be replaced by §5.3 benchmark 4): today `C_x ≈ 1 600` instructions
(COMPILER_DIFF §3.2). A naive two-frame freeze+thaw through `Value` arrays is plausibly
`C_f + C_t ≈ 2 000–4 000` → at `ε = 10 %`, `d* ≈ 12–25` switches; an optimized byte-level
freeze/thaw with chunk reuse (`≈ 300–600`) → `d* ≈ 2–4`. **If the time-side work in
COMPILER_DIFF §7 lands, `C_x` falls to ≈ 100 and `d*` rises 16×** (≈ 200 naive, ≈ 40 optimized).
Two conclusions: eager freezing is only ever acceptable when `C_f + C_t ≪ C_x`, which stops being
true the moment switching is made fast; and the policy must learn `d_site`, because the same
mechanism is a win at `d = 10 000` (c10m: one yield per connection, resumed much later) and a
loss at `d = 1` (sieve, state, pingpong).

The memory side has no such trade-off: freezing a continuation parked for time `T_p` saves
`≈ (R_resident_after_trim + pages) · T_p` byte-seconds and `R` of address space for the whole
`T_p`. Since `R` dominates and is constant, **the decision is entirely about the time cost and
the resume-distance prediction**, not about how much the continuation holds.

### 4.3 Policies

Named so that §5 can ablate them; each is a few lines of code on top of §3.5.

- **P-eager** — freeze in `runtime_handle_suspend`/`switch` on every suspension; thaw on every
  resume. Memory-optimal, time-worst, and the strongest *correctness* mode (every continuation
  round-trips through the packed form). Ships as a flag, not a default.
- **P-age(k, t)** — freeze when a continuation has been parked for ≥ `k` switches or ≥ `t` µs.
  Needs a **parked list**: an intrusive list of suspended stacks in suspension order (the head is
  the oldest); the sweeper (below) walks from the head and stops at the first young entry — O(1)
  amortized per switch. Trim (R2) uses the same list with a smaller threshold: trim early, freeze
  late.
- **P-pressure** — before `allocStackBatch`, freeze the oldest parked stacks until the request is
  served; and keep mapped stacks under `--stack-pool-max` by freezing from the old end. Memory is
  bounded by construction; the time cost appears only when memory would otherwise grow.
- **P-gc** — during the collection's `scan`, freeze every stack that was already parked at the
  previous collection (two-epoch rule). The walk is being done anyway, the packed `refs` become
  ordinary roots, and abandoned frozen continuations die with no finalizer. Reclamation is GC-bound,
  which matches Wizard's existing behaviour rather than fighting it.
- **P-site(ε)** — the learner: per suspend site keep `d_site` (EWMA of resume distance) and a
  miss counter; a stack is a freeze candidate only if `d_site ≥ d*`; a resume of a frozen stack
  within `k_miss` switches of its freeze is a miss and doubles the site's threshold (back-off,
  exactly like a polymorphic inline cache giving up). Sites that never miss converge to freezing
  as early as P-age allows.
- **P-partial(F, K)** — for continuations with more than `F` frames, freeze only the cold prefix
  (everything below the top `K` frames) and thaw lazily (§3.6); below `F`, whole-stack.

**Sweepers.** P-age and P-pressure need a place to run that is not the switch path. Three exist
today: the GC scan, `allocStackBatch`, and the runtime call the interpreter's and SPC's
`suspend`/`switch` already make (every *M*-th call can pop old entries off the parked list). If
COMPILER_DIFF §7's inline `suspend` lands, the third disappears and the first two remain — which
is fine, because the first two are where the memory pressure is *observed*.

### 4.4 Where: which frames, which values, which representation

- **Whole stack vs partial.** Whole-stack freeze is right for shallow continuations (most of
  them: c10m's one frame, a generator's two or three). Partial freeze + lazy thaw is right for
  deep ones (treesum at depth 25, skynet's chains, `algorithmic_differentiation`'s handler
  towers): freeze the cold prefix once, keep the hot top frame(s) on a small stack, thaw the
  prefix a batch at a time behind an underflow stub. Loom's threshold is 500 words (≈ 4 KB) for
  "thaw everything"; Wizard's equivalent knob is in frames or packed bytes and is measured in
  §5.3 benchmark 5.
- **All values vs live values.** Start with all (the PR's reader is complete and simple);
  liveness elision (R5) is a size and GC-retention refinement, measured separately.
- **Packed vs naive.** `NaiveCompressedStack` keeps `Value` arrays (fast to thaw, 16+ bytes per
  value); `PackedCompressedStack` LEB-encodes (slow to thaw, 2–17 bytes per value). A
  middle representation — raw 16-byte payloads with a per-frame tag vector, no LEB — is likely
  the best default (memcpy in and out, ≈ 4× smaller than the slot form, no decoder loop). Measure
  all three on benchmark 4 before choosing.
- **Trim vs freeze.** Trim is a syscall and no data movement; freeze is data movement and no
  syscall. Trim first (age `t_trim`), freeze later (age `t_freeze`) unless pressure forces it.

### 4.5 The decision procedure (recommended default)

```
on suspend/switch (runtime path):                  # no policy work on the hot path beyond bookkeeping
    stack.parked_at = (switch_count, rdtsc)
    parked_list.push_back(stack)                   # intrusive, O(1)
    site = (func, pc); site.suspends++
    if P_eager: freeze(stack)

on resume/switch-to (runtime or inline slow path):
    parked_list.remove(stack)
    site.d = ewma(site.d, switch_count - stack.parked_at.switches)
    if stack.frozen:
        thaw(stack)                                # lazy: top K frames + underflow stub
        if age(stack) < k_miss: site.threshold *= 2   # miss: back off

sweep(reason):                                     # reason ∈ {gc, pool_pressure, periodic}
    for stack in parked_list from oldest:
        if age(stack) < t_trim and reason != pool_pressure: break
        if not stack.trimmed: trim(stack)          # R2
        if reason == gc and stack.parked_epochs >= 2, or
           reason == pool_pressure, or
           age(stack) >= t_freeze and site(stack).d >= site(stack).threshold:
            if freezable(stack): freeze(stack, partial = frames(stack) > F)
        if reason == pool_pressure and pool.has_room(): break
```

Defaults to start from (all to be tuned on §5.3 benchmarks 2–3): `t_trim` = 1 ms or 1 000
switches, `t_freeze` = 10 ms or 100 000 switches, `k_miss` = 100 switches, `ε` = 10 %, `F` = 32
frames, `K` = 2 frames, `--stack-pool-max` = 256 stacks. P-eager and P-gc-only are the two
ablation extremes.

### 4.6 What the heuristics must not do

- Add a call boundary to the inline `resume` beyond the `frozen` test (2–3 instructions), or any
  work to a hot `switch` beyond bookkeeping — the RAS/libcall lesson from Wasmtime (GOAL.md §8).
- Allocate on the hot path. Bookkeeping is field writes; the packed buffer is reused on
  re-freeze; freezing under pressure must not itself need the pool.
- Freeze pinned stacks, or stacks with outstanding accessors, or a stack in any state other than
  `SUSPENDED`/`RESUMABLE`.
- Depend on wall-clock time for correctness — `rdtsc` is a hint; `switch_count` is the durable
  clock.

---

## 5. Evaluating it thoroughly

### 5.1 Metrics and instruments (on this machine)

| Metric | Instrument | Notes |
|---|---|---|
| Resident memory, steady and peak | `/proc/self/status` `VmRSS`/`VmHWM` sampled by the harness at checkpoints; `/usr/bin/time %M` for peak | RSS includes engine + module + pool; always subtract a zero-continuation baseline |
| Virtual size, VMA count | `VmSize`; `wc -l /proc/<pid>/maps` | `vm.max_map_count` = 65 530 here; three VMAs per Wizard stack today |
| **Bytes per suspended continuation** | `(RSS(N) − RSS(0)) / N` at steady state with `N` parked | report alongside the engine's *exact* number (packed bytes + object size) from `Metrics` |
| Engine accounting | new `Metrics`: `stacks:mapped/pooled/parked/frozen`, `frozen:bytes`, `freeze:count`, `freeze:cycles`, `thaw:count`, `thaw:cycles`, `trim:count`, `pool:refills` | `CyclesMetric` uses `rdtsc`; printed with `--metrics` |
| Time per operation | the 1 M vs 10 M differencing of COMPILER_DIFF §3.1 (`/usr/bin/time`, ≥3 runs) | WSL2 has no hardware counters; for instruction-level numbers use `compiler-diff/count-insns.py` (gdb single-step) on the runtime functions |
| GC | collections and time per run (add a metric), scan time per stack | frozen stacks should be *cheaper* to scan |
| First wall | the smallest `N` at which a configuration fails, and how | `mmap` failure / VMA limit / OOM / trap — reported, never dropped |
| Correctness | the program's own checked result; the reference interpreter for new `.wast` | see §5.5 |

### 5.2 What the repo's benchmarks can and cannot show

| Benchmark | Shape (live continuations × depth × resume distance) | What it tests for compression | What it cannot show |
|---|---|---|---|
| fiber-c `c10m` (`ACTIVE_CONN` 10 000 live, 10 M total, one yield each, shallow) | 10⁴ × 1 × ≈10⁴ | the canonical "many parked, shallow, cold" case; where R1/R2 should already remove most of the memory and R4 reaches bytes; `benchfx` has the hand-written state-machine floor (`c10m_bespoke.c`) and an Asyncify build | one `N`; no depth |
| `skynet` (1 M leaves, height 6, six active) | ≈6 deep chains, 10⁶ creations | creation cost with R1.1 (no stack at `cont.new`), parents parked while children run | shallow per frame; no long parks |
| `sieve` (`N` filter fibers alive, chained, every candidate passes through all) | 10³–10⁴ × 1 × 1 | **the adversary**: every parked filter is resumed on the next candidate; any eager policy loses here; P-site must back off | memory is small anyway |
| `state`, `itersum`, `pingpong`, `scheduler` (10 workers) | 1–10 × 1 × 1–10 | pure switch time; compression must be invisible (≤ ε) | nothing about memory |
| `treesum 25` (generator over a depth-25 tree) | 1 × ≤25 × 1 | deep continuation resumed per node: lazy thaw and partial freeze | one continuation |
| `pi` (1 000 tasks × 50 yields, round-robin) | 10³ × 1 × 10³ | the regime where P-age/P-site should freeze between yields with no visible cost | fixed distance |
| `*_switch` variants | as above with `switch` | symmetric switching; **cannot run on Wizard SPC until COMPILER_DIFF §5.4 is fixed** | — |
| OCaml `multicore-effects` (`effect_throughput_*`, `rec_eff_*`, `algorithmic_differentiation`, `eratosthenes`) | mostly 1 × varies × 1 | one-shot tail / zero-shot (no parking); deep handler towers (`algorithmic_differentiation`); dynamic handler shapes | needs `wasm_of_ocaml` output hosted on Wizard first (WASI shim as a host module, `--ext:gc`, `try_table`); today they run only on the reference interpreter |
| OCaml `with_packages/test_sched` (`fork`/`yield` scheduler, `tasks_to_spawn` from argv) | `N` × small × `N` | **the OCaml park sweep already exists in embryo** — the one suite program whose `N` is a command-line parameter | same hosting prerequisite; WasmGC, so engine-stack only |
| `many_stacks*.wast` (999 parked in a table) | 10³ × 1 × ∞ | the existing regression for many live continuations; trivially extended to a sweep | no timing |
| `benchfx/micro/{suspend_resume, 2resumes_same_function}` | 1 × 1 × 1 | switch time | — |

Common gaps: none reports memory; `N` is fixed (or absent); depth is fixed; resume distance is
whatever the program happens to do; no program parks continuations for a *controlled* duration;
no program mixes hot and cold continuations deliberately. Those are the new benchmarks.

### 5.3 New benchmarks

All parameterized from the command line and printing a checked result (the suite convention);
each in the forms listed, so Wizard, Wasmtime, Asyncify and the reference interpreter can run the
same program. Pure-`.wat` forms follow `compiler-diff/pingpong.wat` (no C, no tables unless the
benchmark is about tables) and are assembled with the reference interpreter plus the opcode patch
from COMPILER_DIFF §2.2 until the toolchain catches up.

1. **`park-sweep` — the core artifact.** Create `N` continuations; run each to a suspension at
   recursion depth `d` with `v` live values per frame; park all of them; measure; resume all and
   check the sum. Axes: `N ∈ {10², 10³, 10⁴, 10⁵, 10⁶}`, `d ∈ {1, 4, 16, 64, 256}`, `v ∈ {2, 8, 32}`.
   Outputs: bytes/continuation (RSS and exact), VA, VMA count, time to park all, time to resume
   all, first wall. Forms: `.wat` (engine only, exact), fiber-c C (adds the shadow stack — the
   comparison with Wasmtime and Asyncify and the number the WasmFX paper reported), OCaml
   (`test_sched`-shaped, via `wasm_of_ocaml`). Expected curves: Wizard-as-is flat at ≈ 512 KiB VA
   and 8–16 KiB resident per continuation, wall at ≈ 21 800 (VMAs); R1 lowers VA; R2 lowers
   resident to 2 pages; R4 lowers to hundreds of bytes, linear in `d·v`.
2. **`resume-distance` — policy sensitivity.** `N` continuations in a ring; the resume order gives
   every continuation the same park distance `D ∈ {1, 10, 10², 10³, 10⁴}`. Output: time per
   switch vs `D` for each policy. P-eager should show its cost at `D = 1`; P-site should converge
   to zero overhead below `d*` and full memory above it. This is the benchmark `d*` is fitted on.
3. **`park-times` — a scheduler with a park-duration distribution.** Round-robin scheduler where
   a fraction `p` of tasks "block" for `T_long` and the rest for `T_short` (exponential or bimodal;
   emulates I/O waits). Outputs: throughput, RSS over time (memory-time product), freeze/thaw
   counts. This is where P-age thresholds and P-pressure are tuned and where the lazy default
   must recover most of P-eager's memory.
4. **`freeze-thaw-micro` — the cost model.** Freeze and thaw one continuation of depth `d` with `v`
   values per frame, `10⁵` times, for the naive, packed, and raw-payload representations; fit
   `a, b, c` of §4.2; measure the re-freeze reuse hit rate and allocation per cycle (must be ≈ 0
   in steady state). Also the instruction counts via gdb for the runtime routines.
5. **`deep-resume` — lazy thaw.** Park at depth `d ∈ {256, 1 024, 4 096}`; resume and touch `k`
   frames before suspending again, `k ∈ {1, 10, all}`. Output: thaw time vs `k`; with lazy thaw it
   must be ∝ `k`, with whole-stack thaw ∝ `d`.
6. **`hot-adversary`.** `pingpong`, `sieve`, `state` with each policy *forced on*. Output: the
   overhead ceiling per policy; the requirement is ≤ ε for the shipped default and "documented"
   for P-eager.
7. **`gc-interplay`.** `N` parked (live vs frozen) while the program allocates heavily (WasmGC
   arrays, or Virgil garbage induced through host calls). Output: GC count and time vs `N`;
   frozen stacks should scan as one `refs` array each. Second half: abandon `M` continuations
   (drop the table slot) and plot RSS over time — the "held until GC" curve, with and without
   P-gc.
8. **`cancel`.** Fibers finished by `resume_throw` (fiber-c's cancel path) and by abandonment;
   checks that frozen and live continuations are both reclaimed, and times `resume_throw` into a
   frozen continuation (thaw + unwind).
9. **`mixed-tiers`.** `park-sweep` under `--mode=dyn` and `--mode=lazy` so continuations contain
   interpreter *and* SPC frames (and OSR across a suspend); correctness first, cost second.
10. **`multi-shot`** (only if `cont.clone` is exposed): `nqueens`/`tree-explore` from
    `effect-handlers-bench`, ported to `.wat`; a bonus table, not a goal.
11. **Macro.** A server-shaped workload (waeio's HTTP server) needs WASI sockets in Wizard; out of
    scope for now — `c10m` and `park-times` stand in. Recorded as the known gap.

### 5.4 Systems, configurations, baselines

- **Wizard**, `--mode=spc` (and `jit`; `int` where SPC is broken), one flag per rung and policy:
  `--stack-pool-max=N`, `--stack-classes=…`, `--stack-trim=off|recycle|park:t`,
  `--stack-freeze=off|eager|age:k|gc|pressure|site`, `--freeze-partial=F,K`, `--freeze-repr=naive|packed|raw`.
  Every result table carries the rung and policy it was measured with, and the same table with
  each rung disabled (ablation).
- **Wizard `v3-int`** as the heap-frame bound (no fixed stacks at all; GOAL.md §4.6).
- **Wasmtime** as-is (`-W stack-switching`), with `-W async-stack-size` swept (64 KiB … 2 MiB);
  upstream never frees or pools continuations, so it characterizes "never reclaim" — and the
  first wall there is address space and the GC's unbounded `continuations` walk (GOAL.md §5).
- **Asyncify** (`wasm-opt --asyncify`, binaryen v124, fiber-c's `_asyncify` targets) — the
  no-native-stack baseline; **the hand-written state machine** (`benchfx/*/*_bespoke.c`) — the
  memory floor.
- **Literature anchors** in the tables, clearly marked as not measured here: Loom (a parked
  virtual thread in the hundreds of bytes), Go (2 KiB minimum, adaptive start), OCaml (32-word
  initial fiber), WasmFX 2023 (4 KiB fixed → 55.5 MB at 10 000).

### 5.5 Correctness and differential testing

- **Oracle.** Every new `.wast` is run on the reference interpreter (`wasm -i`) with
  `assert_return`s (as `compiler-diff/pingpong.wast`); the C forms check their own results.
- **Differential.** `--mode=int` vs `spc` vs each policy must agree on every benchmark's result.
- **P-eager as a test mode.** Run the whole `test/regress/ext:stack-switching/` suite (and the
  spec tests) with `--stack-freeze=eager`, so every continuation in every test round-trips through
  freeze and thaw; then with `--freeze-partial` forced small so lazy thaw and the underflow stub
  are exercised; then with a randomized freeze schedule (freeze every *k*-th suspend for random
  *k*) to catch order-dependent bugs.
- **GC stress.** The interpreter already crashes when a collection happens inside
  `runtime_handle_switch` (COMPILER_DIFF §5.5); compression adds allocations at exactly that
  point. Run the suite with a forced-GC-every-*n*-allocations mode (Virgil's runtime can be
  built with a GC-stress redefinition) before and after each rung.
- **Unit level.** PR #647's `X86_64CompressionTest.v3` and `CompressionTest.v3` remain the
  round-trip tests for the reader/writer and strategies; add cases for the raw-payload
  representation, the underflow stub, and freezing under each `StackState`.

### 5.6 Method

From lit-review 02 §3 (Gaißert et al.'s protocol), applied as in COMPILER_DIFF: engines pinned to
commit hashes; one correctness run first; failures reported as `≡` (overflow), `OOM`, `VMA`, `—`
(unimplemented) rather than dropped; ≥ 20 runs or ≥ 6 s with one warm-up, arithmetic mean and
relative standard deviation; whole-process measurement with the contents stated (module load
and compilation included, AOT excluded); geomeans only over benchmarks every system ran; every
optimization also reported disabled; negative results kept. Memory and time in separate tables,
never combined into one score. Machine, kernel (WSL2: no performance counters,
`vm.overcommit_memory` recorded because it decides whether `mmap` fails or the OOM killer acts),
and `vm.max_map_count` stated. The reference interpreter is the semantics oracle only — its
switch costs ≈ 1 900× native and its clock is fictional (`RUNNING.md`).

### 5.7 Milestones and success criteria

| Milestone | Deliverable | Success criteria (numbers to beat, measured on `park-sweep` unless noted) |
|---|---|---|
| **M0** | R0 accounting + `park-sweep` in all three forms + the Wizard-as-is / Wasmtime / Asyncify / bespoke table | a bytes-per-suspended-continuation table with `N` and `d` swept — publishable on its own (lit-review 06 §4.1) |
| **M1** | R1 + R2 | at `N = 10⁴, d = 1`: ≤ 8 KiB resident and ≤ 64 KiB VA per parked continuation; `c10m` RSS within 2× of the bespoke state machine; ≤ 5 % time overhead on `state`, `sieve`, `pingpong`; wall moves from ≈ 21 800 to ≥ 10⁵ (VMAs) |
| **M2** | R4 eager (correctness mode) | ≤ 512 B per parked continuation at `d = 1, v ≤ 8`; ≤ 4 KiB at `d = 16`; the regress suite green under P-eager, random schedules, and GC stress; the time overhead of P-eager *measured and published* (the ablation) |
| **M3** | R4 with the lazy default (§4.5) | ≥ 90 % of M2's memory on `park-sweep` at `D ≥ 100`; ≤ 10 % time overhead at `D = 1` on `resume-distance` and ≤ 5 % on the hot adversaries; steady-state allocation rate per switch ≈ 0 |
| **M4** | Lazy thaw, partial freeze, chunk reuse | `deep-resume` thaw time ∝ frames touched; `treesum 25` and `algorithmic_differentiation` within 10 % of no-compression time with memory at M2 levels |
| **Stretch** | | 10⁶ parked continuations at `d = 4` in < 1 GiB — under 1 KiB each — the "millions of suspended coroutines" bar V8 set for JSPI |

---

## 6. Risks and open questions

- **Allocation on the switch path is already a crash.** The interpreter's GC failure under switch
  pressure (COMPILER_DIFF §5.5) means Wizard's native-frame root maps are fragile exactly where
  compression would allocate; it must be root-caused before P-eager can be trusted, and it argues
  for the byte-level (allocation-free) freeze path early rather than late.
- **The SPC crash on fiber-c's switch module** (COMPILER_DIFF §5.4) blocks the `*_switch`
  benchmarks on the compiler tier.
- **Absolute pointers held outside the stack**: `FrameAccessor`s (probes, debugger, `whamm`)
  cache `sfp`s; a freeze must invalidate them (or refuse while any exists). The frame walk must
  also refuse a stack containing host frames — Loom's pinning rule.
- **Mixed tiers and OSR** (GOAL.md §4.6): both frame kinds are re-materialized by the PR, but
  OSR *during* a thaw (a tiered-up function whose interpreter frame is being rebuilt) is a
  corner that benchmark 9 exists to hit.
- **The time-side plan changes the hooks.** COMPILER_DIFF §7 moves `suspend`/`switch` inline; the
  policy above is designed so that its hot-path footprint is bookkeeping plus one `frozen` test,
  and its sweeps live in GC and pool refill — but the parked-list push/pop then has to be emitted
  inline too (a few stores).
- **Sizing by profile can be wrong in both directions**; R1 without R3/R4's relocating grow turns
  a wrong small class into a trap. Ship R1 only with a grow path.
- **WSL2 measurement limits**: no hardware counters; memory numbers depend on the VM's
  overcommit setting; report both settings tried.
- **The shadow stack** stays out of scope; the C-sourced benchmarks (fiber-c, `c10m`) will show
  an engine-stack result *plus* an unchanged linear-memory region per fiber, and the OCaml/WasmGC
  benchmarks show the engine result alone. Say which is which in every table (GOAL.md §11).
- **What the producer could tell us** — a stack-size hint at the proposal level (lit-review 06
  §2d) — would make R1 exact for compiled generators and async functions. If R1 turns out to
  close most of the gap, the interesting result may be a proposal-level hint, and the plan should
  be ready to say so.

---

## 7. Sources

Primary sources read for this plan (beyond the lit-review notes, whose bibliography is
[`../lit-review/bibliography.md`](../lit-review/bibliography.md)):

- OpenJDK, `src/hotspot/share/runtime/continuationFreezeThaw.cpp` (master, 2026): freeze fast/slow
  paths, chunk reuse, `threshold = 500` words, return barrier, the "~100-150ns" budget.
  <https://github.com/openjdk/jdk/blob/master/src/hotspot/share/runtime/continuationFreezeThaw.cpp>
  JEP 444, *Virtual Threads* (stack chunks in the heap; pinning) <https://openjdk.org/jeps/444>;
  a third-party per-thread measurement (≈ 750 B, blog, low confidence) is cited only as an order
  of magnitude.
- Go, `src/runtime/stack.go` (master, 2026): `stackMin`, `gcComputeStartingStackSize`,
  `shrinkstack`, `newstack`; Go 1.19 release notes on adaptive initial stacks.
  <https://github.com/golang/go/blob/master/src/runtime/stack.go> · <https://go.dev/doc/go1.19>
- OCaml multicore design notes (`caml_fiber_wsz` = 32 words, doubling, cached buckets).
  <https://github.com/ocaml-multicore/docs/blob/main/ocaml_5_design.md>
- libmprompt, `include/mprompt.h` (`mp_config_t`) and README.
  <https://github.com/koka-lang/libmprompt>
- Yu, *Evaluate the Stack Management in Effect Handlers using the libseff C Library*, Edinburgh,
  Nov 2025 — Tables 4.1–4.3 and §5.1. <https://arxiv.org/abs/2512.03083>
- Farvardin & Reppy, *From Folklore to Fact*, PLDI 2020 — §4.1, §5 parameters, Table 3, §6.
  <https://kavon.farvard.in/papers/pldi20-stacks.pdf>
- Alvarez-Picallo, Freund, Ghica, Lindley, *Effect Handlers for C via Coroutines*, OOPSLA 2024
  (hot split, segment recycling) — via lit-review 05.
- Phipps-Costin et al., *Continuing WebAssembly with Effect Handlers*, OOPSLA 2023 (55.5 vs 13.4 MB).
  <https://arxiv.org/abs/2308.08347>
- V8, *WebAssembly JSPI has a new API* (growable/segmented stacks, "millions of suspended
  coroutines") <https://v8.dev/blog/jspi-newapi>; V8 commit `8b1017f6` "[wasm][arm64] Growable
  stacks for Turboshaft" <https://chromium.googlesource.com/v8/v8/+/8b1017f685a9cbd1abd9900a1c87ee9fe6b68fd9>
- Folly fibers README (`recordStackEvery`, guard pages).
  <https://github.com/facebook/folly/blob/main/folly/fibers/README.md>
- Muhcu, Schuster, Steuwer, Brachthäuser, *Multiple Resumptions and Local Mutable State, Directly*,
  ICFP 2025 (stable prompts, refcount-1 in place) — via lit-review 01 §5.
- Ma, Jung, Zhang, *Virtualizing Continuations*, PLDI 2026 (virtual handler IDs; `resume` copies,
  `resume_final` does not). <https://dl.acm.org/doi/10.1145/3808289> · artifact
  <https://zenodo.org/records/19003477>
- Wasmtime tracking issue #10248 (continuation deallocation and pooling still open, no 2026
  activity). <https://github.com/bytecodealliance/wasmtime/issues/10248>
- Wizard PRs: #647 *x86-64 Stack Compression* (open), #625 *Platform-independent compression*,
  #623 *Stack hierarchy + continuation mode helper*, #611/#551 (closed drafts).
  <https://github.com/titzer/wizard-engine/pulls?q=compression>
- Hieb, Dybvig & Bruggeman 1990; Bruggeman, Waddell & Dybvig 1996 (segments, underflow frames,
  one-shot) — via lit-review 01 §6.
- This repo: [`GOAL.md`](GOAL.md), [`COMPILER_DIFF.md`](COMPILER_DIFF.md), [`../lit-review/`](../lit-review/),
  `wizard-engine/src/engine/compression/`, `wizard-engine/src/engine/x86-64/X86_64Stack.v3`,
  `wizard-engine/test/regress/ext:stack-switching/many_stacks*.wast`, `fiber-c/examples/`,
  `benches/with_packages/test_sched/`, `~/workspace/benchfx/` (bespoke baselines, harness).
