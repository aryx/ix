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
# mini-ml's programs, on arm (5, under qemu-arm) or arm64 (7), by ix's
# toolchain alone: the stdlib (ocaml-light's, $OCL/src/stdlib, every
# module, in its Makefile's order) and each program compiled by mini-ml,
# the runtime (runtime/runtime.c) by mini-cc, goken's libc by mini-cc or
# mini-asm (linker/tests/libc.sh), the start object by mini-ml -start,
# all linked by mini-ld; then run, and its output and exit status
# compared with prog.out (the plan's contract: ocaml-light's ocamlopt's,
# recorded by tiny/TinyML_test.sh's RECORD=1 for tests/tiny/), or, with
# LIVE=1, with ocamlopt's for that machine run now. With ML_HEAP=64
# again: the collector's law.
# usage: run.sh 5|7 workdir prog.ml...

set -u
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
IX=$ROOT/_build/default
ML=$IX/languages/ml/Main.exe
O=$1; W=$(realpath -m $2); shift 2
case $O in 5) ARCH=arm; RUN="qemu-arm";; 7) ARCH=arm64; RUN="";; esac
OCL=${OCL:-/tmp/ix-ocaml-light-$ARCH}
S=/tmp/ix-ocaml-light-arm64/src/stdlib
mkdir -p $W/std $W/run
export PATH=$HOME/goken/bin:$HOME/goken/ROOT/arch/boot-gcc/bin:$PATH
INC="-I$HOME/goken/include -I$HOME/goken/include/ALL -I$HOME/goken/include/arch/$ARCH"

# the libc, once per workdir; the runtime and the stdlib, each run
[ -f $W/libc/t/libc.a ] || $ROOT/linker/tests/libc.sh $O $W/libc > /dev/null
$IX/languages/c/Main.exe -m $O $INC -o $W/runtime.$O $ROOT/languages/ml/runtime/runtime.c || { echo "FAIL the runtime"; exit 1; }
units=$(sed -n '/^OBJS=/,/^$/p' $S/Makefile | grep -o '[a-z0-9_]*\.cmo' | sed 's/\.cmo$//')
declare -A deps
for u in $units std_exit; do
  $ML -m $O -I $S -o $W/std/$u.$O $S/$u.ml || { echo "FAIL the stdlib: $u"; exit 1; }
  deps[${u^}]=$($ML -M -I $S $S/$u.ml)
done
# the units a program needs, transitively, in the stdlib's order
needs() {
  declare -A seen
  local todo=($@) u
  while [ ${#todo[@]} -gt 0 ]; do
    u=${todo[0]}; todo=("${todo[@]:1}")
    [ -n "${seen[$u]:-}" ] && continue
    seen[$u]=1; todo+=(${deps[$u]:-})
  done
  for u in $units; do [ -n "${seen[${u^}]:-}" ] && echo -n "${u^} "; done
}

failures=0
for ml in "$@"; do
  ml=$(realpath $ml)
  b=$(basename $ml .ml)
  $ML -m $O -I $S -o $W/$b.$O $ml || { echo "FAIL $b: mini-ml"; failures=$((failures + 1)); continue; }
  names=$(needs Pervasives $($ML -M -I $S $ml))
  $ML -m $O -start $names ${b^} Std_exit -o $W/$b.start.$O
  objs=$(for u in $names; do echo -n "$W/std/${u,}.$O "; done)
  $IX/linker/Main.exe -m $O -H7 -o $W/$b $W/$b.start.$O $objs $W/$b.$O $W/std/std_exit.$O $W/runtime.$O $W/libc/t/libc.a \
    || { echo "FAIL $b: mini-ld"; failures=$((failures + 1)); continue; }
  if [ -n "${LIVE:-}" ]; then
    (cd $W/run && cp $ml $b.ml && $OCL/bin/ocamlopt -o $b.ref $b.ml 2>/dev/null) || { echo "FAIL $b: ocamlopt"; failures=$((failures + 1)); continue; }
    want=$(cd $W/run && timeout 20 $RUN ./$b.ref 2>&1; echo "exit $?")
  else
    want=$(cat ${ml%.ml}.out)
  fi
  got=$(cd $W/run && timeout 20 $RUN $W/$b 2>&1; echo "exit $?")
  if [ "$want" = "$got" ]; then echo "ok $b"; else echo "FAIL $b"; /usr/bin/diff <(echo "$want") <(echo "$got") | head -10; failures=$((failures + 1)); continue; fi
  got=$(cd $W/run && ML_HEAP=64 timeout 60 $RUN $W/$b 2>&1; echo "exit $?")
  if [ "$want" = "$got" ]; then echo "ok $b ML_HEAP=64"; else echo "FAIL $b ML_HEAP=64"; /usr/bin/diff <(echo "$want") <(echo "$got") | head -10; failures=$((failures + 1)); fi
done
echo "$failures failure(s)"
[ $failures = 0 ]
