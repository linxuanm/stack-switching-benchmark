# Where Wizard's time goes on the fiber-c benchmarks, vs Wasmtime

**Version 1 — 2026-08-31.** A profiling study of the fiber-c rows of the microbenchmark harness
(`../run-wizard.sh` / `../run-wasmtime.sh`), asking one question: **which parts of Wizard consume
the time that makes it 3–13× slower than Wasmtime on these workloads?** Engines and modules as
pinned before (Wizard `4a539337` SPC via `--mode=jit`, Wasmtime `d8a0da6d66` Cranelift; modules
from `microbench/wasm/`, built by `../build-all.sh`). Raw profiles, JIT address maps, the sample
bucketing script, and strace outputs are in [`fiber-c-compare/`](fiber-c-compare/). Companions:
[`COMPILER_DIFF.md`](COMPILER_DIFF.md) is the instruction-level view of the same gap;
[`COMPRESSION_PLAN.md`](COMPRESSION_PLAN.md) §4.2 consumes these numbers.

**Host caveat.** This is WSL2 (kernel 6.18.33.2-microsoft-standard-WSL2): no hardware PMU, so all
profiles are **software `cpu-clock` sampling at 999 Hz** (the kernel-versioned perf wrapper is
broken; `/usr/lib/linux-tools-5.15.0-190/perf` works). Cycle/instruction/branch counters are
unavailable; sampling attributes wall-clock CPU time only. Absolute times swing up to ~1.9×
*between sessions* on this host (e.g. `state` on Wizard: 4.5–5.2 s in this session's back-to-back
runs vs 8.6–9.6 s in an earlier one — Wasmtime swings in proportion), so **every table below is
from back-to-back runs in one session, and the Wizard/Wasmtime ratios are the stable quantity**,
as expected for relative comparison.

---

## 1. The numbers being explained

Back-to-back single runs (`/usr/bin/time`), this session. "Pair" = one `suspend` + the `resume`
that answers it, the unit both engines execute once per `fiber_yield`.

| Benchmark | Switch pairs | Wasmtime | Wizard | ratio | ns/pair (Wt → Wz) | minor faults (Wt → Wz) | peak RSS (Wt → Wz) |
|---|---|---|---|---|---|---|---|
| `itersum 5M` | 5.0 M | 0.07 s | 0.88–0.99 s | **≈13×** | 14 → 184 | 904 → 137 259 | 18.7 MB → 550 MB |
| `state` (10 M get/put loop) | 30 M | 0.42 s | 4.5–5.2 s | **≈12×** | 14 → 166 | 880 → 179 319 | 17.7 MB → 719 MB |
| `treesum 4` (2²⁵ leaf yields + tree recursion) | 33.5 M | 1.08 s | 5.6–6.4 s | **≈5.7×** | 32 → 185 | 901 → 179 322 | 18.9 MB → 718 MB |
| `c10m` (10 M conns: 2 resumes + 1 yield + 1 fiber_alloc each) | 10 M conns | FAIL (ENOMEM after ≈32.7 k `cont.new`, 0.30 s) | 6.9 s (this session) | — | — → ≈690/conn | — → 338 802 | — → 926 MB |
| `sieve 2000` (2 000 filter fibers; every candidate walks the chain until a divisor) | 2.04 M | 0.07–0.11 s | 0.45–0.61 s | **≈6×** | ≈40 → ≈245 | 6 708 → 64 423 | 41.5 MB → 259 MB |
| `skynet` (1.11 M fibers: alloc + resume each; the 1 M leaves also yield + resume) | 1.0 M (+1.11 M fiber_alloc) | FAIL (ENOMEM after ≈32.7 k `cont.new`, 0.21 s) | 0.45–0.51 s | — | — → ≈430/fiber | — → 99 384 | — → 399 MB |

Two immediate observations before any profile: Wizard's per-pair cost is **165–185 ns across
three very different benchmarks** (the switch machinery is a constant tax, matching
COMPILER_DIFF §3's 179 ns; `sieve`'s ≈245 ns also carries a division and two table lookups in
C per hop, plus startup on a 0.5 s run), and Wizard takes **10–375× more page faults and
~6–40× more memory** — the switch path allocates.

Notes on the rows:

- `sieve 2000`'s pair count is exact: 2 042 625 resume/yield hops for the 2 000 primes up to
  17 389 (a candidate visits filters until one divides it), plus 2 000 final resumes that let
  the filters return. Both engines print the same 10 575-byte prime list. The harness's `sieve
  500` (≈2.8×) is startup-dominated: 0.03 s vs 0.09 s.
- `skynet` creates Σ₁⁶ 10ᵏ = 1 111 110 fibers with at most six alive; only the 10⁶ leaves
  yield. Wizard's ≈430 ns/fiber covers `fiber_alloc` + resume (+ yield + resume for leaves) +
  `fiber_free`, at a steady 399 MB / 99 384 faults for the 0.47 s run.
- **Wasmtime's `Cannot allocate memory (os error 12)` on `skynet` and `c10m` is the mapping
  count, not RAM.** Every `cont.new` `mmap`s 2 MiB + 4 KiB (`PROT_NONE`, then `mprotect` the
  2 MiB `RW`), so each stack is two VMAs, and `Store::allocate_continuation` keeps them all until
  the store drops. `strace` shows the 32 702nd stack `mmap` failing: 2 × 32 702 + ~120 base
  mappings = `vm.max_map_count` (65 530 on this host). `skynet` dies at 0.21 s / 161 MB and
  `c10m` at 0.30 s / 281 MB, both far from memory pressure; a smaller `async-stack-size` cannot
  help. Both would run once returned stacks are unmapped or pooled (`lit-review/04-runtimes.md`
  Part II; the async-fiber stack pool one directory over is the obvious donor).

## 2. Method

- **Record**: `perf record -e cpu-clock -F 999 -- <engine> <module> <args>`; whole process
  (startup + compile included; they are noise at these run lengths except for `sieve`/`skynet`).
- **Wizard symbolization**: the `wizeng` ELF has full symbols. Two regions do not: the
  pregenerated interpreter/stub region inside the binary (bounded by the `code start`/`code end`
  addresses that `-tk` prints, with per-stub ranges) and the SPC JIT region (per-function ranges
  from `-tk`'s `func[N].target_code` lines; addresses are deterministic under `setarch x86_64 -R`,
  which the profiled runs also use). `fiber-c-compare/bucket-samples.py` classifies every sample
  by address: ELF symbol, `pregen: <stub>`, `jit: wasm func[N]`, or kernel.
- **Wasmtime symbolization**: `wasmtime run --profile perfmap` (perf reads `/tmp/perf-<pid>.map`
  and names JIT frames `wasm[0]::function[N]`); function names recovered from the modules'
  function section.
- **Sample counts**: state 4 862, treesum 6 059, c10m 7 125; itersum 930, sieve 469, skynet 503 —
  the last three carry ±1–2 pp per row.
- **Syscall profile**: `strace -c` per engine/benchmark; **fault/RSS**: `/usr/bin/time`.

## 3. Where Wizard's time goes

Exact cluster totals over all samples (not just top rows; per-symbol tables in
`fiber-c-compare/wizard-profile-*.txt`):

| Cluster (what it is) | itersum | state | treesum | c10m | sieve | skynet |
|---|---|---|---|---|---|---|
| **wasm JIT code** (SPC output, incl. the inline `resume` sequence) | 18.0 % | 21.7 % | 30.7 % | 44.5 % | 35.4 % | 27.6 % |
| **pc/handler lookup** (`lookupPc`, `Vector<(int, List<FuncLoc>)>.[]`, `findHandler`, `lookupTopPc`, `findUserCode`, `computePcFromCode`, frame handles) | 20.8 % | 23.3 % | 21.1 % | 13.0 % | 17.7 % | 9.7 % |
| **value marshalling** (`X86_64Stack.pop/push/popN/pushN/storeValue/popb32/peekTag` — tagged 32-byte slots ↔ `Value` objects) | 19.2 % | 17.7 % | 18.1 % | 12.5 % | 16.2 % | 22.5 % |
| **suspend/resume driver** (`runtime_handle_suspend`, `tryHandleSuspension`, `redirectToHandlerStub`, `Runtime.TABLE_SET/GET`, `CONT_NEW/BIND`) | 13.3 % | 18.3 % | 13.6 % | 10.5 % | 12.2 % | 15.9 % |
| **GC + allocator** (`.alloc`, `RiGc.memClear` = semispace zeroing) | 2.3 % | 12.0 % | 10.1 % | 9.8 % | 1.7 % | 2.0 % |
| **kernel: memory mgmt** (`clear_page_erms`, fault handling, `_raw_spin_lock`, …) | 19.7 % | 2.5 % | 2.5 % | 3.8 % | 9.4 % | 13.3 % |
| pregen stubs (return-parent / enter-func) | 0.0 % | 0.0 % | 0.0 % | 1.9 % | 0.0 % | 4.2 % |
| kernel: other, misc Virgil, other | 6.8 % | 4.5 % | 3.9 % | 3.9 % | 7.5 % | 4.8 % |

Reading it row by row:

1. **Only 18–45 % of Wizard's time executes compiled wasm code.** The rest — 55–82 % — services
   the switching. On the pure switch benchmarks (`itersum`, `state`) the Virgil runtime alone
   (rows 2–4) is 52–59 % of everything.
2. **The single largest runtime cost is finding where to deliver the suspension** (row 2,
   ≈10–23 %): recovering the parent's bytecode `pc` from a return address
   (`X86_64SpcModuleCode.lookupPc` + its `Vector<(int, List<FuncLoc>)>.[]` search are the top two
   runtime symbols in `state` and `treesum`) and then linearly scanning the function's handler
   table (`FuncDecl.findHandler`). This is the profile-level confirmation of COMPILER_DIFF §7.1,
   where the same machinery was 646 of the 1 563 instructions of one suspend.
3. **Value marshalling is nearly as large** (row 3, ≈13–23 %): every payload crosses the
   suspend/resume boundary by popping tagged 32-byte slots into boxed `Value`s
   (`Array<Value>` per hop) and pushing them back out (`storeValue`). `skynet`, which passes
   boxed u64s through `cont.bind`, is worst at 22.5 %.
4. **The driver itself** (row 4, ≈10–18 %) is the remaining body of `runtime_handle_suspend`,
   the return-address rewrite (`redirectToHandlerStub`), and — noteworthy — `Runtime.TABLE_SET`
   / `TABLE_GET` at 1–2 % each: **the continuation table accesses in the fiber-c shim are runtime
   calls in SPC**, where Cranelift compiles them inline.
5. **Rows 5–6 are the same story seen twice — the switch path allocates.**
   `X86_64Stack.popN` allocates an `Array<Value>` per suspension (plus boxed values), so the
   Virgil semispace heap churns: `.alloc` + `RiGc.memClear` (zeroing the to-space after every
   collection) cost up to 12 % in user time, and the kernel pays again in `clear_page_erms` /
   fault handling for the freshly-touched heap pages — 137 k–339 k minor faults per run and
   0.55–0.93 GB RSS where Wasmtime takes ~900 faults and 18 MB. Which of the two rows it lands in
   depends on run length (short runs fault more per second: `itersum` 19.7 % kernel-mm); the sum
   is a steady **12–22 % across every benchmark**.
6. **Syscalls are *not* the story**: strace shows Wizard steady-state makes essentially none
   (`itersum`: 32 mmap + 18 mprotect total). Even `c10m` — 10 M fiber_allocs — does only
   10 032 mmaps and 26 396 mprotects (the stack pool works; ~1 mmap per live stack, then reuse).
   Wizard's kernel time is page faults from heap growth, not calls.
7. **c10m/skynet add the creation path**: `CONT_BIND`/`CONT_NEW` runtime calls (1–4 %), the
   return-parent stub (1.9–4.2 % — every finished fiber crosses it), and `fromCode`/`computePc`
   lookups for the entry trampoline. Still, even the creation-heavy c10m is 55 % non-wasm time.

## 4. Where Wasmtime's time goes

`perf report` with perfmap (files `fiber-c-compare/wasmtime-profile-*.txt`):

| Benchmark | JIT share | Top functions |
|---|---|---|
| `itersum` | 87.5 % | `wasmfx_indexed_resume` 69 %, unnamed C fiber body 14 %, `_start` (driver loop) 5 % |
| `state` | 99.3 % | `wasmfx_indexed_resume` 70 %, unnamed C body 21 %, `_start` 8 % |
| `treesum` | 99.6 % | `walk_tree` recursion 41 %, `wasmfx_indexed_resume` 41 %, `_start` 17 % |
| `sieve` | 69 %* | `wasmfx_indexed_resume` 38 %, C body 28 % (*short run: startup/compile and kernel dominate the remainder) |

There is no runtime row to show: **everything a switch needs — handler search, payload
transfer, state updates, the stack switch itself — is inline in `wasmfx_indexed_resume` and
`wasmfx_suspend`'s compiled code** (COMPILER_DIFF §4.2), and nothing on the path allocates.
The `resume` side carrying ~70 % vs the suspend side's C body is consistent with resume's
larger inline sequence (≈100–120 instructions vs ≈50).

## 5. Cross-checks

- **Per-op reconciliation.** Wizard 166–185 ns/pair here; COMPILER_DIFF measured 179 ns/pair on
  `itersum` and counted 1 563 + ~80 instructions per suspend + resume. At this host's ~4–5 GHz
  that is ~2.5 IPC — plausible for pointer-chasing runtime code. The clusters also match the
  instruction breakdown: lookup 41 % of the runtime instructions there vs lookup ≈ 35–40 % of
  runtime samples here.
- **JIT-vs-JIT.** Scaling each engine's JIT-cluster share by its wall time: `itersum`
  0.93 s × 18 % ≈ 167 ms (Wizard) vs 0.07 s × 87.5 % ≈ 61 ms (Wasmtime) → **≈2.7×**; `state`
  1.08 s vs 0.42 s → **≈2.6×**; `treesum` 1.90 s vs 1.08 s → **≈1.8×**. So even if the runtime
  cost vanished entirely, SPC's code quality alone leaves Wizard ~2–2.7× behind Cranelift on
  these modules (single-pass codegen, everything-spilled call boundaries, runtime-call table
  ops — visible in COMPILER_DIFF §4.1's listings).
- **Gap tracks switch density.** `state` (3 yields per loop iteration, no other work) 12×;
  `itersum` 13×; `treesum` (a real recursion between yields) 5.7×; `sieve` (arithmetic per
  filter hop) ≈2.8×. Dilute the switches with real work and the runtime tax shrinks — the same
  effect the WasmFX literature reports for Asyncify.

## 6. Findings

1. Wizard loses the fiber-c comparison **in its runtime, not in the stack switch**: 52–59 % of
   pure-switch benchmark time is the Virgil runtime servicing `suspend`/`resume`, split
   remarkably evenly across (a) pc/handler lookup ≈20–23 %, (b) tagged-slot ↔ `Value`
   marshalling ≈18–19 %, (c) the driver + runtime-call table ops ≈13–18 %.
2. A further **12–22 % is allocation fallout** (semispace alloc + zeroing + kernel page-fault
   work), caused by per-suspension `Array<Value>` payloads — corroborated by 137 k–339 k minor
   faults and ~0.5–0.9 GB RSS per run vs Wasmtime's ~900 and 18 MB.
3. Compiled wasm code is a minority of Wizard's time (18–45 %) and is itself **≈2–2.7× slower**
   than Cranelift's on the same functions.
4. Wasmtime spends **87–99.6 % of its time in jitted wasm code**; its design leaves nothing else
   to measure on this suite.
5. Syscalls and the stack pool are non-issues in both engines; Wizard's pooling works
   (10 k mmaps for 10 M fibers on `c10m`).
6. All of this is consistent with, and quantitatively predicted by, the instruction-level
   analysis in COMPILER_DIFF — the profile adds the weights: lookup ≥ marshalling > driver >
   GC ≈ codegen quality.

## 7. Reproduction

```bash
P=/usr/lib/linux-tools-5.15.0-190/perf     # the /usr/bin/perf wrapper is broken on this kernel
WZ="wizard-engine/bin/wizeng.x86-64-linux --ext:all --stack-size=65536 --mode=jit"
WT="wasmtime/target/release/wasmtime run --profile perfmap -W=exceptions,function-references,gc,stack-switching,tail-call"

