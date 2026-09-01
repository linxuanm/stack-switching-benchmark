#!/usr/bin/env python3
"""profile-report.py — turn the perf samples collected by runtime-compare.sh into the
"where the time goes" tables of research/FIBER_C_COMPARE.md (sections 3 and 4).

Usage: profile-report.py <out-dir>
Reads <out-dir>/runs.tsv (one line per profiled run, written by runtime-compare.sh:
  engine  bench  wasm  args  rc  wall_s  samples_file  map_file  perf_rc
rc and wall_s come from the plain run, perf_rc from the profiled run)
writes <out-dir>/REPORT.md and prints it.

Classification (address first, then symbol name):
  Wizard  — a sample inside the pregenerated interpreter/stub region (bounded by the
            `code start`/`code end` lines of `wizeng -tk`) is `pregen: <stub>`; inside an SPC
            function's `func[N].target_code` range it is `jit: wasm func[N]`; a kernel address is
            `kernel: <sym>`; otherwise the ELF symbol perf resolved.  The symbol is then mapped to
            one of the clusters in WIZARD_ROWS by the regexes below (first match wins).
  Wasmtime — perf resolves JIT frames through the perfmap (`wasm[0]::function[N]`); host code is
            whatever is in the wasmtime binary; the rest is kernel or libc.
"""
import sys, os, re, collections

# ----------------------------------------------------------------------------------------
# wasm function names: name section > exports > imports
# ----------------------------------------------------------------------------------------
def _leb(b, p):
    r = s = 0
    while True:
        x = b[p]; p += 1; r |= (x & 0x7F) << s; s += 7
        if not x & 0x80:
            return r, p

def _skip_sleb(b, p):
    while b[p] & 0x80:
        p += 1
    return p + 1

def _name(b, p):
    n, p = _leb(b, p)
    return b[p:p + n].decode('utf-8', 'replace'), p + n

def _skip_valtype(b, p):
    t = b[p]; p += 1
    if t in (0x63, 0x64):            # (ref null? <heaptype>)
        p = _skip_sleb(b, p)
    return p

def _skip_limits(b, p):
    flags = b[p]; p += 1
    _, p = _leb(b, p)
    if flags & 1:
        _, p = _leb(b, p)
    return p

def wasm_func_names(path):
    imp, exp, nsec = {}, {}, {}
    try:
        data = open(path, 'rb').read()
    except OSError:
        return {}
    if data[:4] != b'\0asm':
        return {}
    pos, nimports = 8, 0
    try:
        while pos < len(data):
            sid = data[pos]; pos += 1
            size, pos = _leb(data, pos)
            body = data[pos:pos + size]; pos += size
            if sid == 2:                                   # imports
                p = 0; cnt, p = _leb(body, p)
                for _ in range(cnt):
                    mod, p = _name(body, p); fld, p = _name(body, p)
                    kind = body[p]; p += 1
                    if kind == 0:
                        _, p = _leb(body, p); imp[nimports] = mod + '.' + fld; nimports += 1
                    elif kind == 1:
                        p = _skip_valtype(body, p); p = _skip_limits(body, p)
                    elif kind == 2:
                        p = _skip_limits(body, p)
                    elif kind == 3:
                        p = _skip_valtype(body, p); p += 1
                    elif kind == 4:
                        p += 1; _, p = _leb(body, p)
                    else:
                        break
            elif sid == 7:                                 # exports
                p = 0; cnt, p = _leb(body, p)
                for _ in range(cnt):
                    nm, p = _name(body, p); kind = body[p]; p += 1; idx, p = _leb(body, p)
                    if kind == 0:
                        exp.setdefault(idx, nm)
            elif sid == 0:                                 # custom "name" section
                nm, p = _name(body, 0)
                if nm == 'name':
                    while p < len(body):
                        sub = body[p]; p += 1; sz, p = _leb(body, p); end = p + sz
                        if sub == 1:
                            cnt, p = _leb(body, p)
                            for _ in range(cnt):
                                idx, p = _leb(body, p); fn, p = _name(body, p); nsec[idx] = fn
                        p = end
    except (IndexError, UnicodeDecodeError):
        pass
    names = dict(imp); names.update(exp); names.update(nsec)
    return names

