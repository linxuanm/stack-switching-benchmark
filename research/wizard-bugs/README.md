# Two crashing bugs in upstream Wizard (`4a539337`), root-caused

Follow-up to [`../COMPILER_DIFF.md`](../COMPILER_DIFF.md) §5.4 and §5.5, which recorded both
crashes as reproducible but not root-caused. Both are now root-caused, fixed, and covered by a
`.bin.wast` test. Everything here is against the pinned submodule
`dependencies/wizard-engine` at `4a539337`, target `x86-64-linux`, `--ext:all`.

| | Bug A | Bug B |
|---|---|---|
| Where | `src/engine/compiler/SinglePassCompiler.v3` | `src/engine/x86-64/X86_64Runtime.v3` |
| Instruction | `resume_throw` / `resume_throw_ref` | `switch` |
| Tiers hit | `spc`, `jit` (interpreter fine) | all three (`int`, `jit`, `spc`) |
| Symptom | `!NullCheckException in Runtime.TABLE_GET()` | `!GcError: invalid reference … in NativeStackScanner.scanStack()`, or a silently wrong result |
| Kind | register clobber in the lowering | GC-unsafe window in the runtime |
| Fix | `0001-spc-resume_throw-arg-clobber.patch` | `0002-switch-gc-unsafe-detach.patch` |
| Test | `tests/resume_throw_regalloc0.{wast,bin.wast}` — ~0.03 s, for `test/regress/ext:stack-switching/` | `tests/switch_gc0.{wast,bin.wast}` — ~7 s, better suited to `test/stress/` |

The two patches are independent, and verified so: built with only `0001`, bug A's test passes in
all three tiers while bug B's still aborts; built with only `0002`, the reverse. With both applied, `test/regress.sh` is **1438 / 1438 in each of `int`, `jit` and `spc`**,
and the original report from COMPILER_DIFF §5.4 — `wizeng --mode=spc
compiler-diff/itersum_switch_wasmfx.wasm` — prints `499500` instead of trapping.

---

## Bug A — `resume_throw` passes the instance where the runtime expects the continuation stack

### What breaks

`visit_RESUME_THROW` (and identically `visit_RESUME_THROW_REF`) loads the runtime arguments in this
order:

```v3
masm.emit_validate_and_consume_cont(contStack, cont);   // contStack := cont.stack
state.emitSaveAll(resolver, SpillMode.SAVE_AND_FREE_REGS);
…
masm.emit_get_curstack(regs.runtime_arg0);              // clobbers arg0
…
emit_load_instance(regs.runtime_arg1);                  // clobbers arg1
masm.emit_mov_r_r(ValueKind.REF, regs.runtime_arg2, contStack);   // ← too late
```

`contStack` comes from `allocTmp(ValueKind.REF)`, so the register allocator may place it in
`runtime_arg0` or `runtime_arg1`. When it does, the argument-setup sequence overwrites it *before*
the copy into `runtime_arg2`, and `runtime_handle_resume_throw` receives the module `Instance` as
its `contStack` parameter. Nothing checks: the call boundary is raw machine code, so the `Instance`
is used as an `X86_64Stack`.

### Evidence

`--mode=spc -tk -ta` on the test module, stock build — `contStack` lands in `rdx`, which is
`runtime_arg1`:

```asm
pextrq rdx, xmm1, 0        ; contStack := cont.stack      → rdx
…
mov    rdx, [rsp+80]       ; emit_load_instance(arg1=rdx) → CLOBBERS contStack
mov    rcx, rdx            ; arg2 := rdx                  → arg2 = instance   (bug)
xor    r8d, r8d            ; arg3 := tag 0
call   rbp                 ; runtime_handle_resume_throw(…, instance, instance, 0)
```

With the patch the copy moves ahead of the clobber and `arg2` stays the continuation stack:

```asm
pextrq rdx, xmm1, 0        ; contStack → rdx
mov    rcx, rdx            ; arg2 := contStack
…
mov    rdx, [rsp+80]       ; arg1 := instance
```

gdb on the stock build, breaking at `X86_64Runtime.runtime_handle_resume_throw` and dumping the
`Instance` around the call:

```
arg0(rsi,curStack)=0x8455ae8 arg1(rdx,instance)=0x8454f78 arg2(rcx,contStack)=0x8454f78
--- instance BEFORE ---   0x8454fb0: 0x0000000008455040
--- instance AFTER  ---   0x8454fb0: 0xfffffffffffffff8
```

