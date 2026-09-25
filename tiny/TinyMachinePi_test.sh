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
# The tests of TinyMachinePi.ml, its laws:
#
# 1. each program of TinyMachinePi_tests/ assembled by GNU as (linked at
#    0x8000, made a raw image as the Pi1's kernel.img) and by TinyMachinePi:
#    the same bytes;
# 2. run here, its console is its .expected;
# 3. run under mini-qemu and under QEMU (raspi1ap, the image loaded
#    at 0x8000 as the firmware loads it), the console the same;
# 4. the time is the machine's, not the host's: tick.s takes its five
#    interrupts and halts at 50ms of simulated time whatever the
#    instructions per microsecond (10, 30, 100).
#
# Needs arm-linux-gnueabihf-as, -ld and -objcopy (binutils); QEMU's
# qemu-system-arm for 3 (skipped without it).
#
# Usage: TinyMachinePi_test.sh

ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$ROOT/_build/default/tiny/TinyMachinePi.exe
M=$ROOT/_build/default/raspberry/Main.exe
W=$(mktemp -d)
trap 'rm -rf $W' EXIT
failures=0
fail() { echo "FAIL $*"; failures=$((failures + 1)); }
loader() { echo "loader,file=$1,addr=0x8000,cpu-num=0,force-raw=on"; }

for s in $ROOT/tiny/TinyMachinePi_tests/*.s; do
  p=$(basename $s .s)
  # 1. the bytes
  $T -o $W/$p.img $s || { fail "$p: not assembled"; continue; }
  arm-linux-gnueabihf-as -march=armv6kz $s -o $W/$p.o && arm-linux-gnueabihf-ld -Ttext=0x8000 $W/$p.o -o $W/$p.elf &&
    arm-linux-gnueabihf-objcopy -O binary $W/$p.elf $W/$p.gnu
  if cmp -s $W/$p.img $W/$p.gnu; then echo "ok $p: GNU as's bytes"; else fail "$p: the bytes differ from GNU as's"; fi
  # 2. its console
  $T $s > $W/$p.out
  if cmp -s $W/$p.out ${s%.s}.expected; then echo "ok $p: its expected output"; else fail "$p: $(diff $W/$p.out ${s%.s}.expected | head -3)"; fi
  # 3. the other Pis: they never exit, a halted kernel waits forever
  timeout 5 $M -M raspi1ap -device $(loader $W/$p.img) -nographic < /dev/null > $W/$p.mini 2>&1
  if cmp -s $W/$p.out $W/$p.mini; then echo "ok $p: under mini-qemu, the same"; else fail "$p: mini-qemu's output differs"; fi
  if command -v qemu-system-arm > /dev/null; then
    timeout 5 qemu-system-arm -M raspi1ap -device $(loader $W/$p.img) -display none -serial file:$W/$p.qemu < /dev/null > /dev/null 2>&1
    if cmp -s $W/$p.out $W/$p.qemu; then echo "ok $p: under QEMU, the same"; else fail "$p: QEMU's output differs"; fi
  fi
done

# 4. the machine's time
for ips in 10 30 100; do
  r=$($T -ips $ips -s $ROOT/tiny/TinyMachinePi_tests/tick.s 2>&1 >/dev/null)
  n=$(echo "$r" | sed -n 's/.*, \([0-9]*\) interrupts, at \([0-9]*\) us/\1 \2/p')
  set -- $n
  if [ "$1" = 5 ] && [ "$2" -ge 50000 ] && [ "$2" -lt 50200 ]; then echo "ok tick at $ips instructions a microsecond: 5 interrupts, halted at $2 us"
  else fail "tick at $ips: $r"; fi
done

echo "TinyMachinePi_test: $failures failures"
exit $((failures > 0))