# ----------------------------------------------------------------------------------------
# Wizard code map (output of `wizeng -tk`, see runtime-compare.sh)
# ----------------------------------------------------------------------------------------
RE_FUNC = re.compile(r'func\[(\d+)\]\.target_code: break \*0x([0-9A-Fa-f]+) disass 0x[0-9A-Fa-f]+, 0x([0-9A-Fa-f]+)')
RE_RANGE = re.compile(r'([a-z0-9 ->]+):\s+(?:break \*)?0x([0-9A-Fa-f]+)\s*-\s*0x([0-9A-Fa-f]+)')
RE_ADDR = re.compile(r'([a-z0-9 ->]+):\s+(?:break \*)?0x([0-9A-Fa-f]+)$')

def load_wizard_map(path):
    """-> (jit_ranges [(lo,hi,'jit: wasm func[N]')], pregen_ranges, code_start, code_end)"""
    jit, pregen, code_start, code_end = [], [], None, None
    if not path or path == '-' or not os.path.exists(path):
        return jit, pregen, code_start, code_end
    with open(path, errors='replace') as f:
        for line in f:
            line = line.strip()
            m = RE_FUNC.match(line)
            if m:
                lo, hi = int(m.group(2), 16), int(m.group(3), 16)
                if hi > lo:
                    jit.append((lo, hi, 'jit: wasm func[%s]' % m.group(1)))
                continue
            m = RE_RANGE.match(line)
            if m:
                pregen.append((int(m.group(2), 16), int(m.group(3), 16), 'pregen: ' + m.group(1).strip()))
                continue
            m = RE_ADDR.match(line)
            if m:
                name, addr = m.group(1).strip(), int(m.group(2), 16)
                if name == 'code start':
                    code_start = addr
                elif name == 'code end':
                    code_end = addr
                else:
                    pregen.append((addr, None, 'pregen: ' + name))
    pregen.sort(key=lambda r: r[0])
    fixed = []
    for i, (lo, hi, nm) in enumerate(pregen):
        if hi is None:
            hi = pregen[i + 1][0] if i + 1 < len(pregen) else code_end
        fixed.append((lo, hi, nm))
    jit.sort()
    return jit, fixed, code_start, code_end

# ----------------------------------------------------------------------------------------
# perf script -F ip,sym,dso  ->  (ip, sym, dso)
# ----------------------------------------------------------------------------------------
def read_samples(path):
    out = []
    with open(path, errors='replace') as f:
        for line in f:
            parts = line.split()
            if len(parts) < 2:
                continue
            try:
                ip = int(parts[0], 16)
            except ValueError:
                continue
            dso = parts[-1].strip('()') if len(parts) > 2 else ''
            sym = ' '.join(parts[1:-1]) if len(parts) > 2 else parts[1]
            out.append((ip, sym, dso))
    return out

KERNEL_IP = 0xffff000000000000

def wizard_symbol(ip, sym, dso, jit, pregen, code_start, code_end):
    if ip >= KERNEL_IP or 'kernel' in dso:
        return 'kernel: ' + sym
    if code_start is not None and code_end is not None and code_start <= ip < code_end:
        for lo, hi, nm in pregen:
            if lo <= ip < (hi or 0):
                return nm
        return 'pregen: other'
    for lo, hi, nm in jit:
        if lo <= ip < hi:
            return nm
    if sym != '[unknown]':
        return sym
    return 'unresolved: 0x%x region' % (ip >> 24 << 24)

