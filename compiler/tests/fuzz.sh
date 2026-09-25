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
# mini-cc against 5c -O0 and 7c -O0 on random programs (TinyC's
# generator, tiny/TinyC_fuzz.py): the listings the same, instruction
# for instruction, on both machines.
# usage: fuzz.sh workdir count [seed]
set -u
export PATH=$HOME/goken/bin:$HOME/goken/ROOT/arch/boot-gcc/bin:$PATH
ROOT=$(cd $(dirname $0)/../.. && pwd)
IX=$ROOT/_build/default
W=$1; N=$2; SEED=${3:-1}
rm -rf $W; mkdir -p $W/p
cp $ROOT/tiny/TinyC_tests/libc.h $W/
python3 $ROOT/tiny/TinyC_fuzz.py $W/p $N $SEED
same=0; diff=0
for c in $W/p/*.c; do
  b=$(basename $c .c)
  for o in 5 7; do
    (cd $W/p && ${o}c -O0 -S -o /dev/null $b.c 2>/dev/null | grep '^	' > $W/$b.$o.g)
    (cd $W/p && $IX/compiler/Main.exe -m $o -S -o /dev/null $b.c > $W/$b.$o.t 2>&1)
    if cmp -s $W/$b.$o.g $W/$b.$o.t; then same=$((same+1)); else diff=$((diff+1)); echo "DIFF $b -m $o $(/usr/bin/diff $W/$b.$o.g $W/$b.$o.t | grep -c '^[<>]')"; fi
  done
done
echo "same $same, diff $diff"