# address map for JIT bucketing (deterministic with ASLR off), then record + bucket
setarch x86_64 -R timeout 5 $WZ -tk --colors=false microbench/wasm/state_wasmfx.wasm 2>/dev/null \
  | grep -E "target_code|: *(break \*)?0x0" > map-state.txt
setarch x86_64 -R $P record -e cpu-clock -F 999 -o wz.data -- $WZ microbench/wasm/state_wasmfx.wasm
$P script -i wz.data -F ip,sym,dso | python3 research/fiber-c-compare/bucket-samples.py map-state.txt

$P record -e cpu-clock -F 999 -o wt.data -- $WT microbench/wasm/state_wasmfx.wasm
$P report -i wt.data --stdio                # perfmap names the wasm functions

strace -c -f -o st.txt $WZ microbench/wasm/state_wasmfx.wasm
/usr/bin/time -f "%es minor=%R major=%F rss=%MKB" $WZ microbench/wasm/state_wasmfx.wasm
```

---

## 8. Speculation: how Wizard could close the gap (V2 addition)

Grounded in §3's cluster table — each idea names the cluster it attacks and what removing that
cluster is worth on the pure-switch benchmarks (`itersum`/`state`, the 12–13× rows). Mechanism
details live in COMPILER_DIFF §7 and COMPRESSION_PLAN §3–4; this section is the
profile-weighted ordering of that work.

1. **Resume-site handler tables — kill the lookup cluster (worth ≈20–23 %).** The largest
   runtime cost is reconstructing, on every suspension, information the resume site knew at
   compile time: `lookupPc` + its `Vector` search recover the parent's bytecode pc from a return
   address, and `findHandler` linearly scans for the tag. If SPC's `resume` publishes a static
   per-site handler table (tag → handler-stub address) on the stack object — one store — the
   suspend path reads it directly and the entire cluster (`lookupPc`, `Vector<…FuncLoc>.[]`,
   `findHandler`, `lookupTopPc`, `findUserCode`, `computePcFromCode`, most frame-handle work)
   disappears from the hot path. COMPILER_DIFF §7.3 sketches the mechanism; the profile says it
   is the single highest-leverage change.
2. **Allocation-free payload transfer — kill marshalling *and* the memory fallout (worth
   ≈30–40 % combined).** Value marshalling (≈18–23 %) is `popN`/`pushN`/`storeValue` boxing
   tagged slots into fresh `Array<Value>`s; the GC + kernel-memory rows (≈12–22 %) are the
   *consequence* of those allocations (semispace growth, `RiGc.memClear` zeroing, 137 k–339 k
   page faults, 0.5–0.9 GB heaps). Copying payloads slot-to-slot between the two tagged value
   stacks — the six-instruction-per-value loop the inline `resume` already uses
   (`emit_value_copy`) — eliminates both rows at once and, as a bonus, removes the allocation
   that crashes the interpreter's GC under switch pressure (COMPILER_DIFF §5.5). This is the
   best ratio of effort to profile weight: it is runtime-only surgery, no codegen changes.
3. **Inline the suspend/switch driver (worth ≈10–18 %, more later).** What remains of
   `runtime_handle_suspend` after 1–2 — state flips, chain splice, the return-address rewrite —
   is ~30 instructions of work behind a spill-everything runtime call. Emitting it inline in SPC
   (COMPILER_DIFF §7.4, with the current runtime kept as the mixed-tier fallback) removes the
   driver row and the call-boundary spills. Include the two small companions the profile
   surfaced: inline `table.get`/`table.set` (the fiber-c shim pays `Runtime.TABLE_SET/GET`
   runtime calls of 1.5–2.5 % that Cranelift compiles to a few instructions), and a cheaper
   creation path for `c10m`/`skynet` (`CONT_NEW`/`CONT_BIND` runtime calls plus lazy stack
   allocation, COMPRESSION_PLAN §3.2).
4. **Codegen quality is the floor (≈2–2.7×), and it is a different project.** Stacking 1–3 on
   `state` removes ≈73 % of the time (23.3 lookup + 17.7 marshalling + 14.5 memory + 18.3
   driver), a ≈3.7× speedup — taking the gap from ≈12× to ≈3×. What remains is §5's JIT-vs-JIT
   ratio: SPC's single-pass output (everything spilled at block boundaries and calls, no
   regalloc across expressions, runtime calls for slow ops) against Cranelift's optimizing
   pipeline. Closing *that* means either an optimizing tier or targeted SPC improvements
   (keeping hot locals in registers across suspension-free regions, shrinking the 32-byte
   tagged-slot traffic); realistically Wizard matches Wasmtime on switch-heavy code only when
   the switch cost is small enough that the remaining 2× on straight-line code is diluted —
   which is exactly where `sieve` (2.8×) already sits.
5. **How to verify**: this profile setup is the harness — re-run `perf record` + the bucketer
   after each stage and watch the targeted cluster vanish; the per-pair ns in §1 (184 → target
   <40 with 1–3) and the fault counts (137 k → ~1 k with 2) are the acceptance numbers, with
   `state`/`itersum` as the sensitive workloads and `sieve`/`treesum` guarding against
   regressions in compute-dominated code.

Ordering by measured weight: **2 first** (biggest combined share, least invasive, fixes a
correctness bug too), then **1**, then **3**, with **4** as the long-term tier question. This
matches COMPILER_DIFF §7's staging, now with the profile as evidence that the staged wins are
additive and sum to most of the gap.