# ----------------------------------------------------------------------------------------
# clusters
# ----------------------------------------------------------------------------------------
WIZARD_ROWS = [
    ('wasm JIT code', 'SPC output, incl. the inline `resume` sequence'),
    ('pc/handler lookup', '`lookupPc`, `Vector<(int, List<FuncLoc>)>.[]`, `findHandler`, `lookupTopPc`, `findUserCode`, `computePcFromCode`, frame handles'),
    ('value marshalling', '`X86_64Stack.pop/push/popN/pushN/storeValue/popb32/peekTag` — tagged 32-byte slots ↔ `Value` objects'),
    ('suspend/resume driver', '`runtime_handle_suspend`, `tryHandleSuspension`, `redirectToHandlerStub`, `Runtime.TABLE_SET/GET`, `CONT_NEW/BIND`'),
    ('GC + allocator', '`.alloc`, `RiGc.memClear` = semispace zeroing, stack scanning'),
    ('kernel: memory mgmt', '`clear_page_erms`, fault handling, `_raw_spin_lock`, …'),
    ('pregen stubs', 'return-parent / enter-func'),
    ('decode/validate/compile', 'module load: `CodeValidator`, `BytecodeIterator`, SPC codegen'),
    ('other', 'kernel: other, misc Virgil, libc, unresolved'),
]
KMM = re.compile(r'clear_page|fault|page|pte|pmd|pud|vma|mas_|folio|lru|zone|rmqueue|memcg|cgroup|charge|zap_|unmap|mmap|brk|madvise|alloc|free|handle_mm|copy_|tlb|_raw_spin|rcu|mm_|swap|policy|nodemask|list_del|kmem|anon|rmap|mprotect')
DRIVER = re.compile(r'runtime_handle_|X86_64Runtime\.|tryHandleSuspension|redirectToHandlerStub|writeSpcState|Runtime\.(TABLE_|CONT_|unwindStackChain|SUSPEND|RESUME|SWITCH)|Continuations\.|X86_64Stack\.(bind|resume|suspend|switch|reset|clear|init|setup|pushRspPointer|unwind|new)|StackManager|getFreshStack|recycleStack|allocStackBatch|^Table\.\[\]')
MARSHAL = re.compile(r'^(X86_64Stack|ExecStack|WasmStack|VersionedStack)\.(pop|push|peek|store|checkTopTag|set_vsp)|^Values?\.|^Value\.|^Box')
LOOKUP = re.compile(r'lookupPc|lookupTopPc|List<FuncLoc>|findHandler|findSuspensionHandler|findUserCode|computePc|X86_64FrameHandle|fromCode|Sidetable\.|MemoryRange\.contains|FuncLoc|FrameLoc|SpcModuleCode')
GC = re.compile(r'^\.alloc$|\.alloc$|RiGc|Semispace|NativeStackScanner|scanStack|scanSlot|memClear|GcStats|X86_64Stack\.scan|RiRuntime\.(gc|scan)|Allocator')
COMPILE = re.compile(r'CodeValidator|BytecodeIterator|X86_64Masm|X86_64Assembler|X86_64Spc|SpcState|Ssa|BinParser|ModuleParser|Module\.|Instantiator|Engine\.|Strategy|Decoder|Validator|MachineCode|CodeGen|Codegen|DataWriter|DataReader|Vector<|HashMap|Strings\.|StringBuilder|TextReader|Parser')

def classify_wizard(sym):
    if sym.startswith('jit:'):
        return 'wasm JIT code'
    if sym.startswith('pregen:'):
        return 'pregen stubs'
    if sym.startswith('kernel:'):
        return 'kernel: memory mgmt' if KMM.search(sym) else 'other'
    if DRIVER.search(sym):
        return 'suspend/resume driver'
    if MARSHAL.search(sym):
        return 'value marshalling'
    if LOOKUP.search(sym):
        return 'pc/handler lookup'
    if GC.search(sym):
        return 'GC + allocator'
    if COMPILE.search(sym):
        return 'decode/validate/compile'
    return 'other'

WASMTIME_ROWS = [
    ('wasm JIT code', 'Cranelift output: everything a switch needs is inline here'),
    ('Wasmtime runtime (host)', 'libcalls (`cont_new`, traps), store, compilation'),
    ('kernel: memory mgmt', '`clear_page_erms`, fault handling, mmap/mprotect'),
    ('kernel: other', 'scheduling, I/O, …'),
    ('libc / other', 'libc, unresolved'),
]

def classify_wasmtime(sym, dso, ip):
    if dso.endswith('.map') or sym.startswith('wasm['):
        return 'wasm JIT code'
    if ip >= KERNEL_IP or 'kernel' in dso:
        return 'kernel: memory mgmt' if KMM.search(sym) else 'kernel: other'
    if dso.endswith('/wasmtime') or dso == 'wasmtime' or 'wasmtime' in sym or 'cranelift' in sym:
        return 'Wasmtime runtime (host)'
    return 'libc / other'

# ----------------------------------------------------------------------------------------
def pct(n, total):
    return '%.1f %%' % (100.0 * n / total) if total else '—'

def short(sym, names):
    """decorate JIT symbols with the wasm function name"""
    m = re.search(r'func(?:tion)?\[(\d+)\]', sym)
    if m and (sym.startswith('jit:') or sym.startswith('wasm[')):
        idx = int(m.group(1))
        nm = names.get(idx)
        return ('wasm: %s (func[%d])' % (nm, idx)) if nm else ('wasm: func[%d] (unnamed)' % idx)
    return sym

