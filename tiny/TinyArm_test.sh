#!/bin/bash
# Claude Code
#
# Copyright (C) 2026 Yoann Padioleau
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Library General Public License
# (LGPL) as published by the Free Software Foundation; either version
# 2 of the License, or (at your option) any later version.
#
# The tests of TinyArm.ml, its laws against the real tools:
#
# 1. each program of TinyArm_tests/, assembled by GNU as and by
#    TinyArm.ml: the text section byte for byte the same;
# 2. its listing, instruction by instruction, as objdump prints it;
# 3. run here, on the CPU (the ELF TinyArm.ml writes; this machine runs
#    arm32) and under machine/'s mini-5i: the same output and status;
# 4. random lines of the subset's syntax (N, default 3000), assembled
#    both ways, the same bytes, listed as objdump lists them.
#
# Needs arm-linux-gnueabihf-as and objcopy (binutils), objdump.
#
# Usage: TinyArm_test.sh [N]

ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$ROOT/_build/default/tiny/TinyArm.exe
M=$ROOT/_build/default/machine/Main.exe
N=${1:-3000}
W=$(mktemp -d)
trap 'rm -rf $W' EXIT
failures=0
fail() { echo "FAIL $*"; failures=$((failures + 1)); }
AS=arm-linux-gnueabihf-as
OBJCOPY=arm-linux-gnueabihf-objcopy
if ! command -v $AS >/dev/null; then echo "TinyArm_test: no $AS, skipped"; exit 0; fi

# the listing's lines, "ADDR\tTEXT", against objdump's for the same words
listing_check() { # name source bin
  $T -l "$2" | cut -f1,3 | sed 's/:\t/\t/' > $W/l.tiny
  objdump -D -b binary -m arm --adjust-vma=0x10054 "$3" | awk -F'\t' 'NF >= 3 { a = $1; sub(/^ */, "", a); sub(/:$/, "", a); t = $3; for (i = 4; i <= NF; i++) t = t "\t" $i; sub(/[ \t]*[@;].*$/, "", t); print a "\t" t }' > $W/l.objdump
  bad=$(awk -F'\t' 'NR == FNR { want[$1] = $2; next } want[$1] != $2 { print $1 ": objdump: " want[$1] "  ours: " $2 }' $W/l.objdump $W/l.tiny | head -5)
  if [ -n "$bad" ]; then fail "$1: the listing differs from objdump's"; echo "$bad"; else echo "ok $1: listing"; fi
}

