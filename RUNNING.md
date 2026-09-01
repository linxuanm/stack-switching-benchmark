# Running the benchmark suites on the Wasm reference interpreter

This repo collects four benchmark suites as submodules and documents how to get
each of them running under the **stack-switching / WasmFX reference
interpreter**.

```
benches/        ocaml-bench/benches         OCaml micro-benchmarks (incl. 17 effect benchmarks)
macro-benches/  ocaml-bench/macro-benches   OCaml macro-benchmarks (23 real tools)
angstrom/       inhabitedtype/angstrom      Parser combinators (no effects; a neutral baseline)
fiber-c/        wasmfx/fiber-c              Fibers in C, Asyncify vs WasmFX backends
```

## Toolchain on this machine

| Tool | Location | Notes |
|---|---|---|
| `wasm` | `~/.opam/default/bin/wasm` → `~/workspace/specfx/interpreter` | Reports `wasm 3.0.0`. This is the **WasmFX-merged spec repo**, so `cont.new` / `resume` / `suspend` / `switch` are always available — there is no feature flag to enable. |
| `wasm_of_ocaml` | `~/workspace/js_of_ocaml/_build/default/compiler/bin-wasm_of_ocaml/wasm_of_ocaml.exe` | Built from **master** (`27e40dda`). |
| binaryen | `~/dev_path/binaryen/bin` | v124, has `--enable-stack-switching`. |
| wasmtime | `~/.wasmtime/bin/wasmtime` | For real timing runs. |

The scripts take these from `WASI_SDK`, `BINARYEN`, `WASM_INTERP` and `WASM_OF_OCAML`
(environment or a gitignored `build.env`; template `build.env.example`) and stop with a
message when one is unset — the paths above are this machine's, not defaults.

### The js_of_ocaml situation

The local checkout was on a `native-effects` branch (a fork,
`matthew-mojira/js_of_ocaml`). That work **has** landed on upstream
`ocsigen/js_of_ocaml` master, rebased under new SHAs (`d15762ee Effects based on
Stack Switching proposal`, `17d204ee Update Wasm linker to support stack
switching instructions`), so the branch is no longer the place to build from.
Master has been fast-forwarded 665 commits to `27e40dda` and rebuilt.

This matters for two concrete reasons:

1. **Master adds `--effects=native`.** The old branch only had
   `--effects=jspi`. On master the effects backends are
   `jspi | cps | native | disabled`; `native` is the one that emits core
   stack-switching instructions.
2. **Master emits the new exception handling instructions.** The old branch
   emitted *legacy* EH (`try` / `catch`, opcodes `0x06` / `0x07`), which the
   reference interpreter rejects outright — `binary/decode.ml:393` reads
   `| 0x06 | 0x07 as b -> illegal s pos b`. Feeding it a module built from the
   old branch fails with `decoding error: illegal opcode 06`. Master emits
   `try_table` instead, which decodes and validates cleanly.

> The opam switch still has `js_of_ocaml*` **pinned to the `native-effects`
> branch** (`git+file:///home/linxuanm/workspace/js_of_ocaml#native-effects`).
> The pin names a branch, so it is unaffected by which branch is checked out.
> The tooling here calls the freshly built `wasm_of_ocaml.exe` by absolute path
> and does not use the pinned packages. Re-pin to `#master` if you want
> `opam install` to pick this up.

## Four things to know about the reference interpreter

These are not documented prominently and each one costs an afternoon:

1. **It has no WASI.** The only host modules it registers are `spectest` and
   `env` (`main/main.ml:11-12`), and `env` provides just `abort` and `exit`.
   Anything built with `--enable wasi` therefore cannot be instantiated as-is.
2. **`wasm foo.wasm` does not run anything.** It decodes and validates, then
   exits 0. It never instantiates, so a `start` section never fires.
3. **Every CLI argument is an independent script.** `main.ml` does
   `List.iter (fun arg -> Run.run_string arg) !args`, so
   `wasm foo.wasm -e '(invoke "_start")'` fails with
   `no module instance defined` — the module from the first argument is not in
   scope for the second. Nesting does not help either: `(input "foo.wasm")`
   *inside* a script runs in its own scope.
