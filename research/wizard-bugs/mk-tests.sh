#!/usr/bin/env bash
# Regenerate the .bin.wast spectests from their .wast sources.
#
# Two toolchain facts make this more than a one-liner:
#   * this repo's reference interpreter (dependencies/specfx, pinned 15ec7d15)
#     predates the opcode renumbering that inserted `resume_throw_ref`, so it
#     emits `switch` as 0xE5 while Wizard's decoder expects 0xE6. Every `switch`
#     site is byte-patched here, exactly as research/compiler-diff does.
#   * specfx cannot *execute* the payload-less `switch` in switch_gc0.wast (it
#     reports a spurious "stack underflow"); it can still translate it. It also
#     rejects Wizard's own switch0-14.wast on typing grounds, so it is not a
#     usable oracle for `switch` at this pin. Upstream's newer spec checkout
#     (test/regress/build.sh) produces 0xE6 directly and needs no patching.
set -e
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../../env.sh" >/dev/null 2>&1
cd "$HERE/tests"
for t in *.wast; do
  case "$t" in *.bin.wast) continue;; esac
  out="${t%.wast}.bin.wast"; tmp="_tmp_${t%.wast}.bin.wast"
  "$WASM_INTERP" -d "$t" -o "$tmp"
  python3 - "$tmp" "$out" "$t" <<'PY'
import re, sys
src, dst, wast = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src).read()
def patch(m):
    body = m.group(0)
    b = bytearray(int(x, 16) for x in re.findall(r'\\([0-9a-f]{2})', body))
    n = 0
    for k in range(len(b) - 2):
        if b[k] == 0xE5 and b[k+1] < 0x80 and b[k+2] < 0x80:   # switch <ct> <tag>
            b[k] = 0xE6; n += 1
    nsrc = len(re.findall(r'\(switch ', open(wast).read()))
    assert n == nsrc, f"{wast}: patched {n} switch sites, source has {nsrc}"
    lines = ['(module definition binary']
    for i in range(0, len(b), 16):
        lines.append('  "' + ''.join('\\%02x' % c for c in b[i:i+16]) + '"')
    lines.append(')')
    return '\n'.join(lines)
text = re.sub(r'\(module definition binary.*?\n\)', patch, text, flags=re.S)
open(dst, 'w').write(text)
print(f"  wrote {dst}")
PY
  rm -f "$tmp"
done
