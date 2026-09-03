# `resume` / `suspend` / `switch` in the compiler tiers: Wizard SPC vs Wasmtime Cranelift

**Version 2 — 2026-08-31.** V1 (§0–6) was checked by an independent verification pass against the
pinned sources and the raw listings (108 claims; 13 wrong or imprecise, all corrected — §8);
V2 adds §7 (adapting Wizard) and §8. Scope: the **compiler tier only** — Wizard's single-pass compiler
(`--mode=spc` / `--mode=jit`, `dependencies/wizard-engine/src/engine/compiler/SinglePassCompiler.v3` +
`src/engine/x86-64/`) against Wasmtime's Cranelift backend (the only Wasmtime tier that
implements stack switching; Winch and Pulley do not). Interpreter tiers are out of scope except
where a bug forced a fallback. Pinned submodules: Wizard `4a539337`, Wasmtime `d8a0da6d66`.
Every `path:line` was checked at those commits. Machine: i9-13900H, WSL2 (kernel
6.18.33.2-microsoft-standard-WSL2), Rust 1.98.0 (installed as a named toolchain for the Wasmtime
build), Virgil at `~/workspace/virgil`.

Rationale (from the task): Wizard is significantly slower than Wasmtime on the stack-switching
benchmarks. This document asks *why*, at the level of the x86-64 instructions each compiler emits
for the three switching opcodes, on one workload that contains all three.

Companion material: raw listings, the scripts used, and the distilled workload are in
[`compiler-diff/`](compiler-diff/). Background on both runtimes:
[`../lit-review/04-runtimes.md`](../lit-review/04-runtimes.md); Wizard's stack object and pool:
[`GOAL.md`](GOAL.md) §4.

---

## 0. The answer in one screen

Both engines give each continuation its own native stack and switch by exchanging `rsp`. The
exchange itself costs about the same in both. **Everything around the exchange is different**:

| | Wizard SPC | Wasmtime Cranelift |
|---|---|---|
| `resume` | **Inline**, ≈55 instructions + 6 per transferred value. Null/version check, copy the arguments between two *tagged* value stacks (32-byte slots), write 3 state words + 2 links, `mov rsp,[stack.rsp]; pop; jmp`. | **Inline**, ≈100–120 instructions before the switch, ≈30 after. Fat-pointer decode, revision check, store args into the callee's payload buffer, splice chains, save/restore 4 "stack limit" words each way, install the handler list, 10-instruction `stack_switch`, then `brif`/`br_table` dispatch. |
| `suspend` | **Runtime call.** ≈26 instructions of JIT code (spill *all* live slots + tags, store `vsp`/`rsp` into the stack object, call `X86_64Runtime.runtime_handle_suspend`, then a 6-instruction stub switches `rsp`). The Virgil runtime executes **1 563–1 840 instructions** per call (measured): allocates an `Array<Value>` for the payload, walks the parent chain, linearly scans the parent's handler table, rewrites the parent's return address to a handler stub, pushes payload + continuation onto the parent's value stack. | **Inline**, ≈51 instructions + 7 after: handler search is an inline loop over the parent chain and each parent's handler list, payload goes into a stack slot of the suspender's own frame, `stack_switch` through the last ancestor's control context. No runtime call, no allocation. |
| `switch` | **Runtime call.** ≈27 instructions of JIT code + **1 601 instructions** in `runtime_handle_switch` (measured). | **Inline**, ≈140 instructions + 14 after. Includes two 14-instruction fat-pointer (i128) shuffles and a 3-word control-context copy through a temporary stack slot. |
| `cont.new` | Runtime call, **516 instructions** (measured), stack from an 8-deep pool. | Libcall `cont_new` → `allocate_continuation`: `mmap` 2 MiB + guard, `mprotect`, `Box` — no pool, never freed. Not on the hot path of these benchmarks. |
| Continuation value | 16 bytes `(X86_64Stack*, version)` in an XMM register / 32-byte tagged slot | 16 bytes `(revision << 64) \| VMContRef*` as a CLIF `i128` |
| Where handler dispatch happens | Runtime rewrites the resumer's return address to a per-handler stub emitted at the end of the resumer's function | Suspender computes the handler index; resumer does one `br_table` |

Measured on this machine (§3): a `resume`+`suspend` round trip (fiber-c `itersum`) costs
**14.4 ns on Wasmtime and 179 ns on Wizard SPC (12.4×)**; a pair of `switch`es (`pingpong`)
costs **12.2 ns vs 233 ns (19×)**. The runtime-call boundary — spill everything, call Virgil,
allocate, scan, rewrite return addresses, then un-spill — is where Wizard's time goes; the
`rsp` swap is not the problem.

Four toolchain/engine problems had to be worked around to run the workload at all (§5): the
reference interpreter and binaryen still emit the *old* opcode numbers (`switch` = `0xE5`),
Wizard's validator reads `resume_throw`'s immediates in the wrong order, `wasm-opt -O2` asserts
on any module containing `switch`, and Wizard's SPC crashes on the fiber-c switch module (the
interpreter runs it) — so the switch timing on Wizard comes from a distilled 60-line `.wat` with
the same shape, verified against the reference interpreter.

---

## 1. How each compiler lowers the three instructions

### 1.1 Common ground

Both engines: one native stack per continuation, allocated at `cont.new`; the running stack is
found through a global (`X86_64Runtime.curStack`, an absolute address in Wizard;
`VMStoreContext.stack_chain` behind `vmctx+8` in Wasmtime); a continuation value carries a
counter so that consuming it twice traps (`version` in Wizard, `revision` in Wasmtime); the
counter is compared and incremented at `resume` and `switch`. Both are asymmetric at the Wasm
level and both implement `switch` by splicing the target's chain under the handler stack.

### 1.2 Wizard SPC

**Execution model.** SPC compiles one function at a time into code that keeps the Wasm operand
stack on a separate, *tagged* value stack (32-byte slots: tag byte at +0, payload at +16 —
`Tagging(tagged=true, simd=true)`, `src/engine/x86-64/X86_64Target.v3:21`) and a 104-byte native
frame per call (`src/engine/x86-64/X86_64Frames.v3:26-41`; slots used here: `+8 mem0_base`,
`+16 vfp`, `+24 vsp`, `+80 instance`, `+88 curpc`). Fixed registers
(`src/engine/x86-64/X86_64MasmRegs.v3:96-110`): `r11` = vfp, `rsi` = vsp at call boundaries and
runtime arg 0, `r10` = memory 0 base, `rbp` = scratch, `rdx/rcx/r8` = runtime args 1–3, `rax` =
returned `Throwable`. A stack is a Virgil object `X86_64Stack` (`src/engine/x86-64/X86_64Stack.v3:9`);
the field offsets visible in the generated code are `+8 version`, `+16 parent`, `+24 cont_bottom`,
`+48 vsp`, `+56 rsp`, `+72 parent_rsp_ptr`, `+96 state_` (`StackState` tags: `EMPTY`=0,
`SUSPENDED`=1, `CALL_CHILD`=2, `RESUMABLE`=3, `RUNNING`=4, `src/engine/WasmStack.v3:93`).
A continuation is the unboxed pair `(stack, version)`
(`src/engine/continuation/UnboxedContinuation.v3:4`), kept in an XMM register in SPC code
(`valueKind = REF_U64`, tag `CONTREF` = `0x68`).

**`resume` — inline** (`SinglePassCompiler.v3:1452-1514`; helpers in
`src/engine/compiler/MacroAssembler.v3:376-431` and
`src/engine/x86-64/X86_64MacroAssembler.v3:1581-1606`):

1. `emit_validate_and_consume_cont` (`MacroAssembler.v3:376`): `pextrq` the stack pointer out of
   the XMM, trap on null, compare `[stack+8]` with the version half, trap on mismatch, `add [stack+8],1`.
2. `state.emitSaveAll(SAVE_AND_FREE_REGS)` — spill every live slot, *with its tag byte*, to the
   value stack (the source comment at `:1475` admits this is more than necessary).
3. `emit_cont_mv` (`X86_64MacroAssembler.v3:1581`): `n × 32` bytes are copied from the resumer's
   value stack to `[child.vsp]` in a loop (`emit_value_copy`, `:945`): one `movdqu` pair for the
   16-byte payload and one byte move for the tag per value; `child.vsp += n×32`.
4. `curStack.vsp = vsp; curStack.rsp = rsp - 8` (the `-8` reserves the slot the following
   `call` will fill), then `emit_chain_cont_to_parent` (`MacroAssembler.v3:407`):
   `curStack.state = CALL_CHILD`, `child.state = RUNNING`, `child.cont_bottom.parent = curStack`,
   `*(child.cont_bottom.parent_rsp_ptr) = curStack.rsp`, `child.cont_bottom = null`.
5. `call stub_resume` pushes the return address into the reserved slot; the stub
   (`emit_switch_to_stack`, `MacroAssembler.v3:425`) does `mov [curStack], child;
   mov rsp, [child+56]; pop rbp; jmp rbp` — the child's stack top holds either the
   `stack-enter-func` stub (fresh continuation, `X86_64Stack.v3:884`) or the address after the
   child's own `call stub_suspend`/`stub_switch`.