`arg1 == arg2`. The stack walk in `X86_64Stack.throw` reads `this.rsp` (offset +0x38) out of the
`Instance`, walks garbage, and `unwind` writes `-8` back into that same field — which in the
`Instance` is `tables`. `Runtime.TABLE_GET` (`src/engine/Runtime.v3:17`,
`instance.tables[table_index]`) then dereferences it and reports a spurious null check. Any module
whose `resume_throw` site puts the continuation operand under enough register pressure, and which
later touches the clobbered field, hits this; the fiber-c `itersum_switch` module was the original
report.

### Fix

Move the `contStack → runtime_arg2` copy to immediately after `emitSaveAll`, before any of the
other argument registers are written, in **both** `visit_RESUME_THROW` and
`visit_RESUME_THROW_REF`. The copy is then correct whichever register the allocator picked.

### Test

`tests/resume_throw_regalloc0.wast` — a worker suspends on `$yield`, the handler cancels it with
`resume_throw`, and the module then reads `(table.get $t 0)`. Two dead `i32.add`s before the
operands raise register pressure so `contStack` lands in an argument register. The tag is index 0
with no handlers, which is the one encoding that the *separate* `resume_throw` immediate-order bug
(COMPILER_DIFF §5.2, `CodeValidator.v3:1290` vs `BytecodeIterator.v3:785`) reads identically both
ways, so this test does not depend on that bug being fixed first.

Stock `4a539337`: `int` passes, `jit` and `spc` fail with `NullCheckException in
Runtime.TABLE_GET()`. Patched: all three pass. Runs in well under a second.

Only the non-`_ref` variant is covered: this repo's reference interpreter predates
`resume_throw_ref` entirely (`dependencies/specfx` `15ec7d15` has no such token), so no `.bin.wast`
can be produced for it here. The defect and the fix in `visit_RESUME_THROW_REF` are textually
identical, and a matching test can be generated upstream.

---

## Bug B — `switch` detaches the switching stack before its last allocation

### What breaks

`X86_64Runtime.runtime_handle_switch` ends with:

```v3
prev.parent = null;                                  // ← detach
prev.parent_rsp_ptr.store<Pointer>(Pointer.NULL);    // ←
curStack = X86_64Stack.!(target_stack);
curStack.state_ = StackState.RUNNING;
curStack.pushN(vals);
curStack.push(Value.Cont(this_cont));                // ← allocates
```

`Value.Cont(this_cont)` allocates, and the runtime call is still executing on `prev`'s native
stack. A collection triggered by that allocation walks the native stack from the current `rsp` and
crosses to ancestor stacks through `parent` / `parent_rsp_ptr` — the links that were just nulled.
The walk therefore stops after the current frame and never reaches the initial stack, so every root
in an ancestor frame is missed. The one that matters is `this` in `X86_64Stack.resume`'s frame: the
outermost continuation stack.

`runtime_handle_suspend`, twenty lines above, does the same detach **after** its `pushN`/`push` —
which is exactly why `suspend` workloads never showed this and only `switch` did.

### Evidence

Stock build under gdb, on the same producer/consumer module at a smaller iteration count (10 M,
no jitter — enough to reach four collections); counting collections and the number of native
frames each one scans, and watching the slot that the fatal error names (`0x081FFAB8`, the `this`
slot of `X86_64Stack.resume` on the initial stack):

```
GC #1 start: [0x81FFAB8]=0x8453c38    GC #1 scanned 12 native frames
GC #2 start: [0x81FFAB8]=0x1e222730   GC #2 scanned 14 native frames
GC #3 start: [0x81FFAB8]=0x8422768    GC #3 scanned  1 native frame     ← walk truncated
GC #4 start: [0x81FFAB8]=0x8422768    GC #4 scanned  4 native frames (then FATAL)
```

GC #1 and #2 forward the slot (space0 → space1 → space0). GC #3 fires inside the window, scans a
single frame because the parent link is null, and leaves the slot untouched. GC #4 reads it, finds
a pointer into the half that GC #3 abandoned, and aborts:

```
!GcError: invalid reference @ 0x00000000081FFAB8 -> 0x0000000008422768
	in Semispace.scanSlot()      … rt/gc/SemiSpace.v3 @ 104
	in RiGc.scanRefMap()         … rt/gc/RiGc.v3 @ 230
	in NativeStackScanner.scanStack() … rt/native/NativeStackScanner.v3 @ 47
	in RiRuntime.gc()            … rt/native/RiRuntime.v3 @ 88
	in Continuations.continuationWithVersion() [UnboxedContinuation.v3 @ 30]
	in X86_64Stack.popContinuation()          [X86_64Stack.v3 @ 426]
	in X86_64Runtime.runtime_handle_switch()  [X86_64Runtime.v3 @ 182]
```

