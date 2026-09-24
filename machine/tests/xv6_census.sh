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
# The census behind plan_pi.md for xv6-multiarch's Raspberry Pi ports
# (~/xv6/forks/): each port booted by its own quick test (a shell
# prompt, ls) under a wrapper that adds qemu's -d in_asm (the dynamic
# census, census.py --logs), and its kernel and user ELFs
# disassembled by objdump, whose mapping symbols tell ARM from Thumb
# (the static census: qemu's log cannot tell them apart).
#
# Usage: xv6_census.sh OUTDIR   (QEMU11: a qemu with -M raspi4b)

set -u
OUT=$1; mkdir -p $OUT
XV6=${XV6:-$HOME/xv6}
QEMU11=${QEMU11:-/home/pad/work/TOOLCHAINS/qemu/build/qemu-system-aarch64}
HERE=$(cd $(dirname $0) && pwd)
for q in qemu-system-arm qemu-system-aarch64; do
  printf '#!/bin/sh\nexec /usr/bin/%s -d in_asm -D %s/$PORT.$$.log "$@"\n' $q $OUT > $OUT/w-$q
done
printf '#!/bin/sh\nexec %s -d in_asm -D %s/$PORT.$$.log "$@"\n' $QEMU11 $OUT > $OUT/w-pi4
chmod +x $OUT/w-*
cd $XV6
for p in arm-pi1 arm-pi1-bis arm arm-pi2; do PORT=$p make quick-test-$p QEMU_ARM=$OUT/w-qemu-system-arm > $OUT/$p.out 2>&1; done
PORT=arm-pi3 make quick-test-arm-pi3 QEMU_ARM_PI3=$OUT/w-qemu-system-aarch64 > $OUT/arm-pi3.out 2>&1
PORT=arm64-pi4 make quick-test-arm64-pi4 QEMU_ARM64_PI4=$OUT/w-pi4 > $OUT/arm64-pi4.out 2>&1
for p in arm-pi1 arm-pi1-bis arm arm-pi2 arm-pi3; do python3 $HERE/census.py --logs 5 $OUT/$p.*.log | head -2; done
python3 $HERE/census.py --logs 7 $OUT/arm64-pi4.*.log | head -2
# static: ARM against Thumb, and VFP/NEON, per port
cd $XV6/forks
for p in arm-pi1:build/output-qemu.elf arm-pi1-bis:kernel.elf arm:kernel.elf arm-pi2:build/kernel-qemu.elf arm-pi3:build-qemu/kernel-qemu.elf; do
  n=${p%%:*}; f=$n/${p#*:}
  users=$(ls $n/user/_* $n/build/user/_* $n/user/build/_* $n/build-qemu/user/_* 2>/dev/null)
  arm-linux-gnueabihf-objdump -d $f $users 2>/dev/null | awk -v port=$n '
    /^[0-9a-f]+ <.*>:/ {fn = $2}
    /^ +[0-9a-f]+:\t/ { split($0, a, "\t"); split(a[3], b, " "); op = b[1]
      t = (a[2] ~ /^[0-9a-f]{4} ?([0-9a-f]{4})? *$/) ? "T" : "A"
      ops[t " " op]++; if (t == "T") tf[fn] = 1; if (op ~ /^v/) v[op]++ }
    END { na = 0; nt = 0; for (k in ops) { if (k ~ /^A/) na++; else nt++ }
      printf "%s: static, ARM mnemonics %d, Thumb %d, in:", port, na, nt; for (f in tf) printf " %s", f
      printf "; VFP/NEON:"; for (k in v) printf " %s(%d)", k, v[k]; print "" }'
done
