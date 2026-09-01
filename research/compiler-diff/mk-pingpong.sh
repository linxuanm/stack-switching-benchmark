#!/usr/bin/env bash
# mk.sh <N>: bake N into pingpong.wat, assemble with the reference interpreter, patch switch opcodes 0xE5->0xE6
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/../../env.sh"  # WASM_INTERP -> dependencies/specfx (overridable)
N=$1; OUT=pingpong_$N
sed -e 's/(func \$main (export "main") (param \$n i32) (result i32)/(func $run (param $n i32) (result i32)/' \
    -e "s/(elem declare func \$producer \$consumer)/(elem declare func \$producer \$consumer)\n  (func (export \"main\") (result i32) (call \$run (i32.const $N)))/" pingpong.wat > $OUT.wat
"$WASM_INTERP" -d -i $OUT.wat -o $OUT.old.wasm
python3 - "$OUT" <<'PY'
import sys
name=sys.argv[1]
data=bytearray(open(name+'.old.wasm','rb').read())
def leb(b,i):
    r=0;s=0
    while True:
        x=b[i];i+=1;r|=(x&0x7f)<<s;s+=7
        if not x&0x80: return r,i
i=8;code=None
while i<len(data):
    sid=data[i]; size,j=leb(data,i+1)
    if sid==10: code=(j,j+size)
    i=j+size
pat=bytes([0xE5,0x01,0x00]); hits=[k for k in range(code[0],code[1]) if data[k:k+3]==pat]
assert len(hits)==3, hits
for h in hits: data[h]=0xE6
open(name+'.wasm','wb').write(data)
print(name+'.wasm: patched switch sites at', [hex(h) for h in hits])
PY