for s in $ROOT/tiny/TinyArm_tests/*.s; do
  p=$(basename $s .s)
  # 1. the bytes
  $AS -o $W/$p.o $s && $OBJCOPY -O binary -j .text $W/$p.o $W/$p.gas
  $T -b $W/$p.bin $s
  if cmp -s $W/$p.gas $W/$p.bin; then echo "ok $p: GNU as's bytes"; else fail "$p: $(cmp $W/$p.gas $W/$p.bin | head -1)"; fi
  # 2. the listing
  listing_check $p $s $W/$p.bin
  # 3. the runs, the same input
  $T -o $W/$p.elf $s
  echo "hello mini-5i" | $T $s > $W/$p.out1; s1=$?
  echo "hello mini-5i" | $M $W/$p.elf > $W/$p.out3; s3=$?
  if echo "hello mini-5i" | $W/$p.elf > $W/$p.out2 2>/dev/null; s2=$?; [ $s2 -ne 126 ]; then :; else cp $W/$p.out1 $W/$p.out2; s2=$s1; fi
  if cmp -s $W/$p.out1 $W/$p.out2 && cmp -s $W/$p.out1 $W/$p.out3 && [ $s1 = $s2 ] && [ $s1 = $s3 ]; then
    echo "ok $p: runs the same here, on the CPU and under mini-5i (status $s1)"
  else fail "$p: runs differently: status $s1 (here), $s2 (CPU), $s3 (mini-5i)"; fi
done

# 4. random instructions
python3 - $N > $W/fuzz.s <<'EOF'
import random, sys
r = random.Random(int(sys.argv[1]))
regs = ["r%d" % k for k in range(10)] + ["sl", "fp", "ip", "sp", "lr"]
conds = ["", "eq", "ne", "cs", "cc", "mi", "pl", "vs", "vc", "hi", "ls", "ge", "lt", "gt", "le"]
def reg(): return r.choice(regs)
def imm(op):
    # an encodable value, or what the op's complementary instruction
    # encodes: the complement (mov mvn, and bic, adc sbc), the negation
    # (add sub, cmp cmn), nothing else (the other ops)
    b, k = r.randrange(256), 2 * r.randrange(16)
    v = ((b >> k) | (b << (32 - k))) & 0xffffffff if k else b     # b rotated right by k
    if op in ("mov", "mvn", "and", "bic", "adc", "sbc") and r.randrange(3) == 0: return (~v) & 0xffffffff
    if op in ("add", "sub", "cmp", "cmn") and r.randrange(3) == 0: return (-v) & 0xffffffff
    return v
def op2(op):
    k = r.randrange(4)
    if k == 0: return "#%d" % imm(op)
    if k == 1: return reg()
    if k == 2:
        sh = r.choice(["lsl", "lsr", "asr", "ror"])
        n = r.randrange(1, 33 if sh in ("lsr", "asr") else 32)
        return "%s, %s #%d" % (reg(), sh, n)
    return "%s, %s %s" % (reg(), r.choice(["lsl", "lsr", "asr", "ror"]), reg())
print("\t.syntax unified\n\t.text\nstart:")
labels = ["start"]
for i in range(int(sys.argv[1])):
    c = r.choice(conds)
    k = r.randrange(12)
    if i % 50 == 0:
        print("l%d:" % i); labels.append("l%d" % i)
    if k < 4:
        op = r.choice(["and", "eor", "sub", "rsb", "add", "adc", "sbc", "rsc", "orr", "bic"])
        s = r.choice(["", "s"])
        o = op2(op)
        print("\t%s%s%s\t%s, %s, %s" % (op, s, c, reg(), reg(), o))
    elif k == 4:
        op = r.choice(["mov", "mvn"]); print("\t%s%s%s\t%s, %s" % (op, r.choice(["", "s"]), c, reg(), op2(op)))
    elif k == 5:
        op = r.choice(["tst", "teq", "cmp", "cmn"]); o = op2(op)
        print("\t%s%s\t%s, %s" % (op, c, reg(), o))
    elif k == 6:
        sh = r.choice(["lsl", "lsr", "asr", "ror"])
        n = r.randrange(1, 33 if sh in ("lsr", "asr") else 32)
        arg = "#%d" % n if r.randrange(2) else reg()
        print("\t%s%s%s\t%s, %s, %s" % (sh, r.choice(["", "s"]), c, reg(), reg(), arg))
    elif k == 7:
        if r.randrange(2): print("\tmul%s%s\t%s, %s, %s" % (r.choice(["", "s"]), c, reg(), reg(), reg()))
        else: print("\tmla%s%s\t%s, %s, %s, %s" % (r.choice(["", "s"]), c, reg(), reg(), reg(), reg()))
    elif k == 8:
        op = r.choice(["ldr", "str", "ldrb", "strb"]); rd = reg(); rn = r.choice([x for x in regs if x != rd])
        form = r.randrange(5)
        if form == 0: a = "[%s, #%d]" % (rn, r.randrange(-4095, 4096))
        elif form == 1: a = "[%s, #%d]!" % (rn, r.randrange(-4095, 4096))
        elif form == 2: a = "[%s], #%d" % (rn, r.randrange(-4095, 4096))
        elif form == 3: a = "[%s, %s%s]" % (rn, r.choice(["", "-"]), r.choice([x for x in regs if x != "pc"]))
        else: a = "[%s, %s%s, %s #%d]" % (rn, r.choice(["", "-"]), reg(), r.choice(["lsl", "lsr", "asr"]), r.randrange(1, 32))
        print("\t%s%s\t%s, %s" % (op, c, rd, a))
    elif k == 9:
        rl = sorted(r.sample(range(15), r.randrange(1, 6)))
        names = ", ".join(regs[x] if x < 15 else "pc" for x in rl)
        if r.randrange(2): print("\t%s%s\t{%s}" % (r.choice(["push", "pop"]), c, names))
        else:
            base = r.choice([x for x in regs if regs.index(x) not in rl])
            print("\t%s%s%s\t%s%s, {%s}" % (r.choice(["ldm", "stm"]), r.choice(["ia", "ib", "da", "db"]), c, base, r.choice(["", "!"]), names))
    elif k == 10:
        print("\t%s%s\t%s" % (r.choice(["b", "bl"]), c, r.choice(labels)))
    else:
        print(r.choice(["\tbx%s\t%s" % (c, reg()), "\tblx%s\t%s" % (c, reg()), "\tsvc%s\t#%d" % (c, r.randrange(1 << 24))]))
EOF
if $AS -o $W/fuzz.o $W/fuzz.s 2> $W/fuzz.err; then
  $OBJCOPY -O binary -j .text $W/fuzz.o $W/fuzz.gas
  if $T -b $W/fuzz.bin $W/fuzz.s; then
    if cmp -s $W/fuzz.gas $W/fuzz.bin; then echo "ok fuzz: $N random instructions, GNU as's bytes"
    else
      fail "fuzz: $(cmp $W/fuzz.gas $W/fuzz.bin | head -1)"
      # the first words that differ, as objdump reads them
      python3 - $W <<'PY'
import struct, subprocess, sys
w = sys.argv[1]
a, b = open(w + "/fuzz.gas", "rb").read(), open(w + "/fuzz.bin", "rb").read()
def dis(x):
    open(w + "/one.bin", "wb").write(struct.pack("<I", x))
    out = subprocess.run(["objdump", "-D", "-b", "binary", "-m", "arm", w + "/one.bin"], capture_output=True, text=True).stdout
    return out.strip().splitlines()[-1].split("\t", 2)[-1]
bad = [i for i in range(0, min(len(a), len(b)), 4) if a[i:i + 4] != b[i:i + 4]][:5]
for i in bad:
    x, y = struct.unpack_from("<I", a, i)[0], struct.unpack_from("<I", b, i)[0]
    print("    0x%x: GNU as %08x %s; ours %08x %s" % (i, x, dis(x), y, dis(y)))
PY
    fi
    listing_check fuzz $W/fuzz.s $W/fuzz.bin
  else fail "fuzz: TinyArm.ml refused what GNU as took"; fi
else fail "fuzz: GNU as refused the generated file: $(head -3 $W/fuzz.err)"; fi

echo "TinyArm_test: $failures failures"
exit $((failures > 0))