6. Control comes back to the instruction after `call stub_resume` in two ways: the child
   **returns** through the return-parent stub (`X86_64Stack.v3:810-881`: copy results to the
   parent's value stack, push the finished stack onto `X86_64StackManager.cache`, `pop rsp; ret`),
   or the child **suspends** and the runtime has overwritten that return address with the address
   of a *handler stub* (below). Either way the code then reloads `vfp`/`mem0_base` from the frame
   (`emit_reload_regs`, `SinglePassCompiler.v3:2374`).

**`suspend` — runtime call** (`SinglePassCompiler.v3:1515-1554`):

1. `emitSaveAll` again, then `curStack.vsp = vsp`, `curStack.rsp = rsp - 8`, load `instance`
   from the frame, tag index into `rcx`, `mov rbp, <absolute address>; call rbp` into
   `X86_64Runtime.runtime_handle_suspend` (`src/engine/x86-64/X86_64Runtime.v3:138-170`;
   the call is an absolute indirect call, `X86_64MacroAssembler.v3:932-937`).
2. The runtime: `stack.popN(tag params)` **allocates an `Array<Value>`**
   (`X86_64Stack.v3:379-383`); `Runtime.unwindStackChain` (`src/engine/Runtime.v3:393-405`)
   walks `parent` links calling `tryHandleSuspension` (`X86_64Stack.v3:214-254`) on each: that
   reads the parent's top frame, `FuncDecl.findSuspensionHandler` → `findHandler`
   (`src/engine/Module.v3:197-228`, a linear scan flagged `// XXX: speed this up with a binary
   search`), and on a hit **rewrites the return address at the parent's `rsp`** to the handler
   stub (`redirectToHandlerStub`, `src/engine/x86-64/X86_64Frames.v3:82-87`) and resets the
   parent's `vsp` to the handler's stack height. Back in `runtime_handle_suspend`: mark the
   suspender `SUSPENDED`, detach it (`bottom.parent = null`), `curStack = handler stack`,
   `pushN(vals)` + `push(Cont(...))` onto the handler's value stack, and push a dummy word on the
   handler's `rsp` so that the stub's `add [curStack.rsp],8` pairs up.
3. `call stub_suspend` (pushes the suspender's resume address into the reserved slot), and the
   stub: `mov rbp,[curStack]; add [rbp+56],8; mov rsp,[rbp+56]; add [rbp+56],8; pop rbp; jmp rbp`
   — six instructions that land in the resumer's handler stub.
4. The **handler stub** is emitted at the end of every function that has handlers
   (`SinglePassCompiler.v3:223-269`): `mov r11,[rsp+16]; mov r10,[rsp+8]; jmp <merge label>`.
   The handler block's merge state is "everything in memory" when no branch has reached the
   label yet (`buildHandlerDest`, `:1116-1118`); otherwise the existing merge state is reused and
   the stub reloads the register-resident slots (`:257-263`). Either way the payload itself is in
   memory, pushed there by the runtime.

**`switch` — runtime call** (`SinglePassCompiler.v3:1555-1601`, runtime
`X86_64Runtime.v3:174-215`): same JIT-side shape as `suspend` with two immediates (target
continuation type, tag). The runtime pops the target continuation and the arguments
(another `Array<Value>`), null/used checks, `setUsed` (version++),
`unwindStackChain(..., tryHandleSwitch)` (`X86_64Stack.v3:255-265` — same linear scan, no
return-address rewrite because control does not go to the handler), marks the switcher
`SUSPENDED`, splices `target.cont_bottom.parent = prev.parent` and copies the
`parent_rsp_ptr` slot, pushes args + the switcher's continuation onto the target's value
stack, sets `curStack`, pushes the dummy word. The same six-instruction stub then switches.

**`cont.new`** — runtime call in every tier (`emit_call_runtime_op1n`,
`SinglePassCompiler.v3:2001-2023` → `X86_64Runtime.runtime_CONT_NEW` → `Runtime.CONT_NEW`,
`Runtime.v3:360-371`): pops the funcref, takes a stack from the pool, `reset(func)` pushes the
return-parent and enter-func stub addresses (`X86_64Stack.v3:49-60`).

**Consequences worth naming.** (a) Every `suspend`/`switch` crosses into Virgil with *all*
operand-stack values written to memory with tags and reloaded afterwards. (b) The runtime
allocates on the Virgil heap on every `suspend`/`switch` (`popN`), so a switch-heavy loop is
also a GC-pressure loop — the itersum runs below reach 700 MB RSS (§3). (c) Handler search is a
linear scan of `handlers.suspend_handlers` per parent frame, keyed by `pc` recovered from the
return address via `lookupTopPc`. (d) `resume` copies values slot-by-slot, 32 bytes per value,
including the tag. (e) Traps inside the runtime are delivered by rewriting the return address to
the unwind stub (`X86_64Stack.v3:950`), so the JIT code never tests the returned `Throwable`.

### 1.3 Wasmtime Cranelift

**Execution model.** Cranelift compiles Wasm to CLIF, runs regalloc2, and the stack-switching
instructions are *expanded into CLIF* by `crates/cranelift/src/func_environ/stack_switching/instructions.rs`
(2 225 lines) around one primitive CLIF instruction, `stack_switch`
(`cranelift/codegen/meta/src/shared/instructions.rs:981`). The runtime objects the code touches:

- `VMContRef` (`crates/wasmtime/src/runtime/vm/stack_switching.rs:205-248`), laid out by
  `crates/environ/src/vmoffsets.rs:545-690` — with 8-byte pointers: `+0..+24` the four
  `VMStackLimits` words (`stack_limit`, `last_wasm_entry_fp`, `last_wasm_entry_sp`,
  `last_wasm_entry_trap_handler`), `+0x20` state (`Fresh`=0, `Running`=1, `Parent`=2,
  `Suspended`=3, `Returned`=4, `Trapped`=5, `crates/environ/src/stack_switching.rs:16-31`),
  `+0x28/+0x2c/+0x30` handler list (length, capacity, data), `+0x38` first switch-handler
  index, `+0x40/+0x48` parent chain (discriminant `Absent`=0 / `InitialStack`=1 /
  `Continuation`=2, payload), `+0x50` last ancestor, `+0x58` revision, `+0x60` stack top,
  `+0x78/+0x7c/+0x80` `args` buffer, `+0x88/+0x8c/+0x90` `values` buffer.
- `VMStoreContext` (reached as `[vmctx+8]`): `+0x18` stack limit, `+0x40/+0x48/+0x50` the three
  last-Wasm-entry words, `+0x58/+0x60` the active stack chain (the CLIF names these regions,
  e.g. `region4 = 67108952 "VMStoreContext+0x58"` in `compiler-diff/wasmtime-pingpong-main.clif`).
- The **control context**: 24 bytes at `stack_top - 0x18` = `{rsp, rbp, rip}`
  (`cranelift/codegen/src/isa/x64/inst/stack_switch.rs:31-37`,
  `crates/wasmtime/src/runtime/vm/stack_switching/stack/unix.rs:1-60`). For an active
  continuation it holds its *parent's* registers; for a suspended one, its own.
- Continuation values are `i128` fat pointers `(revision << 64) | contref`
  (`stack_switching/fatpointer.rs`). Cranelift lowers the 64-bit shifts of an `i128` generically —
  each decode/encode costs ≈13–17 instructions (`shlx/shrx/test/cmove/or`), visible in every listing below.

**`stack_switch`** (`cranelift/codegen/src/isa/x64/inst/emit.rs:547-646`): two operands, a
"store" and a "load" control-context pointer (allowed to be equal), a payload in the fixed
register `rdi` (`stack_switch.rs:47`). Emission is exactly

```
mov tmp1,[load+0] ; mov [store+0],rsp ; mov rsp,tmp1      ; exchange rsp
mov tmp1,[load+8] ; mov [store+8],rbp ; mov rbp,tmp1      ; exchange rbp
mov tmp1,[load+16]; lea tmp2,[rip+resume]; mov [store+16],tmp2 ; jmp tmp1
resume:
```

ten instructions (eight `mov`s, a `lea`, a `jmp`; `lit-review/04-runtimes.md` §3's "six movs"
undercounts by two), no register saves: the instruction is declared to clobber every register
except the payload register `rdi` (`cranelift/codegen/src/isa/x64/inst/mod.rs:1032-1050`), so
regalloc2 spills exactly what is live.

**`resume`** (`translate_resume_impl`, `instructions.rs:1407-1867`): decode the fat pointer, trap
on null, load `revision`, compare with the witness, trap, store `revision+1`; branch on
`state == Fresh` to pick the `args` or `values` buffer and store the arguments there (16 bytes per
value); splice: `last_ancestor.parent_chain = VMStoreContext.stack_chain`, zero
`last_ancestor`, `stack_chain = Continuation(contref)`; `child.state = Running`,
`parent.state = Parent`; copy the four limit words from `VMStoreContext` into the parent's
`VMStackLimits` and the child's into `VMStoreContext`; install the handler list (data pointer =
a stack slot of this frame, one `lea vmctx+tag_offset` per handler, length,
`first_switch_handler_index`); `stack_switch` through the **last ancestor's** control context
with payload `RESUME = 1<<32`. After the switch: reload the chain, restore the parent chain and
`Running`, clear the handler list, then `test rdi` — zero is a return (`CONTROL_EFFECT_RETURN = 0`,
`crates/environ/src/stack_switching.rs:35`), the fast path; otherwise `shr rdi,32; cmp 4` for
trap, else it is a suspend and the low 32 bits are the handler index fed to a `br_table`
(`:1829`), whose targets load the payload from the suspended continuation's `values` buffer.

**`suspend`** (`translate_suspend`, `:1901-1975`): `search_handler` (`:1154-1284`) is emitted
inline as a doubly nested loop — outer over `parent_chain` links until discriminant 1
(`InitialStack`, trap `UnhandledTag`), inner over `[0, first_switch_handler_index)` of that
parent's handler list comparing `*mut VMTagDefinition` addresses. Then: `active.last_ancestor =
end of chain`, allocate the `values` buffer as a **stack slot of the suspender's frame**
(`allocate_or_reuse_stack_slot`, `:1934`), store the payload, `state = Suspended`, break the
chain (`end.parent_chain = Absent`, two zero stores), `stack_switch` through the end-of-chain
control context with payload `SUSPEND<<32 | handler_index`. On resumption, `cmp rdi>>32, 5`
distinguishes `resume_throw` (throw) from `resume` (load the tag's results from `values`).

**`switch`** (`translate_switch`, `:1977-2225`): decode + revision check + increment on the
switchee; `search_handler` with `search_suspend_handlers = false` (scan
`[first_switch_handler_index, length)`); mark the switcher `Suspended`, break its chain, save
three limit words; build the switcher's fat pointer, store `args + switcher` into the switchee's
`args`/`values` buffer (16 bytes each); `switchee.state = Running`;
`switchee.last_ancestor.parent_chain = handler stack`; set the active chain and write the
switchee's limits to `VMStoreContext`; copy the switchee's control context to a temporary
stack slot and the switcher's over the switchee's (3 × 2 loads/stores — one slot per `switch`
instruction, a `NOTE` at `:2150`), then `stack_switch(store = switcher's cc, load = tmp)`
with payload `SWITCH = 3<<32`.

**`cont.new`** (`translate_cont_new`, `:1310-1337`): libcall `cont_new`
(`crates/environ/src/builtin.rs:157` → `crates/wasmtime/src/runtime/vm/stack_switching.rs:313-362`
→ `store.rs:2137 allocate_continuation`: `Box` + `mmap` of `async_stack_size` (2 MiB,
`config.rs:301`) + guard, `mprotect`; nothing is pooled or freed), then `revision` load and
fat-pointer construct. It is the only one of the four that leaves compiled code.

### 1.4 Side by side

| Aspect | Wizard SPC | Wasmtime Cranelift |
|---|---|---|
| Runtime calls per op | `suspend`, `switch`, `cont.new`, `cont.bind` — yes; `resume` — no | only `cont.new` |
| Heap allocation per op | `suspend`/`switch`: one `Array<Value>` per payload (`popN`), plus whatever `Continuations`/trace paths allocate | none (payload buffers are stack slots or inside the continuation's own stack) |
| Values crossing the switch | copied slot-by-slot between tagged value stacks (32 B/value, loop) | stored to / loaded from a 16 B/value buffer with straight-line code |
| Handler search | Virgil: walk parents, per parent linear scan of a per-function table keyed by `pc` recovered from the return address | inline loop over the chain, per parent linear scan of a pointer array installed by `resume` |
| Handler dispatch | runtime rewrites the resumer's return address → per-handler stub → merge label | suspender passes an index; resumer `br_table`s on it |
| Register state at the switch | all live slots + tags spilled by SPC before the call; everything reloaded after | regalloc2 spills only what is live across `stack_switch` (which clobbers all but `rdi`) |
| Trap delivery from the op | return-address rewrite to the unwind stub | `trapz`/`trapnz` → `ud2` sites in the same function |
| State written per `resume` | 3 states + 2 links + `vsp`/`rsp` of both stacks | 2 states, 2×(2-word chain) + 2×4 limit words + handler list (≥4 words) + payload length |
| Stack for a fresh continuation | from a free list refilled 8 at a time (`StackTuning.stackCacheSize`), 512 KiB default (64 KiB in `benchmark/fiber-c/config.yml`) | `mmap` 2 MiB + 4 KiB guard per `cont.new`, kept until the store is dropped |
| Static size of the sequence (this workload) | resume 51–55, suspend 26–28, switch 27 (+ runtime) | resume 102–119 (+30 return path), suspend 51 (+4–7), switch 138–140 (+13–14) |
| Dynamic instructions per op | resume ≈ 55–70 (inline; static count, not measured); suspend 1 563–1 840 measured + ≈30; switch 1 601 measured + ≈30 | ≈ static counts; the search loops iterate once here |

---

## 2. The workload

### 2.1 What is in the repo

The only programs in this repository that contain all three opcodes are the **fiber-c `*_switch`
benchmarks** (`benchmark/fiber-c/examples/{hello,itersum,treesum,pi,scheduler}_switch.c`). Their C code calls a
tiny Wasm shim, `benchmark/fiber-c/src/wasmfx/imports_switch.wat.pp`, that `wasm-merge` fuses into every
`*_switch_wasmfx.wasm`; the shim is where the opcodes live:

| Shim function | Instructions | Role |
|---|---|---|
| `$wasmfx_switch_trampoline` | `cont.new`, two `resume … (on $yield switch) (on $switch-return $lbl)`, `resume_throw` inside `try_table` | the scheduler on the main stack: starts the first fiber, cancels finished ones, resumes the next |
| `$switch` (`wasmfx_switch`) | one `switch $ct2 $yield` | `fiber_switch()`: symmetric transfer to another fiber |
| `$switch-return` (`wasmfx_switch_return`) | one `suspend $switch-return` | `fiber_switch_return()`: a fiber finished, hand control to the trampoline |
| `$indexed_cont_new` | `cont.new` + `cont.bind` | `fiber_alloc()` |

`itersum_switch` (`examples/itersum_switch.c`) is the smallest: a `run` fiber and a `sum` fiber
ping-pong `N` times with `fiber_switch`, then each returns with `fiber_switch_return`. `N` comes
from `argv[1]` through WASI. The non-switch sibling `itersum` (`examples/itersum.c` +
`src/wasmfx/imports.wat.pp`, `$indexed_resume` = one `resume`, `$suspend` = one `suspend`) is the
matching `resume`/`suspend`-only workload and is used below for that pair's timing.

The OCaml suites (`benchmark/benches/`, `benchmark/macro-benches/`, `benchmark/angstrom/`) go through `wasm_of_ocaml
--effects=native`, whose runtime (`~/workspace/js_of_ocaml/runtime/wasm/effect-native.wat`) uses
`cont.new`/`resume`/`suspend` but never `switch`, so they cannot serve here.

### 2.2 Getting the workload to load: four incompatibilities

The fiber-c build assembles the shim with the reference interpreter and merges/optimizes with
binaryen. At the pinned commits that pipeline produces a module **neither engine can load**:

1. **Opcode numbers.** The reference interpreter (`~/workspace/specfx`, commit `15ec7d15`,
   2024-10) and binaryen v124 (`src/wasm-binary.h:1240-1245`) emit the proposal's *old*
   numbering, `switch` = `0xE5` and no `resume_throw_ref`. Wizard (`src/engine/Opcodes.v3:611-617`)
   and Wasmtime's wasmparser 0.258 (`binary_reader.rs:1109-1117`) use the current one:
   `0xE4 resume_throw`, `0xE5 resume_throw_ref`, `0xE6 switch`. The shim's `switch` therefore
   decodes as `resume_throw_ref` in both engines. Fix: patch the opcode byte at the (single)
   `switch` site, `E5 0D 01` → `E6 0D 01` (`compiler-diff/mk-pingpong.sh` shows the same patch for
   the distilled module; the site is located by scanning the code section for the exact
   three-byte encoding and asserting exactly one hit).
2. **`resume_throw` immediates in Wizard.** The spec, wasmparser and Wizard's own bytecode
   iterator (`src/engine/BytecodeIterator.v3:785`) read `resume_throw` as *(cont, tag, handlers)*;
   Wizard's validator reads *(cont, handlers, tag)* (`src/engine/CodeValidator.v3:1290-1305`, the
   `readSuspensionHandlers()` at `:1293` precedes `readTagRef()` at `:1299`). The shim's
   `resume_throw $cancel-ct $cancel` encodes as `E4 09 02 00` (cont 9, tag 2, no handlers); the
   validator reads "2 handlers" and desynchronises, and the module is rejected with the
   misleading `expected 23 data segments, missing data section`
   (`compiler-diff/itersum_switch_wasmfx.original-tags.wasm`, bytes `e4 09 02 00 1a` at `0x3c5`).
   Fix without touching the
   instruction: **declare `$cancel` first** so it becomes tag 0 — `E4 09 00 00` decodes
   identically under both orders (`compiler-diff/fiber_switch_wasmfx_imports.tagreorder.wat`).
3. **binaryen cannot optimize a module that contains `switch`.** `benchmark/fiber-c/Makefile` never runs
   `wasm-opt` on `*_switch` modules (`Makefile:50-53`: clang → `wasm-merge` → done; only the
   non-switch rule at `:46-47` applies `-O2 -g`). The first version of `build-fiber-c.sh` applied
   `-O2` to both, and binaryen v124 asserted on the switch module
   (`src/cfg/cfg-traversal.h:597: Assertion 'branches.size() == 0' failed`, first in
   `HeapStoreOptimization`, then in `CoalesceLocals` with that pass skipped); the script now
   mirrors the Makefile. So the switch module used here is what the Makefile produces (clang
   `-O3`, merged, not touched by `wasm-opt`) and the `itersum` module goes through `-O2 -g` as
   the Makefile does.
4. **Wizard's SPC mis-executes the result** (`!NullCheckException in Runtime.TABLE_GET()` from
   `[spc-module] #12`, the trampoline, after the first `$switch-return`; §5.4). The
   interpreter (`--mode=int`) computes the right answer. Wasmtime runs it. All 27 of Wizard's own
   `test/regress/ext:stack-switching/switch*.bin.wast` pass in `--mode=jit`. So the SPC-tier
   `switch` timing on Wizard is taken from a distilled module (§2.4) that Wizard's SPC does run.

Wizard's compiled code for the fiber-c module is still exactly what §4 shows — compilation
happens before the crash, and the same sequences appear in the distilled module.

### 2.3 Building the fiber-c modules

`compiler-diff/build-fiber-c.sh <name>` replays `benchmark/fiber-c/Makefile`'s `out/%_wasmfx.wasm` /
`out/%_switch_wasmfx.wasm` rules outside the submodule tree, with the tools that exist on this
machine (wasi-sdk 22 from `~/workspace/benchfx/tools/wasi-sdk/wasi-sdk-22.0`, binaryen v124 at
`~/dev_path/binaryen`, the reference interpreter at `~/.opam/default/bin/wasm`), the same flags
(`-O3`, `WASMFX_PRESERVE_SHADOW_STACK=1`, 64 KiB continuation shadow stacks, table capacity
1024). For the switch module the Makefile's product is the merge itself; the two workarounds
(items 1–2) were applied on top of it:

```bash
# shim with $cancel declared first (item 2), assembled by the reference interpreter
wasm -d -i fiber_switch_wasmfx_imports.tagreorder.wat -o fiber_switch_wasmfx_imports.tagreorder.wasm
wasm-merge <binaryen flags> --enable-multimemory fiber_switch_wasmfx_imports.tagreorder.wasm fiber_switch_wasmfx_imports \
           itersum_switch_wasmfx.pre.wasm main -o itersum_switch_wasmfx.tr.wasm
# item 1: 0xE5 -> 0xE6 at the one `switch $ct2 $yield` site (bytes E5 0D 01 inside the code section)
python3 - <<'PY'
data=bytearray(open('itersum_switch_wasmfx.tr.wasm','rb').read())
# ... locate the code section, assert exactly one occurrence of b'\xE5\x0D\x01', set it to 0xE6 ...
PY
```

The resulting `itersum_switch_wasmfx.wasm` prints `499500` for `N = 1000` on Wasmtime and in
Wizard's interpreter. The itersum module (`build-fiber-c.sh itersum`) needs no patch: `cont.new`,
`cont.bind`, `suspend`, `resume` (`0xE0`–`0xE3`) are numbered the same in both generations.

### 2.4 `pingpong.wat` — the same shape without C

`compiler-diff/pingpong.wat` (60 lines) is `itersum_switch` with the C, the continuation table,
the globals and the shadow stack removed. It has the three opcodes in three tiny functions:

- `$main` — `cont.new` the consumer, `resume $ct (on $yield switch) (on $done $lbl)` it; when the
  producer reports completion through `$done` (payload: result + the consumer's continuation),
  `resume` the consumer once more with the result.
- `$consumer` — `cont.new` the producer, then `N` × `switch $ct $yield`, summing what comes back.
- `$producer` — `N` × `switch $ct $yield` back to the consumer, then `suspend $done`.

`N` is baked in at build time (`mk-pingpong.sh N`; Wizard's CLI passes no arguments to an
exported `main(i32)` — it ran `main(0)`, §5.6). The module was checked against the reference
interpreter as a semantics oracle: `(assert_return (invoke "main" (i32.const 1000)) (i32.const
499500))` and `(… 5 … 10)` both pass (`wasm -i compiler-diff/pingpong.wast`; the `.wast` is the
module text followed by those two assertions). Wasmtime prints `499500`;
Wizard, which uses `main`'s return value as the exit status, exits with `499500 mod 256 = 44`.
Wizard's SPC runs it for `N = 10 000 000` (exit status 192 = `-2014260032 mod 256`, the same
overflowed sum Wasmtime prints).

### 2.5 Running

```bash
WT=dependencies/wasmtime/target/release/wasmtime          # built from the submodule with cargo +1.98.0
WZ=dependencies/wizard-engine/bin/wizeng.x86-64-linux     # ./build.sh wizeng x86-64-linux
F=-W=exceptions,function-references,gc,stack-switching
$WT run $F itersum_wasmfx.wasm 10000000                       # fiber-c, WASI argv
$WT run $F --invoke main pingpong_10000000.wasm
$WZ --ext:stack-switching --ext:gc --stack-size=65536 --mode=spc itersum_wasmfx.wasm 10000000   # benchmark/fiber-c/config.yml flags, spc = no interpreter fallback
$WZ --ext:stack-switching --mode=spc pingpong_10000000.wasm
```

`--mode=spc` is "pre-compile modules with SPC, no fallback"; `--mode=jit` is the same code with
interpreter fallback (`wizeng --help`, `src/engine/x86-64/X86_64Target.v3:27-28`). Both were run;
they agree to within noise.

---

## 3. Measurements

### 3.1 Wall-clock, 1 M vs 10 M iterations

`/usr/bin/time -f "%e s %M KB"`, one process per run, warm page cache; WSL2 has no hardware
performance counters (`perf stat` is unavailable for this kernel), so wall-clock is what there
is. Three runs at 10 M agreed within ±3 % (Wasmtime itersum 0.13/0.13/0.13, itersum_switch
0.38/0.40/0.38; Wizard spc itersum 1.80/1.74/1.75); the table shows one run each.

| Workload (what one iteration does) | N | Wasmtime | Wizard `spc` | Wizard `jit` | Wizard `int` |
|---|---|---|---|---|---|
| fiber-c `itersum` (1 `resume` + 1 `suspend` + handler dispatch) | 1 M | 0.01 s | 0.17 s | — | 0.23 s |
| | 10 M | 0.14 s, 18 MB | 1.78 s, **718 MB** | — | 2.21 s |
| fiber-c `itersum_switch` (2 `switch` + table/global/shadow-stack traffic) | 1 M | 0.04 s | crash (§5.4) | crash | 0.60 s |
| | 10 M | 0.39 s, 18 MB | crash | crash | GC crash (§5.5) |
| `pingpong` (2 `switch`, nothing else) | 1 M | 0.02 s | 0.24 s | 0.25 s | 0.26 s |
| | 10 M | 0.13 s | 2.34 s | 2.22 s | GC crash (§5.5) |

Per-iteration cost, `(T(10 M) − T(1 M)) / 9 M`, which cancels process start-up and compilation:

| Per iteration | Wasmtime | Wizard SPC | ratio |
|---|---|---|---|
| `resume` + `suspend` round trip (itersum) | **14.4 ns** | **179 ns** | 12.4× |
| two `switch`es (pingpong) | **12.2 ns** (6.1 ns per switch) | **233 ns** (117 ns per switch; `jit` 219 ns) | 19× |
| two `switch`es + C glue (itersum_switch) | 38.9 ns | — (interpreter: ≈560 ns) | — |

The 718 MB resident set on Wizard's itersum run is consistent with the Virgil heap growing under the
per-suspend allocations of §1.2 (not profiled; Wasmtime stays at 18 MB); it is a memory observation, not a
timing one, but it is the same mechanism.

### 3.2 Instructions

Dynamic counts of Wizard's runtime calls were taken with gdb single-stepping from the entry of
the Virgil function to its return (`compiler-diff/count-insns.py`; `FUNC=<symbol> NCALLS=3 gdb
-batch -x count-insns.py --args wizeng …`). They are deterministic — every call of a given kind
counted the same:

| Wizard runtime function | Workload | Instructions per call |
|---|---|---|
| `X86_64Runtime.runtime_handle_suspend` | itersum (`suspend $yield`, one i32, handler one link up) | **1 563** |
| | pingpong (`suspend $done`, i32 + contref) | **1 840** |
| `X86_64Runtime.runtime_handle_switch` | itersum_switch and pingpong (one i32 + contref, handler one link up) | **1 601** |
| `X86_64Runtime.runtime_CONT_NEW` | pingpong (stack taken from the pool) | **516** |

Static counts of the emitted sequences (§4; Wizard from the compiler trace, Wasmtime from
`wasmtime objdump`, instructions between the first opcode-specific instruction and the last):

| Opcode | Wizard SPC JIT code | + Wizard runtime | Wasmtime, up to the `jmp` | Wasmtime, after |
|---|---|---|---|---|
| `resume` | 51 (fiber-c, 3 args) / 55 (pingpong, 2 args); copy loop 6 × args | 0 | 102 (fiber-c) / 119 (pingpong) | 31 return path, 27 suspend path (+ `br_table`) |
| `suspend` | 26 / 28 (of which 4–7 are spills) | 1 563–1 840 | 51 (fiber-c and pingpong) | 4–8 |
| `switch` | 27 / 27 (4 spills) | 1 601 | 138 / 140 | 13–14 |

So a Wizard `switch` executes ≈1 630 instructions where Wasmtime executes ≈150, and the ratio in
time (19×) is larger than the ratio in instructions (≈11×) — the Virgil path also pays a heap
allocation, an indirect call through an absolute address, the handler-table scan's data-dependent
loads, and the stores/reloads of every live slot on both sides.

---

## 4. The emitted x86-64 code

Listings are for the fiber-c `itersum_switch` module (§2.3) unless noted; the `pingpong` versions
are the same sequences with different slot offsets and argument counts and are in
`compiler-diff/`. Wizard listings are in Intel syntax as printed by Wizard's own disassembler
(`-tk -ta`), cross-checked instruction-for-instruction against gdb on the live process (§4.3;
raw gdb dumps with bytes: `compiler-diff/wizard-spc-*.gdb.txt`). Wasmtime listings are in AT&T
syntax as printed by `wasmtime objdump` (raw, with bytes and Wasm-offset maps:
`compiler-diff/wasmtime-*.objdump.txt`). Comments were added by hand from the sources cited in
§1. In Wizard's trace, unresolved branch targets print as `$-5`; in the gdb dump they are the
SPC trap stub for the reason named.

### 4.1 Wizard SPC

Registers: `r11` = vfp (base of this frame's value-stack slots, 32 bytes each), `rsp` = the
104-byte native frame (`[rsp+8]` mem0_base, `[rsp+16]` vfp, `[rsp+24]` vsp, `[rsp+80]` instance),
`rbp` = scratch. `[0x083BE2C0]` is `X86_64Runtime.curStack` in this build. Absolute callee
addresses were resolved with `nm`/gdb: `0x8240DC0` = `X86_64Runtime.runtime_handle_suspend`,
`0x8241268` = `X86_64Runtime.runtime_handle_switch`, `0x823FC78` = `runtime_CONT_NEW`.

#### `resume` — `$wasmfx_switch_trampoline`, first `resume $ct-initial (on $yield switch) (on $switch-return …)` at bytecode +24 (3 arguments)

```asm
	movdqu xmm0, oword [r11+784]   ; operand: the continuation (slot 24) -> xmm0 = (stack | version)
	movaps xmm1, xmm0
	pextrq rax, xmm1, 0            ; rax = cont.stack
	cmp rax, 0
	je   <trap NULL_DEREF>
	pextrq rbp, xmm1, 1            ; rbp = cont.version
	cmp qword [rax+8], rbp         ; stack.version == version ?
	jne  <trap USED_CONTINUATION>
	add qword [rax+8], 1           ; consume: stack.version++
	mov rsi, r11
	add rsi, 768                   ; rsi = vsp (all 24 live slots are already in memory: emitSaveAll)
	mov ecx, 3                     ; nvals = 3 (params of $ct-initial)
	mov r8, rcx
	imul r8, r8, 32                ; bytes = nvals * 32
	mov rbp, rax
	mov rdx, qword [rbp+48]        ; rdx = child.vsp
	add qword [rbp+48], r8         ; child.vsp += bytes
	sub rsi, r8                    ; rsi = first argument slot on our value stack
	cmp ecx, 0
	je   $30                       ; (never taken here)
	shl ecx, 5
	movdqu xmm2, oword [rsi+rcx-16] ; -- copy loop, one 32-byte slot per iteration:
	movdqu oword [rdx+rcx-16], xmm2 ;    16-byte payload
	mov bpl, byte [rsi+rcx-32]      ;    and the tag byte
	mov byte [rdx+rcx-32], bpl
	sub ecx, 32
	jne  $-27                       ; -- 6 instructions x nvals
	mov rbx, qword [0x083BE2C0]    ; rbx = curStack
	mov rsi, r11
	add rsi, 672                   ; vsp after popping the 3 args + the continuation (21 slots)
	mov qword [rsp+24], rsi        ; frame.vsp
	mov qword [rbx+48], rsi        ; curStack.vsp = vsp
	mov qword [rbx+56], rsp
	sub qword [rbx+56], 8          ; curStack.rsp = rsp - 8  (the slot `call` fills below)
	mov dword [rbx+96], 2          ; curStack.state = CALL_CHILD
	mov rbp, rax
	mov dword [rbp+96], 4          ; child.state = RUNNING
	mov rbp, qword [rbp+24]        ; rbp = child.cont_bottom
	mov qword [rbp+16], rbx        ; bottom.parent = curStack
	mov rbx, qword [rbx+56]        ; rbx = curStack.rsp
	mov rbp, qword [rbp+72]        ; rbp = bottom.parent_rsp_ptr
	mov qword [rbp], rbx           ; *parent_rsp_ptr = curStack.rsp  (used by the return-parent stub)
	mov dword [rax+24], 0          ; child.cont_bottom = null
	call $15                       ; call stub_resume: pushes the return address into the reserved slot
	;; ---- control comes back here: after a return (via the return-parent stub) or a suspend
	;;      (the runtime rewrote this return address to the handler stub; see below)
	mov r11, qword [rsp+16]        ; reload vfp
	mov r10, qword [rsp+8]         ; reload mem0_base
	jmp  $15                       ; skip the stub
	mov qword [0x083BE2C0], rax    ; stub_resume: curStack = child
	mov rsp, qword [rax+56]        ; rsp = child.rsp
	pop rbp                        ; child's resume address (enter-func stub, or after its suspend/switch stub)
	jmp rbp
```

51 instructions plus 6 per argument. On the resumer's side nothing else executes: the
return-parent stub (pregenerated, `X86_64Stack.v3:810-881`: copy the results to the parent's
value stack with the same loop, null `parent`/`parent_rsp_ptr`, push the stack onto the free
list, `curStack = parent`, `pop rsp; ret`) brings control back for a return; for a suspension
the handler stub emitted at the end of this function does:

```asm
	mov r11, qword [rsp+16]        ; handler stub #1 (dest of `(on $switch-return $lbl)`)
	mov r10, qword [rsp+8]
	jmp  $-1246                    ; the handler block's merge label; payload + continuation are
	                               ; already on the value stack, pushed by runtime_handle_suspend
```

`(on $yield switch)` produces no stub (`handler stub #0: DUMMY`).

#### `switch` — `$switch` (`wasmfx_switch`), `switch $ct2 $yield` at bytecode +66

```asm
	mov dword [r11+288], 127       ; spill slot 9 tag = I32 (0x7F)   -- emitSaveAll
	mov dword [r11+320], 104       ; spill slot 10 tag = CONTREF (0x68)
	mov dword [r11+304], eax       ; slot 9 value: the argument
	movdqu oword [r11+336], xmm0   ; slot 10 value: the target continuation
	mov rsi, r11
	add rsi, 352                   ; vsp = vfp + 11 slots
	mov qword [rsp+24], rsi        ; frame.vsp
	mov rbp, qword [0x083BE2C0]
	mov qword [rbp+48], rsi        ; curStack.vsp = vsp
	mov rsi, qword [0x083BE2C0]    ; arg0 = curStack
	mov qword [rsi+56], rsp
	sub qword [rsi+56], 8          ; curStack.rsp = rsp - 8
	mov rdx, qword [rsp+80]        ; arg1 = instance
	mov ecx, 13                    ; arg2 = target continuation type index ($ct2)
	mov r8d, 1                     ; arg3 = tag index ($yield)
	mov ebp, 136581736             ; 0x8241268 = X86_64Runtime.runtime_handle_switch
	call rbp                       ; ~1 601 instructions of Virgil (pop, checks, version++, handler search,
	                               ;   splice, push args + our continuation on the target, curStack = target)
	call $15                       ; call stub_switch: pushes our resume address into the reserved slot
	;; ---- resumed here (by a switch back to us, or by a resume of our continuation)
	mov r11, qword [rsp+16]        ; reload vfp
	mov r10, qword [rsp+8]         ; reload mem0_base
	jmp  $25
	mov rbp, qword [0x083BE2C0]    ; stub_switch: rbp = curStack (the target, set by the runtime)
	add qword [rbp+56], 8          ; drop the dummy word the runtime pushed
	mov rsp, qword [rbp+56]        ; rsp = target.rsp
	add qword [rbp+56], 8
	pop rbp                        ; target's resume address
	jmp rbp
```

27 instructions; the results (`[i32 (ref null $ct2)]`) are then read back from slots 9 and 10,
where `runtime_handle_switch` of the *other* side left them.

#### `suspend` — `$switch-return` (`wasmfx_switch_return`), `suspend $switch-return` at bytecode +9

```asm
	mov dword [r11+64], 127        ; spill slot 2 tag = I32
	mov dword [r11+96], 127        ; spill slot 3 tag = I32
	mov dword [r11+80], eax        ; slot 2 value (target index)
	mov dword [r11+112], ebx       ; slot 3 value (arg)
	mov rsi, r11
	add rsi, 128                   ; vsp
	mov qword [rsp+24], rsi
	mov rbp, qword [0x083BE2C0]
	mov qword [rbp+48], rsi        ; curStack.vsp = vsp
	mov rsi, qword [0x083BE2C0]    ; arg0 = curStack
	mov qword [rsi+56], rsp
	sub qword [rsi+56], 8          ; curStack.rsp = rsp - 8
	mov rdx, qword [rsp+80]        ; arg1 = instance
	mov ecx, 2                     ; arg2 = tag index ($switch-return)
	mov ebp, 136580544             ; 0x8240DC0 = X86_64Runtime.runtime_handle_suspend
	call rbp                       ; ~1 563-1 840 instructions of Virgil
	call $15                       ; call stub_suspend
	;; ---- resumed here
	mov r11, qword [rsp+16]
	mov r10, qword [rsp+8]
	jmp  $25
	mov rbp, qword [0x083BE2C0]    ; stub_suspend: rbp = curStack (the handler stack)
	add qword [rbp+56], 8          ; drop the dummy word
	mov rsp, qword [rbp+56]        ; rsp = handler stack's rsp -> its (rewritten) return address
	add qword [rbp+56], 8
	pop rbp                        ; = the resumer's handler stub
	jmp rbp
```

26 instructions. The same sequence with raw bytes, as gdb saw it for `wasmfx_suspend` in the
itersum module (`compiler-diff/wizard-spc-fiberc-itersum.gdb.txt`, `disassemble/r`, only the
opcode-specific part; tag index 0, one i32):

```
0x7ffff7fdd88c: 41 c7 43 20 7f 00 00 00   mov DWORD PTR [r11+0x20],0x7f
0x7ffff7fdd894: 41 89 43 30               mov DWORD PTR [r11+0x30],eax
0x7ffff7fdd898: 4c 89 de                  mov rsi,r11
0x7ffff7fdd89b: 48 83 c6 40               add rsi,0x40
0x7ffff7fdd89f: 48 89 74 24 18            mov QWORD PTR [rsp+0x18],rsi
0x7ffff7fdd8a4: 48 8b 2c 25 c0 e2 3b 08   mov rbp,QWORD PTR ds:0x83be2c0
0x7ffff7fdd8ac: 48 89 75 30               mov QWORD PTR [rbp+0x30],rsi
0x7ffff7fdd8b0: 48 8b 34 25 c0 e2 3b 08   mov rsi,QWORD PTR ds:0x83be2c0
0x7ffff7fdd8b8: 48 89 66 38               mov QWORD PTR [rsi+0x38],rsp
0x7ffff7fdd8bc: 48 83 6e 38 08            sub QWORD PTR [rsi+0x38],0x8
0x7ffff7fdd8c1: 48 8b 54 24 50            mov rdx,QWORD PTR [rsp+0x50]
0x7ffff7fdd8c6: 31 c9                     xor ecx,ecx
0x7ffff7fdd8c8: bd c0 0d 24 08            mov ebp,0x8240dc0
0x7ffff7fdd8cd: ff d5                     call rbp
0x7ffff7fdd8cf: e8 0f 00 00 00            call 0x7ffff7fdd8e3
0x7ffff7fdd8d4: 4c 8b 5c 24 10            mov r11,QWORD PTR [rsp+0x10]
0x7ffff7fdd8d9: 4c 8b 54 24 08            mov r10,QWORD PTR [rsp+0x8]
0x7ffff7fdd8de: e9 19 00 00 00            jmp 0x7ffff7fdd8fc
0x7ffff7fdd8e3: 48 8b 2c 25 c0 e2 3b 08   mov rbp,QWORD PTR ds:0x83be2c0
0x7ffff7fdd8eb: 48 83 45 38 08            add QWORD PTR [rbp+0x38],0x8
0x7ffff7fdd8f0: 48 8b 65 38               mov rsp,QWORD PTR [rbp+0x38]
0x7ffff7fdd8f4: 48 83 45 38 08            add QWORD PTR [rbp+0x38],0x8
0x7ffff7fdd8f9: 5d                        pop rbp
0x7ffff7fdd8fa: ff e5                     jmp rbp
```

#### `cont.new` — `$indexed_cont_new`, for completeness

The SPC code is the generic runtime-call shape (`emit_call_runtime_op1n`): spill, `vsp`/`rsp`
into `curStack`, `instance` and the type index in `rdx`/`rcx`, `mov ebp, 0x823FC78; call rbp`
(`runtime_CONT_NEW`, 516 instructions), then `add [curStack+56], 8` and reload `vfp`/`mem0_base`.
The `cont.bind` that follows it in the shim is the same shape with two immediates.

### 4.2 Wasmtime Cranelift

`%rdi` is `vmctx` on entry (spilled to the frame; `8(%rdi)` = `VMStoreContext`). Offsets into a
`VMContRef` are the ones listed in §1.3. The 13–17-instruction `shlx/shrx/test/cmove/or` groups
are Cranelift's generic lowering of a 64-bit shift of an `i128` — fat-pointer decode
(`ushr 64` → witness) or encode (`ishl 64` → contref).

#### `suspend` — `wasmfx_switch_return` (`wasm[0]::function[14]`), complete function

```asm
1740: pushq %rbp ; movq %rsp,%rbp
1744: movq 8(%rdi),%r10 ; movq 0x18(%r10),%r10 ; addq $0x70,%r10   ; stack-limit check against
1750: cmpq %rsp,%r10 ; ja  StackOverflow                           ;   VMStoreContext.stack_limit
1759: subq $0x60,%rsp
175d: movq %rbx,0x30(%rsp) ; movq %r12,0x38(%rsp) ; movq %r13,0x40(%rsp) ; movq %r14,0x48(%rsp) ; movq %r15,0x50(%rsp)
1776: movl 0x170(%rdi),%eax ; movl %eax,0x160(%rdi)   ; global.set $switched_from_fiber_index (global.get $active_fiber_index)
;; suspend $switch-return  (Wasm offset 0x494)
1782: movq 8(%rdi),%rax                     ; rax = VMStoreContext
1786: movq %rdi,0x20(%rsp)
178b: movq 0x58(%rax),%r8                   ; active chain discriminant
178f: movq 0x60(%rax),%r14                  ; r14 = active contref (the suspender)
1793: movq %r14,%r11                        ; r11 = current link
1796: cmpq $1,%r8 ; je  UnhandledTag         ; -- search_handler, outer loop: InitialStack? -> trap
17a0: movq 0x40(%r11),%r8 ; movq 0x48(%r11),%rsi   ; parent chain of this link (discr, contref)
17a8: movq 0x30(%rsi),%r9                   ; parent.handlers.data
17ac: movl 0x38(%rsi),%r10d                 ; end = parent.first_switch_handler_index (suspend handlers are [0, end))
17b0: xorl %eax,%eax                        ; index = 0
17b2: cmpl %r10d,%eax ; jb  17c3            ; -- inner loop: index < end ?
17bb: movq %rsi,%r11 ; jmp 1796             ;    exhausted: climb to the parent link
17c3: movq %rax,%rdi ; shll $3,%edi ; movq (%r9,%rdi),%r12    ; handlers[index]
17cd: movq 0x20(%rsp),%rdi ; leaq 0x198(%rdi),%r13             ; &vmctx.tags[$switch-return]
17d9: leal 1(%rax),%ebx
17dc: cmpq %r13,%r12 ; je  17ed             ;    match?
17e5: movq %rbx,%rax ; jmp 17b2             ;    no: next index
17ed: movq %r11,0x50(%r14)                  ; suspender.last_ancestor = end of chain
17f1: movl $2,0x8c(%r14)                    ; suspender.values.capacity = 2
17fc: leaq (%rsp),%rsi ; movq %rsi,0x90(%r14)   ; suspender.values.data = a stack slot of THIS frame
1807: movl %edx,(%rsp) ; movl %ecx,0x10(%rsp)   ; payload: the two i32 arguments, 16 bytes apart
180e: movl $2,0x88(%r14)                    ; values.length = 2
1819: movl $3,0x20(%r14)                    ; suspender.state = Suspended
1821: movq %r14,0x28(%rsp)
1826: movq $0,0x40(%r11) ; movq $0,0x48(%r11)   ; end.parent_chain = Absent (break the chain)
1836: movq 0x60(%r11),%rcx ; addq $-0x18,%rcx   ; rcx = end-of-chain stack top - 0x18 = its control context
1841: movl %eax,%edi ; orq 0xbe(%rip),%rdi  ; payload = handler index | (SUSPEND=2)<<32  (constant pool)
;; stack_switch (store = load = rcx)
184a: movq (%rcx),%rax ; movq %rsp,(%rcx) ; movq %rax,%rsp          ; exchange rsp
1853: movq 8(%rcx),%rax ; movq %rbp,8(%rcx) ; movq %rax,%rbp        ; exchange rbp
185e: movq 0x10(%rcx),%rax ; leaq 6(%rip),%rdx ; movq %rdx,0x10(%rcx) ; jmpq *%rax   ; save resume rip, jump
;; ---- resumed here with the control effect in %rdi
186f: shrq $0x20,%rdi ; cmpq $5,%rdi ; je  18c5   ; RESUME_THROW? -> throw path (cold)
187d: movq 0x28(%rsp),%r14
1882: movl $0,0x88(%r14) ; movl $0,0x8c(%r14) ; movq $0,0x90(%r14)   ; clear values buffer
18a3: movq 0x30(%rsp),%rbx ; … ; movq 0x50(%rsp),%r15 ; addq $0x60,%rsp ; movq %rbp,%rsp ; popq %rbp ; retq
18c5: … load exnref from values ; clear ; callq throw_ref libcall ; ud2      ; (cold)
1900: ud2 StackOverflow ; 1902: ud2 UnhandledTag
```

51 instructions from the first load to the `jmpq`, 7 after it on the normal path (the three
checks and the three `values` clears) before the epilogue. Nothing is
allocated; the payload lives at `(%rsp)` of the suspender's own frame and is read from there by
the resumer's handler preamble through `values.data`.

#### `switch` — `wasmfx_switch` (`wasm[0]::function[13]`), from the null check to the results

```asm
;; switch $ct2 $yield  (Wasm offset 0x45c); %rax:%r9 = the target continuation fat pointer from table.get
136a: testq %rax,%rax ; je  NullReference
1373: movq 0x58(%rax),%rdx                  ; rdx = switchee.revision
1377: shrxq … cmoveq … (13 instructions)    ; rsi = witness (high 64 bits of the fat pointer)
13b2: cmpq %rsi,%rdx ; jne ContinuationAlreadyConsumed
13bb: addq $1,%rdx ; movq %rdx,0x58(%rax)   ; switchee.revision++
13c6: movq 8(%rdi),%rdx ; movq %rdi,0x118(%rsp)          ; rdx = VMStoreContext
13d2: movq 0x58(%rdx),%r9 ; movq 0x60(%rdx),%r14 ; movq %r14,%rsi   ; active chain; r14 = switcher
13dd: cmpq $1,%r9 ; je  UnhandledTag         ; -- search_handler (switch handlers): outer loop
13e7: movq 0x40(%rsi),%r9 ; movq 0x48(%rsi),%r8            ; parent link
13ef: movq 0x30(%r8),%r10 ; movl 0x38(%r8),%r11d ; movl 0x28(%r8),%ebx   ; data, index = first_switch_handler_index, end = length
13fb: cmpl %ebx,%r11d ; jb  140c
1404: movq %r8,%rsi ; jmp 13dd
140c: movq %r11,%rdi ; shll $3,%edi ; movq (%r10,%rdi),%r12
1416: movq 0x118(%rsp),%rdi ; leaq 0x194(%rdi),%r13        ; &vmctx.tags[$yield]
1425: addl $1,%r11d ; cmpq %r13,%r12 ; jne 13fb
1435: movq %rsi,0x50(%r14)                  ; switcher.last_ancestor = end of chain
1439: movl $2,0x8c(%r14) ; leaq (%rsp),%rdi ; movq %rdi,0x90(%r14)   ; switcher.values = {capacity 2, data = stack slot}
144f: movl $3,0x20(%r14)                    ; switcher.state = Suspended
1457: movq $0,0x40(%rsi) ; movq $0,0x48(%rsi)              ; end.parent_chain = Absent
1467: movq 0x48(%rdx),%r10 ; movq 0x40(%rdx),%r11 ; movq 0x50(%rdx),%rbx   ; VMStoreContext last-entry words
1473: movq %r10,8(%r14) ; movq %r11,0x10(%r14) ; movq %rbx,0x18(%r14)      ;   -> switcher.limits
147f: movq 0x58(%r14),%r10                  ; switcher.revision (for its fat pointer)
1483: movl 0x20(%rax),%edi ; testl %edi,%edi ; jne 14ac    ; switchee Fresh? -> args buffer, else values buffer
148e: movq 0x80(%rax),%r11 ; movl 0x78(%rax),%ebx ; leal 2(%rbx),%edi ; movl %edi,0x78(%rax) ; shlq $4,%rbx ; addq %rbx,%r11 ; jmp 14cb
14ac: (same on 0x90/0x88)
14cb: movl %ecx,(%r11)                      ; payload[0] = the i32 argument
14ce: shlxq … cmoveq … (17 instructions)    ; build (switcher.revision << 64) | switcher
151f: movq %r10,0x10(%r11) ; movq %rcx,0x18(%r11)          ; payload[1] = switcher's continuation (16 bytes)
1527: movl $1,0x20(%rax)                    ; switchee.state = Running
152e: movq 0x50(%rax),%r10                  ; switchee.last_ancestor
1532: movq %r9,0x40(%r10) ; movq %r8,0x48(%r10)            ; ….parent_chain = the handler stack's chain link
153a: movq $2,0x58(%rdx) ; movq %rax,0x60(%rdx)            ; VMStoreContext.stack_chain = Continuation(switchee)
1546: movq (%rax),%rdi ; movq %rdi,0x18(%rdx)              ; switchee.limits -> VMStoreContext (4 words)
154d: movq 8(%rax),%r8 ; movq %r8,0x48(%rdx) ; movq 0x10(%rax),%r9 ; movq %r9,0x40(%rdx) ; movq 0x18(%rax),%r11 ; movq %r11,0x50(%rdx)
1565: movq 0x60(%rsi),%r11                  ; switcher-chain end: stack top
1569: movq 0x60(%r10),%rax                  ; switchee-chain end: stack top
156d: movq -0x18(%rax),%rdx ; leaq 0x100(%rsp),%rcx ; movq %rdx,0x100(%rsp)    ; tmp = switchee cc (3 words) …
1581: leaq -0x18(%r11),%rdx ; movq -0x18(%r11),%rsi ; movq %rsi,-0x18(%rax)    ; switchee cc = switcher cc …
158d: movq -0x10(%rax),%rsi ; movq %rsi,0x108(%rsp) ; movq -0x10(%r11),%rsi ; movq %rsi,-0x10(%rax)
15a1: movq -8(%rax),%rsi ; movq %rsi,0x110(%rsp) ; movq -8(%r11),%rsi ; movq %rsi,-8(%rax)
15b5: movabsq $0x300000000,%rdi             ; payload = SWITCH<<32
;; stack_switch (store = rdx = switcher cc, load = rcx = tmp)
15bf: movq (%rcx),%rax ; movq %rsp,(%rdx) ; movq %rax,%rsp
15c8: movq 8(%rcx),%rax ; movq %rbp,8(%rdx) ; movq %rax,%rbp
15d3: movq 0x10(%rcx),%rax ; leaq 6(%rip),%rbx ; movq %rbx,0x10(%rdx) ; jmpq *%rax
;; ---- resumed here
15e4: shrq $0x20,%rdi ; cmpq $5,%rdi ; je  16e4          ; RESUME_THROW? (cold)
15f2: movq 0x130(%rsp),%r14 ; movq 0x90(%r14),%rcx        ; our values buffer
1601: movl (%rcx),%eax ; movq 0x10(%rcx),%rdx ; movq 0x18(%rcx),%rcx   ; results: i32, contref fat pointer
160b: movl $0,0x88(%r14) ; movl $0,0x8c(%r14) ; movq $0,0x90(%r14)     ; clear
```

138 instructions to the `jmpq`, 13 after. Of the 138, 30 are the two fat-pointer shuffles (13 + 17)
and 14 are the control-context copy through the temporary (16 with the two stack-top loads).

#### `resume` — `wasmfx_switch_trampoline` (`wasm[0]::function[12]`), first `resume` (Wasm offset 0x37e)

`%rax` holds the contref just returned by the `cont_new` libcall (the fat pointer was built at
`0x54f–0x594`; the pingpong `main` at `compiler-diff/wasmtime-pingpong.objdump.txt` `0xe19–0x1128`
is the same sequence for a 2-argument continuation).

```asm
597: testq %rax,%rax ; je  NullReference
5a0: movq 0x58(%rax),%rdx                   ; revision
5a4: shrxq … cmoveq … (16 instructions)     ; rcx = witness
5e8: cmpq %rcx,%rdx ; jne ContinuationAlreadyConsumed
5f1: leaq 1(%rdx),%rcx ; movq %rcx,0x58(%rax)          ; revision++
5f9: movl 0x20(%rax),%ecx ; testl %ecx,%ecx ; jne 625   ; state == Fresh ? args : values
604: movq 0x80(%rax),%rcx ; movl 0x78(%rax),%edx ; leal 3(%rdx),%esi ; movl %esi,0x78(%rax)   ; args.length += 3
614: movl %edx,%edx ; shlq $4,%rdx ; addq %rcx,%rdx ; movq %r13,%r11 ; jmp 647
625: (values variant on 0x90/0x88)
647: movl %r11d,(%rdx) ; movl %ecx,0x10(%rdx) ; movl %r8d,0x20(%rdx)   ; the three i32 arguments, 16 bytes apart
657: movq 0x50(%rax),%rcx                   ; rcx = child.last_ancestor
65b: movq 0x10(%rsp),%rdi ; movq 8(%rdi),%rdx          ; rdx = VMStoreContext
664: movq 0x58(%rdx),%rsi ; movq 0x60(%rdx),%r10        ; current chain (here: InitialStack, r10 = its CommonStackInformation)
66c: movq %rsi,0x40(%rcx) ; movq %rsi,0x18(%rsp) ; movq %r10,0x48(%rcx)   ; last_ancestor.parent_chain = current chain
679: movq $0,0x50(%rax)                     ; child.last_ancestor = 0
681: movq $2,0x58(%rdx) ; movq %rax,0x60(%rdx)          ; VMStoreContext.stack_chain = Continuation(child)
68d: movl $1,0x20(%rax) ; movl $2,0x20(%r10)            ; child Running, parent Parent
69c: movq 0x48(%rdx),%rsi ; movq 0x40(%rdx),%r8 ; movq 0x50(%rdx),%r9
6a8: movq %rsi,8(%r10) ; movq %r8,0x10(%r10) ; movq %r9,0x18(%r10)    ; parent.limits[1..3] = store's last-entry words
6b4: movq 0x18(%rdx),%rsi ; movq %rsi,(%r10)            ; parent.stack_limit = store's stack_limit
6bb: movq (%rax),%rsi ; movq %rsi,0x18(%rdx)            ; store's 4 limit words = child's
6c2: movq 8(%rax),%rsi ; movq %rsi,0x48(%rdx) ; movq 0x10(%rax),%rsi ; movq %rsi,0x40(%rdx) ; movq 0x18(%rax),%rax ; movq %rax,0x50(%rdx)
6da: movq %rdx,0x58(%rsp)
6df: movl $2,0x2c(%r10) ; leaq (%rsp),%rax ; movq %rax,0x30(%r10) ; movq %rax,0x48(%rsp)   ; parent.handlers = {capacity 2, data = stack slot}
6f4: leaq 0x198(%rdi),%rax ; movq %rax,(%rsp)           ; handlers[0] = &tags[$switch-return]  (suspend handlers first)
6ff: leaq 0x194(%rdi),%rax ; movq %rax,8(%rsp)          ; handlers[1] = &tags[$yield]          (then switch handlers)
70b: movl $2,0x28(%r10) ; movl $1,0x38(%r10)            ; length 2, first_switch_handler_index 1
71b: movq %r10,0x50(%rsp)
720: movq 0x60(%rcx),%rdx ; addq $-0x18,%rdx            ; the last ancestor's control context
72b: movabsq $0x100000000,%rdi              ; payload = RESUME<<32
;; stack_switch (store = load = rdx)
735: movq (%rdx),%rax ; movq %rsp,(%rdx) ; movq %rax,%rsp
73e: movq 8(%rdx),%rax ; movq %rbp,8(%rdx) ; movq %rax,%rbp
749: movq 0x10(%rdx),%rax ; leaq 6(%rip),%rcx ; movq %rcx,0x10(%rdx) ; jmpq *%rax
;; ---- resumed here: %rdi = control effect
75a: movq 0x58(%rsp),%rcx ; movq 0x60(%rcx),%rdx        ; rcx = VMStoreContext, rdx = the contref that just yielded/returned
763: movq 0x18(%rsp),%rax ; movq %rax,0x58(%rcx) ; movq 0x50(%rsp),%r10 ; movq %r10,0x60(%rcx)   ; restore our chain link
775: movl $1,0x20(%r10)                     ; parent Running
77d: movl $0,0x28(%r10) ; movl $0,0x2c(%r10) ; movq $0,0x30(%r10) ; movq $0,0x38(%r10)   ; clear handler list
79d: movq %rdi,%rsi ; testq %rsi,%rsi ; jne 800         ; RETURN (0)? fast path
7a9: movq (%r10),%r11 ; movq %r11,0x18(%rcx) ; … (4 words)   ; our limits back into VMStoreContext
7c8: movl $4,0x20(%rdx)                     ; child.state = Returned
7cf: movq 0x80(%rdx),%rax ; movl (%rax),%eax               ; result from child.args
7d8: movl $0,0x78(%rdx) ; movl $0,0x7c(%rdx) ; movq $0,0x80(%rdx) ; jmp …   ; clear args, continue after the resume
800: movq %rsi,%rax ; shrq $0x20,%rax ; cmpq $4,%rax ; je  trap-path       ; TRAP (4)?
811: movq 0x48(%rcx),%rax ; … ; movq %r9,0x18(%rdx)       ; suspended child.limits[1..3] = store's last-entry words
829: movq (%r10),%rax ; movq %rax,0x18(%rcx) ; … (4 words) ; our limits back into VMStoreContext
848: movq 0x58(%rdx),%rax                   ; suspended child's revision (for the contref handed to the handler)
84c: movl $1,%edi ; movl %esi,%esi ; cmpl %edi,%esi ; cmovbl %esi,%edi   ; clamp handler index
858: leaq 0xa(%rip),%r8 ; movslq (%r8,%rdi,4),%rsi ; addq %rsi,%r8 ; jmpq *%r8   ; br_table -> handler preamble
871: movq 0x90(%rdx),%rsi ; movl (%rsi),%r12d ; … ; movl $0,0x88(%rdx)        ; preamble: load payload from child.values
88e: shlxq … (17 instructions)              ; build the (revision << 64 | contref) handed to the handler block
```

102 instructions to the `jmpq`; after it 14 shared, then 17 more on the return path (31 in
total) or 27 more on the suspend path before the handler's own code.

### 4.3 How the listings were obtained

**Wizard.** `-tk` (`--trace-compiler`) prints every function as it is compiled with the Wasm
instruction being translated and, with `-ta` (`--trace-asm`; this build has `Debug.asm = true`,
`src/engine/Debug.v3:7`), Wizard's own disassembly of the bytes just emitted, plus a
`func[N].target_code: break *0x… disass 0x…, 0x…` line per function with the code address
range (`src/engine/x86-64/X86_64Target.v3:51-62`). Function indices come from the export table
(`wasm-objdump -x -j Export`). With ASLR disabled the code addresses are stable across runs, so
the same range can be disassembled from the live process:

```bash
setarch x86_64 -R $WZ --ext:stack-switching --ext:gc --stack-size=65536 --mode=spc -tk -ta --colors=false \
    itersum_switch_wasmfx.wasm 1000 > trace.txt          # sequences + func[N].target_code ranges
gdb -batch -q -ex 'set disassembly-flavor intel' -ex 'catch syscall exit exit_group' -ex run \
    -ex 'disassemble/r 0x00007FFFF7FDBF73,0x00007FFFF7FDC3AB' \
    --args $WZ --ext:stack-switching --ext:gc --stack-size=65536 --mode=spc itersum_switch_wasmfx.wasm 1000
```

(Wizard exits through `exit`, not `exit_group`; catching only the latter lets the process go.)
The gdb output agreed with the trace instruction-for-instruction on every function checked —
fiber-c `#12` (trampoline), `#13`, `#14`, itersum `#11`, `#12` and the three pingpong functions
(`compiler-diff/wizard-spc-*.gdb.txt` vs `*.trace.txt`; the traces end with the
`func[N].target_code` address lines); it also resolves the trap labels and, via `info symbol`,
the runtime callees. Dynamic instruction counts: `compiler-diff/count-insns.py`.

**Wasmtime.**

```bash
$WT compile $F -O opt-level=2 --emit-clif clif/ itersum_switch_wasmfx.wasm -o itersum_switch_wasmfx.cwasm
$WT objdump --addresses --bytes --addrmap=true --traps=true itersum_switch_wasmfx.cwasm > objdump.txt
```

`--addrmap=true` interleaves the Wasm code offset each instruction came from, which is how the
`resume` at Wasm offset `0x37e` was delimited inside the trampoline. `opt-level=2` is what
`benchmark/fiber-c/Makefile` uses for its `.cwasm`s and is Wasmtime's default; `wasmtime run` on the
`.cwasm` (`--allow-precompiled`) gives the same results as on the `.wasm`. The CLIF per function
(`compiler-diff/*.clif`) is what the annotations were derived from.

---

## 5. Problems found on the way

1. **Opcode numbering skew between the toolchain and the engines** (§2.2 item 1). The repo's
   reference interpreter and binaryen predate the renumbering that added `resume_throw_ref`;
   both engines pinned here use the new numbers. Any `switch` assembled by this toolchain is
   silently misread as `resume_throw_ref` by both engines. Affects: every `benchmark/fiber-c/*_switch`
   build, `RUNNING.md`'s pipeline for anything using `switch`.
2. **Wizard validator: `resume_throw` immediate order** (`src/engine/CodeValidator.v3:1290-1305`
   vs `src/engine/BytecodeIterator.v3:785`). Upstream bug; a module is accepted only if its
   `resume_throw` sites happen to encode identically under both orders (tag index equal to the
   handler count, e.g. tag 0 with no handlers). Not patched here (submodule).
3. **binaryen v124 `wasm-opt -O2` asserts on any module containing `switch`**
   (`cfg-traversal.h:597`). Not a fiber-c pipeline defect — its Makefile does not optimize switch
   modules — but it rules out post-merge optimization for switch workloads. Not patched.
4. **Wizard SPC crash on the fiber-c switch module.** `--mode=spc`/`jit`:
   `!NullCheckException in Runtime.TABLE_GET() [src/engine/Runtime.v3 @ 17:44] in [spc-module]
   #12 (wasmfx_switch_trampoline) in [spc-module] #20 in [spc-module] #15`, i.e. the trampoline's
   `table.get $conts` right after its `(on $switch-return …)` handler ran for the first time —
   the `instance` argument the SPC code passed from its frame slot was not an `Instance`.
   `--mode=int` prints the right result; Wizard's 27 `switch*` regress tests pass in `jit`; the
   distilled `pingpong` (same handler shape, no tables/`try_table`/`resume_throw`) runs in `spc`.
   The module is `compiler-diff/itersum_switch_wasmfx.wasm` and the repro is
   `wizeng.x86-64-linux --ext:stack-switching --ext:gc --stack-size=65536 --mode=spc compiler-diff/itersum_switch_wasmfx.wasm 1000`.
   **Root-caused and fixed** — `visit_RESUME_THROW`/`visit_RESUME_THROW_REF` copy the continuation
   stack into `runtime_arg2` *after* `emit_load_instance` has already overwritten that register,
   so the runtime unwinds the `Instance` as if it were a stack and writes `-8` over
   `instance.tables`. See [`wizard-bugs/`](wizard-bugs/README.md) (bug A) for the disassembly,
   the gdb before/after dump, the patch and a `.bin.wast` regression test.
5. **Wizard interpreter GC crash under switch pressure.** `--mode=int` at 10 M iterations of
   either switch workload: `!GcError: invalid reference … in Semispace.scanSlot() … in
   NativeStackScanner.scanStack() … in X86_64Runtime.runtime_handle_switch()` — the Virgil
   collector, triggered by the per-switch allocation from inside `runtime_handle_switch`
   called from the interpreter, finds a bad reference while scanning native frames. `spc` mode
   survives the same allocation rate.
   **Root-caused and fixed** — `runtime_handle_switch` nulls `prev.parent`/`prev.parent_rsp_ptr`
   *before* its last allocation (`curStack.push(Value.Cont(...))`), so a collection triggered
   there cannot walk past the just-detached stack and leaves roots in ancestor frames — notably
   the outermost stack held in `X86_64Stack.resume`'s frame — un-forwarded. `runtime_handle_suspend`
   detaches after its allocations, which is why only `switch` was affected. Two corrections to the
   observations above: `spc` is **not** immune — it merely did not sample the window with the
   modules tried here, and a test that decorrelates the collector phase reproduces in all three
   tiers; and the abort is not the only outcome, a missed root equally produces a silently wrong
   result. See [`wizard-bugs/`](wizard-bugs/README.md) (bug B).
6. **`wizeng` passes no arguments to an exported `main(i32)`** — it invoked `main(0)`
   (`src/WasmMode.v3:151`: `findMain` returns `Arrays.map(found.sig.params, Values.default)`, so
   every parameter is its type's default). Worked around by baking `N` into the module.
7. **Wasmtime**: nothing broke. `--invoke main <args>` warns that argument passing is
   experimental; `wasm-tools`-style tooling would have avoided the byte patch but is not on
   this machine (the `wast` 258 crate that matches wasmparser 0.258 is in `~/.cargo/registry`
   if a spec-current assembler is ever needed).

---

## 6. Reproduction cheat-sheet

```bash
# 0. toolchains (once)
rustup toolchain install 1.98.0 --profile minimal          # Wasmtime d8a0da6 needs rust >= 1.96
(cd wasmtime && cargo +1.98.0 build --release --bin wasmtime)   # ~5 min; stack-switching is a default feature
(cd wizard-engine && ./build.sh wizeng x86-64-linux)       # Virgil from ~/workspace/virgil

# 1. fiber-c modules (outputs land in $OUT, default ./fiber-c-build next to the script)
research/compiler-diff/build-fiber-c.sh itersum            # resume/suspend workload, fully as the Makefile does it
research/compiler-diff/build-fiber-c.sh itersum_switch     # as the Makefile: no wasm-opt for *_switch; then: reorder tags,
                                                           # re-assemble, re-merge, patch 0xE5->0xE6 as in section 2.3

# 2. distilled workload
(cd research/compiler-diff && ./mk-pingpong.sh 1000 && ./mk-pingpong.sh 1000000 && ./mk-pingpong.sh 10000000)
wasm -i research/compiler-diff/pingpong.wast               # oracle: both assert_returns pass

# 3. run / time
/usr/bin/time -f "%e s %M KB" $WT run $F --invoke main pingpong_10000000.wasm
/usr/bin/time -f "%e s %M KB" $WZ --ext:stack-switching --mode=spc pingpong_10000000.wasm

# 4. code
setarch x86_64 -R $WZ --ext:stack-switching --mode=spc -tk -ta --colors=false pingpong_1000.wasm > trace.txt
$WT compile $F -O opt-level=2 --emit-clif clif/ pingpong_1000.wasm -o pingpong_1000.cwasm && $WT objdump --addresses --bytes --addrmap=true pingpong_1000.cwasm

# 5. dynamic instruction counts inside Wizard's runtime
FUNC=X86_64Runtime.runtime_handle_switch NCALLS=3 gdb -batch -x research/compiler-diff/count-insns.py \
    --args $WZ --ext:stack-switching --mode=spc pingpong_1000.wasm
```
---

## 7. Adapting Wizard to Wasmtime's mechanism without rebuilding Wizard

*Added after the verification pass (V2).* This is a design brainstorm, not a plan of record.
It starts from what the measurements say the cost is, keeps everything about Wizard that is
not on the hot path, and copies from Wasmtime only the parts that are.

### 7.1 Where the 1 563 instructions of a Wizard `suspend` go

Same gdb method as §3.2, nested calls counted inclusively, itersum's `suspend $yield` (one i32,
handler one link up, all frames SPC):

| Callee inside `runtime_handle_suspend` | Instructions | Share | What it is for |
|---|---|---|---|
| `Runtime.unwindStackChain` | 1 096 | 70 % | walk parents looking for a handler |
| ↳ `X86_64Stack.tryHandleSuspension` | 1 024 | 66 % | per parent: find the handler and redirect |
| ↳↳ `X86_64SpcModuleCode.lookupTopPc` | **501** | 32 % | recover the parent's bytecode `pc` from its return address (`X86_64Frames.v3:128-136`) |
| ↳↳ `FuncDecl.findHandler` | 145 | 9 % | linear scan of the function's handler table for that `pc` and tag |
| ↳↳ rest of `tryHandleSuspension` | ≈ 380 | 24 % | frame handle, `writeSpcState`, `redirectToHandlerStub` (two table lookups), `vsp` reset |
| `X86_64Stack.popN` | **293** | 19 % | pop the one-value payload into a fresh `Array<Value>` |
| `X86_64Stack.pushN` + `push(Cont)` | 84 + 51 | 9 % | re-push payload and continuation on the handler's value stack |
| `bind([])` 10, `pushRspPointer` 11, state stores, tracing checks | ≈ 40 | ≈ 3 % | bookkeeping |

`runtime_handle_switch` (1 601) has the same shape: `tryHandleSwitch` → `lookupTopPc` +
`findHandler`, two `popN`s, `pushN` + `push`. **Nothing in these tables is the stack switch.**
The switch is the six-instruction stub. What Wizard pays for is *finding out where to go*
(two thirds) and *moving the payload through Virgil heap objects* (a quarter).

Wasmtime avoids both by construction: the resumer *installs* the handler list before switching
(so the suspender never has to reverse-map a return address to a `pc`), and payloads move
through a fixed buffer the compiler addresses directly.

### 7.2 Constraints that should stay fixed

- **One `X86_64Stack` for every tier.** The interpreter and SPC share the stack object, the
  free-list pool, the return-parent stub, the tagged value stack and the GC scanner
  (`X86_64Stack.scan`); mixed interpreter/SPC frames on one continuation and OSR across a
  suspend are features (GOAL.md §4.6). Any SPC fast path must leave the object in the state the
  interpreter's runtime path expects (`state_`, `parent`, `cont_bottom`, `parent_rsp_ptr`,
  `vsp`, `rsp`, `version`).
- **The tagged 32-byte value stack and the 104-byte frame** are how SPC talks to the GC; SPC has
  no stack maps. A stack that is *suspended* will be scanned, so every live slot must be in
  memory with its tag at the suspend point. `emitSaveAll` before a `suspend`/`switch` stays
  (it is ≈4–7 stores here; it is not where the time goes).
- **Unboxed continuations `(stack, version)`** — the inline `resume` already checks and bumps
  the version in three instructions; keep it.
- **Handler stubs + return-address rewriting** as the *dispatch* mechanism. Wasmtime's
  `br_table` is not cheaper than a single store of a stub address into the resumer's return slot;
  what is expensive in Wizard is computing *which* stub, not jumping to it.
- **The Virgil runtime path remains the fallback** for every case the inline path does not cover
  (interpreter frames in the chain, host frames, traps, tracing). This is what keeps the change
  from being intrusive: the fast path is an *addition* guarded by a null check, not a replacement.

### 7.3 The mechanism to copy: resumer-installed handler tables

Wasmtime's one idea worth importing is that **the `resume` site knows its handler table at
compile time and publishes it before switching**. Wizard's SPC already has everything needed to
do the same:

- Each `resume` site's handlers are known in `visit_RESUME` (`handlers: Range<SuspensionHandler>`),
  and SPC already emits one handler stub per destination and records `stub_label`
  (`SinglePassCompiler.v3:223-269`, `handler_dest_info`).
- `X86_64MacroAssembler` already emits absolute-address tables into the code stream and patches
  them when the code is placed (`jump_tables` / `setTargetAddress`, `X86_64MacroAssembler.v3:35-45`),
  and it already records embedded object references for the GC to relocate
  (`addEmbeddedRefOffset`).

Proposal: for every `resume`/`resume_throw` site, emit a static **handler table** after the
function body: `n` entries of `(tag ref, kind, stub address)` — `tag ref` is the canonical
`Tag` object (imported tags are shared objects, so identity comparison is correct across
instances; the slot is registered as an embedded ref so the moving GC keeps it right), `kind`
distinguishes `(on $t $l)` from `(on $t switch)`, `stub address` is the handler stub for that
destination (or 0 for switch handlers). Add one field to `X86_64Stack`: `spc_handlers: Pointer`
(plus the count, or a terminator). The inline `resume` sequence gains **one store**
(`curStack.spc_handlers = &table`) and the return-parent stub / handler stubs gain one store to
clear it; interpreter-tier resumes leave it null.

This is exactly what `parent_csi.handlers` + `first_switch_handler_index` are in Wasmtime, but
in Wizard's terms and without the per-`resume` copying of tag addresses into a stack slot
(Wasmtime builds the list at run time on every `resume`; a static table costs nothing per
resume beyond the one pointer store).

### 7.4 Staged plan

**Stage 1 — keep the runtime call, remove its expensive parts (≈ 1 500 → ≈ 300 instructions; no ABI change).**

1. `tryHandleSuspension`/`tryHandleSwitch`: if `parent.spc_handlers != null`, scan that table
   (tag identity compare, `kind` filter) and take the stub address from it; only fall back to
   `lookupTopPc` + `findHandler` when the field is null (interpreter frame, or old code).
   Removes 501 + 145 + most of the 380. Touch points: `X86_64Stack.v3:214-265`, `visit_RESUME`
   (one store), the return-parent stub and the handler stubs (one store each), the table emitter.
2. `runtime_handle_suspend`/`switch`: replace `popN`/`pushN`/`push(Cont)` with a raw slot copy
   between value stacks — the payload is already tagged and contiguous at `[vsp − n×32, vsp)`,
   and `emit_value_copy` shows the copy is six instructions per value. `Value`-level pops are
   needed only for tracing. Removes ≈ 400 instructions and, more importantly, **the per-op heap
   allocation** (§3.1's 718 MB, §5.5's GC crash in the interpreter).
3. Drop `bind([])`, the trace `if`s and the dummy-word protocol (`pushRspPointer(NULL)` +
   `add [curStack.rsp],8` in the stub) by having the runtime return the target stack in `rax` and
   letting the stub use it — cosmetic, but it removes two memory round trips per switch.

Expected: `suspend`/`switch` at roughly the cost of `resume` plus a call, i.e. ≈ 3–5× faster
than today, still a runtime call, still safe for mixed tiers because the fallback is the current
code.

**Stage 2 — inline `suspend` and `switch` in SPC when the fast path applies (Wasmtime's shape; ≈ 60–100 instructions).**

`visit_SUSPEND` emits: spill (as now) → `stack = curStack` → loop: `parent = stack.parent; if
(parent == 0) goto slow; table = parent.spc_handlers; if (table == 0) goto slow; for each entry:
if (entry.tag == Tag(tag_index) && entry.kind == SUSPEND) goto found; stack = parent` →
`found:` copy payload slots to `[parent.vsp]` and bump `parent.vsp` (`emit_cont_mv`), push the
`(stack, version)` continuation slot, write `stack.state = SUSPENDED`, `stack.cont_bottom =
child-of-parent`, `bottom.parent = 0`, `*[parent.rsp] = entry.stub` (the return-address
rewrite — one store), `curStack = parent`, `mov rsp,[parent.rsp]; pop rbp; jmp rbp`. `slow:`
is today's call. The `Tag` object for `tag_index` is loaded from `instance.tags[tag_index]`
(two loads) so no tag pointer is baked into code except in the tables.

`visit_SWITCH` is the same search with `kind == SWITCH`, followed by the splice
`runtime_handle_switch` does today (five stores: `bottom.parent`, `bottom.parent_rsp_ptr`
value copy, `prev.parent = 0`, `*prev.parent_rsp_ptr = 0`, `curStack = target`) and the payload
copy into the target's value stack; the target continues at its own resume address via the
stub, exactly as today.

What this does *not* need from Wasmtime: the control context in the stack memory (Wizard's
`rsp` field plus `parent_rsp_ptr` already play that role), `last_ancestor` (`cont_bottom` is
it), the four-word limits dance (Wizard has no stack-limit checks in compiled code; overflow is
the guard page), fat pointers (the XMM pair is already 16 bytes and needs no `i128` shuffles),
`br_table` dispatch, and the `VMHostArray` payload buffers (the value stack is the buffer).

Expected: `suspend`/`switch` at ≈ 60–100 instructions, comparable to Wasmtime's 51/140; on
`pingpong` that is the difference between 117 ns and something in the 10–20 ns range per
switch, i.e. most of the 19×.

**Stage 3 — only if profiling still says so.**

- `resume`'s `emit_cont_mv` copies 32 bytes + a tag byte per value through a loop; for the
  common 1–3 value case an unrolled copy or, as in Wasmtime, storing arguments straight into the
  child's value stack from registers would save a few instructions per value — minor.
- `cont.new` (516 instructions, pooled) is already cheaper than Wasmtime's `mmap` path and is
  not on the switch-heavy hot paths; leave it.
- The interpreter tier keeps the runtime path; if Stage 1 lands, it benefits too.

### 7.5 Risks and how the fallback contains them

- **GC and moving `Tag` objects**: the static tables hold object references in code; SPC's
  existing embedded-ref mechanism (`addEmbeddedRefOffset`) is built for exactly this. If that
  proves awkward, compare *stable tag ids* instead (e.g. a per-`Tag` `u32` assigned at
  instantiation) at the cost of one extra load per entry.
- **Stale `spc_handlers`**: the field must be cleared whenever a resume site is left — normal
  return (return-parent stub), suspension (handler stub), trap/unwind (`STACK_UNWIND_STUB`).
  A stale non-null pointer would make the inline search read a table for the wrong site; the
  safe default is to clear it in `emit_switch_to_stack`'s caller before the `call` and set it
  again only for the duration of the child's run — i.e. set just before `call stub_resume`,
  clear right after it returns, which the existing "reload regs" landing pad can do in one store.
- **Mixed tiers / host frames**: any null in the chain sends the inline path to the runtime,
  which behaves exactly as today. Correctness of the inline path can be tested by running
  Wizard's existing `ext:stack-switching` regress suite in `jit` mode with the fast path forced
  on and off (`--mode=int` vs `spc` already gives the differential oracle used in §2.4, and the
  reference interpreter is the third).
- **`resume_throw` / exceptions through a suspended frame** are untouched (they stay on the
  runtime path: `runtime_resume_throw_ref` → `stack.throw`).
- **Bugs found here that are prerequisites**: §5.2 (validator immediate order) blocks any
  `resume_throw` workload and is still open; §5.4 (SPC crash on the fiber-c switch module) and
  §5.5 (interpreter GC crash) are both root-caused and fixed in
  [`wizard-bugs/`](wizard-bugs/README.md), each with a `.bin.wast` regression test, so the
  fiber-c switch benchmarks can now serve as the acceptance test. §5.5's GC-unsafe window is
  worth keeping in mind for Stage 1.2: removing the per-switch allocation would hide it rather
  than fix it.

### 7.6 What to measure to validate the design

The same three numbers as this document: `count-insns.py` on `runtime_handle_suspend`/`switch`
after Stage 1 (target: < 300), the static length of the inline sequences after Stage 2 (target:
< 120 for `switch`, < 80 for `suspend`), and the two per-iteration wall-clock numbers of §3.1
(target: within 2× of Wasmtime on `itersum` and `pingpong`). Because both stages are guarded
fast paths, each can be A/B'd with a runtime flag against the unchanged code on the same binary.


---

## 8. Verification log (V1 → V2)

An independent pass re-checked every `path:line` and code claim of §0–6 against the pinned
sources and the raw listings (108 items). Corrected in V2:

1. `stack_switch` is **ten** instructions (eight `mov`s, `lea`, `jmp`), not eight; it clobbers
   every register **except `rdi`**.
2. `benchmark/fiber-c/Makefile` never runs `wasm-opt` on `*_switch` modules; the binaryen assertion was
   triggered by an extra `-O2` step in the first `build-fiber-c.sh` (now mirrors the Makefile).
3. Mode descriptions are at `X86_64Target.v3:27-28`; the CLIF region for the stack chain in the
   pingpong file is `region4`; `wasm_of_ocaml`'s native-effects runtime is `effect-native.wat`;
   the `*_switch` example list includes `hello_switch.c`; `instructions.rs:2150` is a `NOTE`.
4. Sub-counts: fat-pointer shuffles are 13–17 instructions each (30 for the pair in `switch`),
   the control-context copy is 14 (+2 loads); the Wasmtime `suspend` has 7 instructions after
   the `jmpq` on the normal path; the `resume` return/suspend legs share 14 instructions.
5. Handler stubs span `SinglePassCompiler.v3:223-269`; the "everything in memory" merge state
   applies only when no branch reached the label first; the stub bumps `[curStack.rsp]`, not
   `[rsp]`; `resume`'s "≈60" is a static count; `wizeng` passes `Values.default` for `main`'s
   parameters (`WasmMode.v3:151`).
6. Evidence the pass found missing was added: gdb dumps for the fiber-c trampoline (`#12`) and
   the itersum functions, the `func[N].target_code` lines in the stored traces,
   `pingpong.wast`, and the pre-reorder module with the `E4 09 02 00` encoding.

Not verifiable without re-running the engines (and therefore taken as measured): §3.1 times,
§3.2 dynamic counts, the crash messages in §5.
