import sys, re
# address-first classification: pregen region (labeled sub-ranges), JIT func ranges, ELF syms, kernel
ranges=[]; pregen=[]; code_start=code_end=None
for line in open(sys.argv[1]):
    line=line.strip()
    m=re.match(r'func\[(\d+)\]\.target_code: break \*0x([0-9A-Fa-f]+) disass 0x[0-9A-Fa-f]+, 0x([0-9A-Fa-f]+)',line)
    if m:
        lo,hi=int(m.group(2),16),int(m.group(3),16)
        if hi>lo: ranges.append((lo,hi,'jit: wasm func[%s]'%m.group(1)))
        continue
    m=re.match(r'([a-z0-9 ->]+):\s+(?:break \*)?0x([0-9A-Fa-f]+)\s*-\s*0x([0-9A-Fa-f]+)',line)
    if m: pregen.append((int(m.group(2),16),int(m.group(3),16),'pregen: '+m.group(1).strip())); continue
    m=re.match(r'([a-z0-9 ->]+):\s+(?:break \*)?0x([0-9A-Fa-f]+)$',line)
    if m:
        name,addr=m.group(1).strip(),int(m.group(2),16)
        if name=='code start': code_start=addr
        elif name=='code end': code_end=addr
        else: pregen.append((addr,None,'pregen: '+name))
pregen.sort(); fixed=[]
for i,(lo,hi,nm) in enumerate(pregen):
    if hi is None: hi=pregen[i+1][0] if i+1<len(pregen) else code_end
    fixed.append((lo,hi,nm))
pregen=fixed; ranges.sort()
from collections import Counter
c=Counter(); total=0
for line in sys.stdin:
    parts=line.split()
    if not parts: continue
    try: ip=int(parts[0],16)
    except ValueError: continue
    total+=1
    sym=' '.join(parts[1:-1]) if len(parts)>2 else '?'
    dso=parts[-1] if parts else ''
    if ip>=0xffff000000000000 or 'kernel' in line: c['kernel: '+sym]+=1; continue
    if code_start and code_start<=ip<(code_end or 0):
        name=None
        for lo,hi,nm in pregen:
            if lo<=ip<hi: name=nm; break
        c[name or 'pregen: other']+=1; continue
    hit=None
    for lo,hi,nm in ranges:
        if lo<=ip<hi: hit=nm; break
    if hit: c[hit]+=1; continue
    if sym!='[unknown]': c[sym]+=1
    else: c['unknown: 0x%x range'%(ip>>24<<24)]+=1
print("total samples:",total)
for name,n in c.most_common(20): print("%6.2f%%  %6d  %s"%(100*n/total,n,name))
