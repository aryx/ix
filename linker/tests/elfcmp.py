#!/usr/bin/env python3
# elfcmp.py goken.exe ix.exe: SAME when the two ELF files are equal, or
# equal but for goken's section table where 5l writes it over the end of
# the data (at HEADR+text+data, inside the data's page: a goken bug that
# mini-ld doesn't reproduce: it puts the table after the data). Else DIFF
# and the first offset that differs.
import struct, sys
g, t = open(sys.argv[1], 'rb').read(), open(sys.argv[2], 'rb').read()
if g == t:
    print('SAME'); sys.exit(0)
is64 = g[4] == 2
shoff_at, shsize = (40, 3 * 64 + 22) if is64 else (32, 3 * 40 + 22)
fmt = '<Q' if is64 else '<I'
w = 8 if is64 else 4
gsh = struct.unpack(fmt, g[shoff_at:shoff_at + w])[0]
tsh = struct.unpack(fmt, t[shoff_at:shoff_at + w])[0]
# the table's bytes, and e_shoff, aside
skip = set(range(shoff_at, shoff_at + w)) | set(range(gsh, gsh + shsize)) | set(range(tsh, tsh + shsize))
n = max(len(g), len(t))
for i in range(n):
    if i in skip: continue
    a = g[i] if i < len(g) else 0
    b = t[i] if i < len(t) else 0
    if a != b:
        print('DIFF at %d (0x%x): %02x %02x' % (i, i, a, b)); sys.exit(1)
if g[gsh + shsize - 22:gsh + shsize] != t[tsh + shsize - 22:tsh + shsize]:
    print('DIFF in the section names'); sys.exit(1)
print('SAME but the section table (goken: 0x%x, inside the data; ix: 0x%x)' % (gsh, tsh) if gsh != tsh else 'SAME')
