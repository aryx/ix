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
# The tests of TinyMachine.ml, its laws, on TinyKernel_v0.tm
# (a page of kernel, four user programs: a and b print 20 letters
# each, c executes csrw, d stores into the kernel):
#
# 1. with a period longer than any program, no interrupt: the programs
#    one after the other, exactly;
# 2. with periods from 30 to 400 (every 13th) (below 30 the next interrupt
#    comes before the kernel's eret: no user instruction ever runs),
#    every letter printed, c's and d's faults caught, the machine
#    halted with status 0; and a and b interleaved, a b before a's
#    last a;
# 3. the same period, the same output: the time is the program's;
# 4. the kernel assembled to an image (-o), the image run: the same
#    output as the source run, and its listing the same.
#
# Usage: TinyMachine_test.sh

ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$ROOT/_build/default/tiny/TinyMachine.exe
K=$ROOT/tiny/TinyKernel_v0.tm
W=$(mktemp -d)
trap 'rm -rf $W' EXIT
failures=0
fail() { echo "FAIL $*"; failures=$((failures + 1)); }

with_period() { # period -> the output, then the status on its own line
  sed "s/^period:\t.word\t[0-9]*/period:\t.word\t$1/" $K > $W/k.tm
  timeout 10 $T $W/k.tm; echo; echo $?
}

out=$(with_period 1000000)
expected="$(printf 'a%.0s' {1..20})$(printf 'b%.0s' {1..20})c<illegal>d<fault>"
if [ "$out" = "$expected
0" ]; then echo "ok long period: the programs one after the other"; else fail "long period: $out"; fi

bad=0
for p in $(seq 30 13 400); do
  out=$(with_period $p); s=${out##*$'\n'}; text=${out%$'\n'*}; text=${text%$'\n'}
  letters=$(echo -n "$text" | sed 's/<illegal>//; s/<fault>//')
  na=$(echo -n "$letters" | tr -cd a | wc -c); nb=$(echo -n "$letters" | tr -cd b | wc -c)
  why=""
  [ "$s" = 0 ] || why="status $s"
  [ "$na" = 20 ] && [ "$nb" = 20 ] || why="$why; $na a, $nb b"
  case "$text" in *c*"<illegal>"*) ;; *) why="$why; no c then <illegal>" ;; esac
  case "$text" in *d*"<fault>"*) ;; *) why="$why; no d then <fault>" ;; esac
  last_a=$(echo -n "$letters" | grep -bo a | tail -1 | cut -d: -f1); first_b=$(echo -n "$letters" | grep -bo b | head -1 | cut -d: -f1)
  [ "$p" -le 100 ] && { [ -n "$first_b" ] && [ "$first_b" -lt "$last_a" ] || why="$why; not interleaved"; }
  [ "$(with_period $p)" = "$out" ] || why="$why; not the same twice"
  if [ -n "$why" ]; then bad=$((bad + 1)); [ $bad -le 3 ] && echo "  period $p: $why: $text"; fi
done
if [ $bad = 0 ]; then echo "ok 29 periods, 30-400: every letter, both faults caught, halted with 0, interleaved, the same twice"; else fail "periods: $bad of 29"; fi

$T -o $W/kernel.img $K
if [ "$($T $W/kernel.img; echo $?)" = "$($T $K; echo $?)" ] && [ "$($T -l $W/kernel.img)" = "$($T -l $K)" ]; then
  echo "ok image: run and listed as the source"
else fail "image: not as the source"; fi

echo "TinyMachine_test: $failures failures"
exit $((failures > 0))
