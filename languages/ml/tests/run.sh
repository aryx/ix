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
# again: the collector's law. GAS=1 (arm): through GNU's tools instead,
# decision 8's route B: mini-ml -gas, the runtime by gcc, glibc, GNU's
# ld, the executable run under qemu-arm.
# A program is a file, or a directory of units (ordered by their
# dependencies, mini-ml -M).
# usage: run.sh 5|7 workdir prog.ml|dir...

set -u
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
IX=$ROOT/_build/default
ML=$IX/languages/ml/Main.exe
O=$1; W=$(realpath -m $2); shift 2
case $O in 5) ARCH=arm; RUN="qemu-arm";; 7) ARCH=arm64; RUN="";; esac
GAS=${GAS:-}
if [ -n "$GAS" ]; then
  [ $O = 5 ] || { echo "GAS=1: arm only"; exit 2; }
  RUN="qemu-arm -L /usr/arm-linux-gnueabihf"; E=s; FLAGS=-gas
else E=$O; FLAGS=; fi
OCL=${OCL:-/tmp/ix-ocaml-light-$ARCH}
S=/tmp/ix-ocaml-light-arm64/src/stdlib
mkdir -p $W/std $W/run
export PATH=$HOME/goken/bin:$HOME/goken/ROOT/arch/boot-gcc/bin:$PATH
INC="-I$HOME/goken/include -I$HOME/goken/include/ALL -I$HOME/goken/include/arch/$ARCH"

# the libc, once per workdir; the runtime and the stdlib, each run
if [ -n "$GAS" ]; then
  arm-linux-gnueabihf-gcc -marm -w -c -o $W/runtime.o $ROOT/languages/ml/runtime/runtime.c || { echo "FAIL the runtime"; exit 1; }
else
[ -f $W/libc/t/libc.a ] || $ROOT/linker/tests/libc.sh $O $W/libc > /dev/null
$IX/languages/c/Main.exe -m $O $INC -o $W/runtime.$O $ROOT/languages/ml/runtime/runtime.c || { echo "FAIL the runtime"; exit 1; }
fi
units=$(sed -n '/^OBJS=/,/^$/p' $S/Makefile | grep -o '[a-z0-9_]*\.cmo' | sed 's/\.cmo$//')
declare -A deps
for u in $units std_exit; do
  $ML -m $O $FLAGS -I $S -o $W/std/$u.$E $S/$u.ml || { echo "FAIL the stdlib: $u"; exit 1; }
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

# a directory's units in their dependencies' order (a unit before the
# ones naming it), then its main, the unit no other names
local_order() {
  local d=$1 u v done_=" " out=() progress=1
  local all=$(for f in $d/*.ml; do basename $f .ml; done)
  declare -A ldeps
  for u in $all; do ldeps[$u]=$($ML -M -I $S $d/$u.ml); done
  while [ $progress = 1 ]; do
    progress=0
    for u in $all; do
      [[ "$done_" == *" $u "* ]] && continue
      local ready=1
      for v in ${ldeps[$u]}; do for w in $all; do [ "${w^}" = "$v" ] && [[ "$done_" != *" $w "* ]] && ready=0; done; done
      [ $ready = 1 ] && { out+=($u); done_="$done_$u "; progress=1; }
    done
  done
  echo ${out[@]}
}

failures=0
for ml in "$@"; do
  ml=$(realpath $ml)
  b=$(basename $ml .ml)
  # a program: a file, or a directory of units
  if [ -d $ml ]; then srcs=(); for u in $(local_order $ml); do srcs+=($ml/$u.ml); done
  else srcs=($ml); fi
  own=(); mods=(); ok=1
  for src in ${srcs[@]}; do
    u=$(basename $src .ml)
    $ML -m $O $FLAGS -I $S -o $W/$b.$u.$E $src || { ok=0; break; }
    own+=($W/$b.$u.$E); mods+=(${u^})
  done
  [ $ok = 1 ] || { echo "FAIL $b: mini-ml"; failures=$((failures + 1)); continue; }
  names=$(needs Pervasives $(for src in ${srcs[@]}; do $ML -M -I $S $src; done))
  $ML -m $O $FLAGS -start $names ${mods[@]} Std_exit -o $W/$b.start.$E
  objs=$(for u in $names; do echo -n "$W/std/${u,}.$E "; done)
  if [ -n "$GAS" ]; then
    arm-linux-gnueabihf-gcc -marm -o $W/$b $W/$b.start.s $objs ${own[@]} $W/std/std_exit.s $W/runtime.o -lm 2> $W/$b.ld.log \
      || { echo "FAIL $b: gcc: $(head -1 $W/$b.ld.log)"; failures=$((failures + 1)); continue; }
  else
  $IX/linker/Main.exe -m $O -H7 -o $W/$b $W/$b.start.$O $objs ${own[@]} $W/std/std_exit.$O $W/runtime.$O $W/libc/t/libc.a \
    || { echo "FAIL $b: mini-ld"; failures=$((failures + 1)); continue; }
  fi
  if [ -n "${LIVE:-}" ]; then
    (cd $W/run && rm -f *.cm* *.mli || exit 1
     for src in ${srcs[@]}; do
       u=$(basename $src .ml); cp $src .
       if [ -f ${src%.ml}.mli ]; then cp ${src%.ml}.mli . && $OCL/bin/ocamlopt -c $u.mli || exit 1; fi
       $OCL/bin/ocamlopt -c $u.ml || exit 1
     done
     $OCL/bin/ocamlopt -o $b.ref $(for src in ${srcs[@]}; do echo -n "$(basename $src .ml).cmx "; done)) > /dev/null 2>&1 \
      || { echo "FAIL $b: ocamlopt"; failures=$((failures + 1)); continue; }
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