The same instrumentation on the patched build, same module:

```
GC #1: 14 frames   GC #2: 14 frames   GC #3: 12 frames   GC #4: 14 frames   → ##-ok
```

Every collection walks the full chain and the slot is forwarded each time.

The abort is not the only outcome. When the phase differs the missed root is simply lost and the
run returns a wrong answer instead — at 8 000 000 switches the stock build reports
`assert_return expected 8000000, got 0` rather than a `GcError`. Silent corruption is the more
dangerous face of this bug.

### Fix

Move the two detach statements after the last allocation, matching what
`runtime_handle_suspend` already does. Nothing else observes `prev.parent` in between.

### Test

`tests/switch_gc0.wast` — a producer/consumer pair ping-ponging with `switch` under an
`(on $yield switch)` handler, 30 000 000 iterations, ~7 s. Two details are load-bearing:

* **No value payload on the switch.** `popN` runs *before* the detach; with an empty payload it
  allocates almost nothing, so the post-detach `push` dominates the per-switch allocation and a
  collection is far more likely to land in the window.
* **A small pseudo-random allocation in the loop** (an `array.new_default` of 0–7 words on ~1 in
  32 iterations). Without it the collector phase locks to the loop period: every collection in a
  run lands at the same offset within the switch, and raising the iteration count does not help.
  Measured directly — a payload-less loop with no jitter fired from some invocations and from none
  of the others at 10 M, 20 M *and* 40 M iterations alike. With the jitter, detection climbs with
  the iteration count as it should.

Stock `4a539337`: fails from every invocation phase tried (standalone by absolute path, by
relative path, from inside `test/regress/ext:stack-switching/`, and appended to that whole
directory in one process), in **all three tiers**, 2/2 runs each — mostly `GcError`, occasionally
the wrong-result form. Patched: `##-ok` everywhere, ~6.3–7.2 s per tier. 25 M iterations was the
smallest count that still covered every phase; 10 M covered only some.

Two corrections to what `COMPILER_DIFF.md` §5.5 recorded: `spc` does **not** survive this — it
looked immune only because its GC phase did not sample the window; and the abort is not the only
outcome, a missed root can equally produce a silently wrong result.

**This guard samples the window, it does not hit it deterministically**, and its cost reflects
that: ~7 s against 0.13 s for Wizard's entire current `regress.sh`. That is why the recommendation
is `test/stress/` — which already holds exactly this kind of case (`many_stacks_gc0.wat`,
`many_resumes*.wat`) and is not wired into `test/all.sh` — rather than the regression suite. It
never produces a false failure: a patched engine passes regardless. On an unpatched engine with a
different heap size (`build.sh` uses `-heap-size=700m` on x86-64-linux) it may need a larger
iteration count to fire.

---

## Applying and verifying

```bash
cd dependencies/wizard-engine
git apply ../../research/wizard-bugs/0001-spc-resume_throw-arg-clobber.patch
git apply ../../research/wizard-bugs/0002-switch-gc-unsafe-detach.patch
source ../../env.sh && ./build.sh wizeng x86-64-linux

# bug A's test: fast
for m in int jit spc; do
  bin/wizeng.x86-64-linux --ext:all --mode=$m \
    ../../research/wizard-bugs/tests/resume_throw_regalloc0.bin.wast
done

# bug B's test: ~7 s per tier
for m in int jit spc; do
  bin/wizeng.x86-64-linux --ext:all --mode=$m \
    ../../research/wizard-bugs/tests/switch_gc0.bin.wast
done

# full suite, all three tiers
for m in int jit spc; do TEST_TARGET=x86-64-linux TEST_MODE=$m ./test/regress.sh; done
```

Drop the same commands against a stock build to see them fail: bug A's test traps in `jit`/`spc`,
bug B's aborts (or mismatches) in all three.

The tests are named for `test/regress/ext:stack-switching/`, which `test/regress.sh` runs with
`--ext:all`. `mk-tests.sh` regenerates the `.bin.wast` files from the `.wast` sources; read its
header before doing so — this repo's pinned reference interpreter emits the pre-renumbering
`switch` opcode (0xE5, patched to 0xE6 here) and cannot validate *any* of Wizard's existing
`switch*.wast` tests, so it is not a usable oracle for `switch` at this pin.

Per the repo's rules the submodule is left untouched: the fixes live here as patches, not as
commits in `dependencies/wizard-engine`.
