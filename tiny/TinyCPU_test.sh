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
# The tests of TinyCPU.ml, its laws:
#
# 1. each program of TinyCPU_tests/, interpreted, prints its
#    .expected (computed otherwise: Python's factorials, primes, sort);
# 2. random programs (N, default 200), each a straight line of every
#    kind of instruction with branches and jal over one: the listing,
#    reassembled, lists the same words.
#
# Usage: TinyCPU_test.sh [N]

ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$ROOT/_build/default/tiny/TinyCPU.exe
N=${1:-200}
W=$(mktemp -d)
trap 'rm -rf $W' EXIT
failures=0
fail() { echo "FAIL $*"; failures=$((failures + 1)); }
INPUT="hello tiny machine"

# a program's listing, reassembled and listed again: "same" or the diff
relist() { # source
  $T -l "$1" > $W/l1 || { echo "not assembled"; return; }
  cut -f3- $W/l1 | sed 's/^/\t/' > $W/r.tm
  $T -l $W/r.tm > $W/l2 2>&1
  if cmp -s $W/l1 $W/l2; then echo same; else diff $W/l1 $W/l2 | head -3; fi
}

for s in $ROOT/tiny/TinyCPU_tests/*.tm; do
  p=$(basename $s .tm)
  echo "$INPUT" | $T $s > $W/$p.out 2>&1
  if cmp -s $W/$p.out ${s%.tm}.expected; then echo "ok $p: its expected output"; else fail "$p: $(diff $W/$p.out ${s%.tm}.expected | head -3)"; fi
done

# random programs
python3 - $N $W <<'EOF'
import random, sys
n, w = int(sys.argv[1]), sys.argv[2]
alu = ["add", "sub", "mul", "div", "rem", "and", "or", "xor", "shl", "shr", "sar", "slt", "sltu"]
alui = ["addi", "andi", "ori", "xori", "shli", "shri", "sari", "slti", "sltiu"]
special = [0, 1, -1, 2**31 - 1, -2**31, 31, 32, 10, -10, 0xffff, 0x10000]
for k in range(n):
    r = random.Random(k)
    reg = lambda: "r%d" % r.randrange(16)
    lines = []
    for i in range(1, 16):
        v = r.choice(special) if r.random() < 0.3 else r.getrandbits(32) - 2**31
        lines.append("\tli\tr%d, %d" % (i, v))
    label = 0
    for i in range(40):
        c = r.randrange(10)
        if c < 4: lines.append("\t%s\t%s, %s, %s" % (r.choice(alu), reg(), reg(), reg()))
        elif c < 6:
            op = r.choice(alui)
            v = r.randrange(0x10000) if op in ("andi", "ori", "xori") else r.randrange(-0x8000, 0x8000)
            lines.append("\t%s\t%s, %s, %d" % (op, reg(), reg(), v))
        elif c == 6: lines.append("\tlui\t%s, %d" % (reg(), r.randrange(0x10000)))
        elif c == 7:
            if r.randrange(2): lines.append("\t%s\t%s, %d(%s)" % (r.choice(["ldw", "ldb"]), reg(), r.randrange(-0x8000, 0x8000), reg()))
            else: lines.append("\t%s\t%s, %d(r0)" % (r.choice(["stw", "stb"]), reg(), r.randrange(0x4000, 0x7ff0)))
        else:
            label += 1
            if c == 8: lines.append("\t%s\t%s, %s, l%d" % (r.choice(["beq", "bne", "blt", "bge", "bltu", "bgeu"]), reg(), reg(), label))
            else: lines.append("\tjal\t%s, l%d" % (reg(), label))
            lines.append("\t%s\t%s, %s, %s" % (r.choice(alu), reg(), reg(), reg()))
            lines.append("l%d:" % label)
    lines += ["\tli\tr1, 0", "\tsys\t0"]
    open("%s/f%d.tm" % (w, k), "w").write("\n".join(lines) + "\n")
EOF
bad=0
for k in $(seq 0 $((N - 1))); do
  r=$(relist $W/f$k.tm)
  if [ "$r" != same ]; then bad=$((bad + 1)); [ $bad -le 3 ] && echo "  random program $k: $r"; cp $W/f$k.tm /tmp/tiny-cpu_fail_$k.tm 2>/dev/null; fi
done
if [ $bad = 0 ]; then echo "ok random: $N programs, their listings reassembled to the same words"; else fail "random: $bad of $N differ (kept as /tmp/tiny-cpu_fail_*.tm)"; fi

echo "TinyCPU_test: $failures failures"
exit $((failures > 0))