4. **To actually execute, you need one `.wast` script** that contains both the
   module and the commands driving it. `(module binary "\00\61\73\6d…")`
   followed by `(invoke "_start")` works.

## The OCaml → reference interpreter pipeline

`tools/ocaml-refrun.sh` implements the whole path and is the quickest way to see
it work:

```bash
eval $(opam env)
./tools/ocaml-refrun.sh benches/multicore/multicore-effects/effect_throughput_perform.ml 200
# 200 iterations took 0.001000
# 5000.0ns per iteration
```

The stages are:

| Stage | Command | Why |
|---|---|---|
| 1 | `ocamlfind ocamlc prog.ml -o prog.byte` | `wasm_of_ocaml` consumes OCaml **bytecode**. |
| 2 | `wasm_of_ocaml compile --effects=native --enable wasi prog.byte -o prog.js` | Emits `code.wasm` using `cont.new` / `resume` / `suspend` and `try_table`. |
| 3 | `tools/wasi_shim_gen.py` + `wasm -d -i shim.wat -o shim.wasm` | Generates a `wasi_snapshot_preview1` implementation. Note the reference interpreter assembles its own shim. |
| 4 | `wasm-merge prog.wasm "main" shim.wasm "wasi_snapshot_preview1" -o merged.wasm` | Fuses the shim onto the module's exported memory, internalising the WASI imports. **Order matters** — main must come first, or the shim's `(import "main" "memory")` does not resolve and you get two memories. |
| 5 | `tools/wasm2wast.py merged.wasm -o prog.wast` | Wraps as `(module binary …)` + `(invoke "_start")`. |
| 6 | `wasm -i prog.wast` | Runs. |

### What the shim provides

`tools/wasi_shim_gen.py` emits 24 WASI entry points. Three are more than stubs:

- **`fd_write`** walks the iovecs and emits each byte via `spectest.print_i32`,
  which the interpreter does provide. Output therefore arrives as one decimal
  byte per line; `ocaml-refrun.sh` decodes it back to text at the end.
- **`args_get` / `args_sizes_get`** serve a real `argv`, baked in at generation
  time. This matters because every benchmark here takes its problem size from
  `Sys.argv.(1)` and falls back to a *huge* default otherwise —
  `effect_throughput_perform` defaults to 1,000,000 iterations.
- **`clock_time_get`** is a virtual monotonic clock that advances 1 ms per
  query. The interpreter has no real clock, and a deterministic one keeps runs
  reproducible. **Any timing a benchmark prints is therefore fictional.**

### Libraries with C stubs

An OCaml library whose externals are C stubs needs a wasm runtime shim.
`tools/bigstringaf_runtime.wat` is a worked example for `bigstringaf` (which
angstrom depends on, and which ships only a JavaScript runtime):

```bash
EXTRA_RUNTIME=$PWD/tools/bigstringaf_runtime.wat ./tools/ocaml-refrun.sh driver.byte 3
```

The trap: `wasm_of_ocaml` merges the prelinked runtime **and every user-supplied
runtime file under the single module name `env`**. Importing
`caml_bigstring_blit_ba_to_bytes` from `"bigstring"` — the runtime *source file*
these live in — leaves an unresolvable import in the final module. Import from
`"env"`.

## Per-repo notes

### `benches/` — the best fit by far

196 programs from 117 build scripts; `manifest.yml` is the authoritative
*(program, script, args)* list. Single files, stdlib only, no vendored
dependency tree.

**The significant files for stack switching** are all in
`multicore/multicore-effects/` (17 programs):

| File | Stresses |
|---|---|
| `effect_throughput_perform.ml` | Full perform→resume round trip. The headline number. |
| `effect_throughput_perform_drop.ml` | Perform plus the cost of collecting a *dropped* continuation. |
| `effect_throughput_val.ml` | Handler install/teardown with no `perform` at all. |
| `algorithmic_differentiation.ml` | Reverse-mode AD via deep handlers — the realistic one. |
| `rec_eff_{fib,tak,ack,evenodd,motzkin,sudan}.ml` | Handler installed at every recursive call, never triggered. |
| `rec_seq_{fib,tak,ack,evenodd,motzkin,sudan}.ml` | The pure-recursive baselines to subtract. |
| `eratosthenes.ml` | Sieve as a pipeline of communicating handlers. |