def main(outdir):
    runs = []
    with open(os.path.join(outdir, 'runs.tsv')) as f:
        for line in f:
            if not line.strip() or line.startswith('#'):
                continue
            engine, bench, wasm, args, rc, wall, samples, mapf, perf_rc = line.rstrip('\n').split('\t')
            runs.append(dict(engine=engine, bench=bench, wasm=wasm, args=args, rc=int(rc),
                             wall=float(wall), samples=samples, map=mapf, perf_rc=int(perf_rc)))
    benches = []
    for r in runs:
        if r['bench'] not in benches:
            benches.append(r['bench'])
    names = {b: wasm_func_names(next(r['wasm'] for r in runs if r['bench'] == b)) for b in benches}

    # per run: cluster counts, symbol counts, total
    res = {}
    for r in runs:
        samples = read_samples(r['samples']) if os.path.exists(r['samples']) else []
        clusters, syms = collections.Counter(), collections.Counter()
        if r['engine'] == 'wizard':
            jit, pregen, cs, ce = load_wizard_map(r['map'])
            r['map_ok'] = bool(jit) and cs is not None and ce is not None
            for ip, sym, dso in samples:
                s = wizard_symbol(ip, sym, dso, jit, pregen, cs, ce)
                syms[s] += 1; clusters[classify_wizard(s)] += 1
        else:
            r['map_ok'] = True
            for ip, sym, dso in samples:
                s = sym if sym != '[unknown]' else 'unresolved (%s)' % dso
                if ip >= KERNEL_IP or 'kernel' in dso:
                    s = 'kernel: ' + sym
                syms[s] += 1; clusters[classify_wasmtime(sym, dso, ip)] += 1
        r['total'] = len(samples); r['clusters'] = clusters; r['syms'] = syms
        res[(r['engine'], r['bench'])] = r

    meta = {}
    mp = os.path.join(outdir, 'meta.txt')
    if os.path.exists(mp):
        for line in open(mp):
            if '=' in line:
                k, v = line.rstrip('\n').split('=', 1); meta[k] = v

    L = []
    L.append('# runtime-compare: where the time goes — Wizard (SPC) vs Wasmtime (Cranelift)')
    L.append('')
    L.append('Whole-process `perf record -e %s -F %s` per engine and benchmark (startup and compilation '
             'included). Percentages are shares of all samples of that run. Method: '
             '`research/FIBER_C_COMPARE.md` section 2; generated by `runtime-compare.sh`.'
             % (meta.get('event', 'cpu-clock'), meta.get('freq', '?')))
    L.append('')
    for k in ('date', 'host', 'perf', 'wizard', 'wasmtime', 'note'):
        if meta.get(k):
            L.append('- %s: %s' % (k, meta[k]))
    L.append('')
    L.append('## Runs')
    L.append('')
    L.append('| Benchmark | args | Wizard wall (s) | rc | samples | Wasmtime wall (s) | rc | samples |')
    L.append('|---|---|---|---|---|---|---|---|')
    for b in benches:
        wz, wt = res.get(('wizard', b)), res.get(('wasmtime', b))
        args = (wz or wt)['args']
        def cell(r):
            if not r:
                return '— | — | —'
            return '%.2f | %s | %d' % (r['wall'], ('0' if r['rc'] == 0 else '**%d**' % r['rc']), r['total'])
        L.append('| `%s` | %s | %s | %s |' % (b, args or '—', cell(wz), cell(wt)))
    L.append('')
    L.append('Wall time and rc are from a plain run (no perf); the profiled run follows it. '
             'rc ≠ 0 means the engine failed (the profile then covers the run up to the failure).')
    mism = [r for r in runs if r['perf_rc'] != r['rc']]
    if mism:
        L.append('')
        L.append('**Warning:** exit status differed between the plain and the profiled run for %s.'
                 % ', '.join('%s/`%s` (%d vs %d)' % (r['engine'], r['bench'], r['rc'], r['perf_rc']) for r in mism))
    L.append('')

    def matrix(engine, rows, title):
        L.append('## %s' % title)
        L.append('')
        cols = [b for b in benches if (engine, b) in res]
        L.append('| Cluster (what it is) | ' + ' | '.join('`%s`' % c for c in cols) + ' |')
        L.append('|---|' + '---|' * len(cols))
        for row, desc in rows:
            cells = []
            for b in cols:
                r = res[(engine, b)]
                cells.append(pct(r['clusters'].get(row, 0), r['total']))
            L.append('| **%s** (%s) | %s |' % (row, desc, ' | '.join(cells)))
        L.append('')

    matrix('wizard', WIZARD_ROWS, "Where Wizard's time goes")
    bad = [b for b in benches if ('wizard', b) in res and not res[('wizard', b)]['map_ok']]
    if bad:
        L.append('**Warning:** no SPC code map for %s — JIT samples of those runs are counted as '
                 '"other".' % ', '.join('`%s`' % b for b in bad))
        L.append('')
    unres = [(b, res[('wizard', b)]) for b in benches if ('wizard', b) in res]
    unres = [(b, sum(n for s, n in r['syms'].items() if s.startswith('unresolved')), r['total']) for b, r in unres]
    unres = [(b, n, t) for b, n, t in unres if t and 100.0 * n / t > 2]
    if unres:
        L.append('**Warning:** unresolved addresses above 2 %% in %s — the code map may not match '
                 'the profiled run (ASLR must be disabled for both: `setarch -R`).'
                 % ', '.join('`%s` (%s)' % (b, pct(n, t)) for b, n, t in unres))
        L.append('')

    matrix('wasmtime', WASMTIME_ROWS, "Where Wasmtime's time goes")
    L.append('| Benchmark | JIT share | Top functions |')
    L.append('|---|---|---|')
    for b in benches:
        r = res.get(('wasmtime', b))
        if not r or not r['total']:
            continue
        jit = [(s, n) for s, n in r['syms'].most_common() if s.startswith('wasm[')][:4]
        tops = ', '.join('`%s` %s' % (short(s, names[b]), pct(n, r['total'])) for s, n in jit)
        L.append('| `%s` | %s | %s |' % (b, pct(r['clusters'].get('wasm JIT code', 0), r['total']), tops))
    L.append('')

    L.append('## JIT-only time (wall × JIT share)')
    L.append('')
    L.append('Time spent executing compiled wasm code on each engine — what remains of the gap if '
             "Wizard's runtime cost vanished entirely.")
    L.append('')
    L.append('| Benchmark | Wizard wall (s) | Wasmtime wall (s) | wall ratio | Wizard JIT (ms) | Wasmtime JIT (ms) | JIT ratio |')
    L.append('|---|---|---|---|---|---|---|')
    for b in benches:
        wz, wt = res.get(('wizard', b)), res.get(('wasmtime', b))
        if not wz or not wt or wz['rc'] != 0 or wt['rc'] != 0 or not wz['total'] or not wt['total']:
            continue
        a = 1000 * wz['wall'] * wz['clusters'].get('wasm JIT code', 0) / wz['total']
        c = 1000 * wt['wall'] * wt['clusters'].get('wasm JIT code', 0) / wt['total']
        L.append('| `%s` | %.2f | %.2f | %s | %.0f | %.0f | %s |' % (
            b, wz['wall'], wt['wall'], ('%.1f×' % (wz['wall'] / wt['wall'])) if wt['wall'] else '—',
            a, c, ('%.1f×' % (a / c)) if c else '—'))
    L.append('')

    L.append('## Top symbols per run')
    L.append('')
    for b in benches:
        for engine in ('wizard', 'wasmtime'):
            r = res.get((engine, b))
            if not r or not r['total']:
                continue
            L.append('- **%s / `%s`** (%d samples): ' % (engine, b, r['total']) +
                     ', '.join('`%s` %s' % (short(s, names[b]), pct(n, r['total']))
                               for s, n in r['syms'].most_common(8)))
    L.append('')
    text = '\n'.join(L)
    with open(os.path.join(outdir, 'REPORT.md'), 'w') as f:
        f.write(text + '\n')
    # full per-run symbol tables, for digging
    for r in runs:
        with open(os.path.join(outdir, '%s-%s.symbols.txt' % (r['engine'], r['bench'])), 'w') as f:
            f.write('total samples: %d\n' % r['total'])
            for s, n in r['syms'].most_common():
                f.write('%6.2f%%  %6d  %s\n' % (100.0 * n / r['total'], n, s))
    print(text)

if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