The `rec_eff_*` / `rec_seq_*` pairing is the point: same computation, one with a
handler frame per call, one without.

Verified working: `effect_throughput_perform` (prints its result),
`algorithmic_differentiation` (asserts internally; runs clean).

Also relevant, needing opam packages at build time:
`with_packages/test_sched` and `with_packages/thread-lwt` (Lwt scheduling),
`with_packages/chameneos`. `simple/` and `simple/stdlib` are effect-free
baselines for measuring what `--effects=native` costs ordinary code.

### `angstrom/` — a neutral baseline

Angstrom uses **no effects at all** (`grep -rn "Effect\." lib/` is empty). Its
value here is as a control: under `--effects=native` the whole program is
compiled with the stack-switching calling convention, so angstrom answers *"what
does the native effects backend cost code that never performs an effect?"*

**Significant files:**

- `benchmarks/pure_benchmark.ml` — the real benchmark, but it needs `core`,
  `core_bench` and file I/O, none of which survive this pipeline. Not usable
  as-is.
- `examples/RFC7159.ml` (JSON) and `examples/RFC2616.ml` (HTTP) — the parsers
  the benchmark drives. These depend only on angstrom and **are** usable.
- `benchmarks/data/` — `twitter{1,10,20}.json`, `http-requests.txt`. Embed the
  payload as a string literal rather than reading it; the shim has no filesystem.
- `lib/parser.ml`, `lib/angstrom.ml` — the CPS core, if you want to see what the
  backend is actually compiling.

Verified working: a driver parsing an embedded JSON document with `RFC7159.json`
via `Angstrom.parse_string`, built against the submodule's own
`_build/default/lib/angstrom.cma`, with `tools/bigstringaf_runtime.wat` supplied.

```bash
cd angstrom && dune build lib/angstrom.cma examples/RFC7159.cma && cd ..
ocamlfind ocamlc -package bigstringaf -linkpkg \
  -I angstrom/_build/default/lib/.angstrom.objs/byte \
  -I angstrom/_build/default/examples/.RFC7159.objs/byte \
  angstrom/_build/default/lib/angstrom.cma \
  angstrom/_build/default/examples/RFC7159.cma driver.ml -o driver.byte
EXTRA_RUNTIME=$PWD/tools/bigstringaf_runtime.wat ./tools/ocaml-refrun.sh driver.byte 3
```

### `macro-benches/` — not a reference-interpreter target

23 real tools (menhir, coq, frama-c, infer, ocamlformat, …) with every
dependency vendored via opam-monorepo. `make setup` pulls a duniverse first.

**Significant files:** `benchmarks/manifest.yml` (the program list, with the
`small`/`default`/`large` input ladder), `benchmarks/<tool>/<tool>.build.sh`,
and `docs/benchmarks/<tool>.md`.

Why it does not fit: the `default` rungs are sized for a native runtime — a
771 MB JSON document for `yojson`, a 256 MB payload for `decompress`, 27 GB peak
RSS for `sedlex`'s large rung. At the interpreter's throughput (below) these are
years, not minutes. Several are additionally impossible: `zarith` needs GMP,
`owl` needs OpenBLAS, `pplacer` needs GSL — C libraries with no wasm runtime.

If you want one anyway, the pure-OCaml candidates with the smallest `small`
rungs are `menhir`, `sedlex`, `ocamlformat` and `alt-ergo`. Treat them as
correctness tests, not measurements.

Worth noting: `benchmarks/js_of_ocaml/jsoo.build.sh` benchmarks the jsoo
compiler itself — a curiosity here, given jsoo is the tool being used.

### `fiber-c/` — already reference-interpreter aware, but blocked locally

**Significant files:**

- `examples/*.c` — the benchmarks. `config.yml` lists the active set:
  `itersum`, `sieve`, `state`, `treesum`, `c10m`, `pi`, `skynet`, `scheduler`,
  plus `*_switch.c` variants (`itersum`, `treesum`, `pi`, `scheduler`) that
  exercise `switch` rather than `resume`/`suspend`.
- `src/wasmfx/imports.wat.pp` — **the interesting file.** The WasmFX fiber
  implementation itself, in hand-written wat: `(cont $ft1)` types, a `$yield`
  tag, a growable `(table $conts)` of continuations, and the shadow-stack
  save/restore. `src/wasmfx/wasmfx_impl.c` is the C side.
- `src/asyncify/asyncify_impl.c` — the Binaryen Asyncify backend it is measured
  against.
- `inc/fiber.h` — the API both backends implement.
- `bench.py` / `build.py` / `config.yml` — the harness.

The Makefile **already uses the reference interpreter**, but only as an
assembler:

```make
fiber_wasmfx_imports.wasm: src/wasmfx/imports.wat
	$(WASM_INTERP) -d -i $< -o $@
```

`-d` is *dry* — decode and write out, do not run. The benchmarks themselves are
executed by wasmtime, d8 or wizard (`config.yml`), never by the interpreter.

**Blocked locally:** the build needs WASI-SDK 30.0, and there is no wasi-sdk on
this machine (`make.config` expects everything under `ROOT=/opt/wasmfx`, which
does not exist). Binaryen and the reference interpreter are present. To proceed,
either install WASI-SDK and point `ROOT` at it, or use the
[benchtainer](https://github.com/wasmfx/benchtainer) image the README suggests.

Once built, `out/*_wasmfx.wasm` can be run on the reference interpreter with the
same technique as the OCaml side — it is a WASI module, so it needs the shim and
the `.wast` wrapper:

```bash
python3 tools/wasi_shim_gen.py itersum 1000 -o shim.wat
wasm -d -i shim.wat -o shim.wasm
wasm-merge <flags> out/itersum_wasmfx.wasm "main" shim.wasm "wasi_snapshot_preview1" -o merged.wasm
python3 tools/wasm2wast.py merged.wasm -o itersum.wast
wasm -i itersum.wast
```

One caveat specific to fiber-c: `imports.wat` imports `main`'s memory **and**
`__indirect_function_table` and `__stack_pointer`, so the module is already the
product of a `wasm-merge`. Merging the WASI shim on top is a second merge, and
`--enable-multimemory` must stay off for the memories to fuse.

## The thing to be honest about: speed

The reference interpreter is written for clarity, not speed. Measured on
`effect_throughput_perform`:

| | per perform/resume round trip |
|---|---|
| `ocamlopt` native | 62 ns |
| `wasm` reference interpreter | ~120 µs |

That is roughly **1,900× slower**, or about 8,300 effect round-trips per second.
A benchmark whose default is 1,000,000 iterations takes two minutes native and
about four hours here.

**So: do not use the reference interpreter for timing.** Use it as a semantics
oracle — it is the executable definition of the proposal, so if your generated
code runs correctly here, the code is right and any engine disagreement is an
engine bug. Then measure with wasmtime, wizard or d8, exactly as `fiber-c`'s
`bench.py` already does.

Practical sizes: pass explicit small arguments (`effect_throughput_perform 200`,
`algorithmic_differentiation 20`) rather than accepting the defaults.

## Tools in this repo

| File | Purpose |
|---|---|
| `tools/ocaml-refrun.sh` | End-to-end: `.ml` (or pre-linked `.byte`) → run on the reference interpreter. `EXTRA_RUNTIME=` adds runtime `.wat` files; `OUTDIR=` keeps intermediates. |
| `tools/wasi_shim_gen.py` | Generates the `wasi_snapshot_preview1` shim, with a real `argv` and a virtual clock. |
| `tools/wasm2wast.py` | Wraps a `.wasm` as a `.wast` script the interpreter will actually execute. |
| `tools/bigstringaf_runtime.wat` | Worked example of a wasm runtime shim for a library with C stubs. |
