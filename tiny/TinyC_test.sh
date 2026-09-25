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
# The tests of TinyC.ml, which need goken (~/goken, built, with its
# arm64 libc): each program of TinyC_tests/ compiled by TinyC and by
# 7c, both assembled with all of goken's libc (7c -S) by TinyAssembler,
# run, and their outputs and exit statuses compared.
# usage: TinyC_test.sh [prog.c...]

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TC=${TC:-$ROOT/_build/default/tiny/TinyC.exe}
TA=${TA:-$ROOT/_build/default/tiny/TinyAssembler.exe}
GOKEN=${GOKEN:-$HOME/goken}
export PATH=$GOKEN/bin:$GOKEN/ROOT/arch/boot-gcc/bin:$PATH
W=${W:-$(mktemp -d)}
[ -n "${KEEP:-}" ] || trap 'rm -rf $W' EXIT
failures=0
progs=("$@")

# the libc's assembly, in its mkfile's order, 7c's listing being the
# lines with a tab
mkdir -p $W/libc
libc=()
pushd $GOKEN/lib_core/libc > /dev/null
while read -r line; do
  set -- $line
  src=${@: -1}; b=$(echo ${src%.*} | tr / _)
  case $1 in
  7c) flags=$(echo "$line" | sed -e 's/^7c //' -e 's/ -o [^ ]* [^ ]*$//' -e 's/\$CFLAGS_EXTRA//')
      7c $flags -S -o $W/libc/$b.7 $src 2>/dev/null | grep '^	' > $W/libc/$b.s; libc+=($W/libc/$b.s) ;;
  7a) libc+=($GOKEN/lib_core/libc/$src) ;;
  esac
done < <(mk -a -n objtype=arm64 cputype=arm64 2>/dev/null)
popd > /dev/null

T=$ROOT/tiny/TinyC_tests
[ ${#progs[@]} = 0 ] && progs=($T/*.c)
for c in "${progs[@]}"; do
  b=$(basename $c .c)
  # claude: 7c -O0: its optimizer gets some constants wrong (plan_bugs_goken.md)
  (cd $(dirname $c) && 7c -O0 -S -o $W/$b.7 $b.c 2>/dev/null | grep '^	' > $W/$b.ref.s) || { echo "7c-FAIL $b"; continue; }
  $TC -o $W/$b.s $c || { echo "FAIL $b: tiny-c"; failures=$((failures + 1)); continue; }
  $TA -o $W/$b.ref $W/$b.ref.s "${libc[@]}" || { echo "FAIL $b: assembling 7c's"; failures=$((failures + 1)); continue; }
  $TA -o $W/$b.exe $W/$b.s "${libc[@]}" || { echo "FAIL $b: assembling"; failures=$((failures + 1)); continue; }
  # the same name in two directories, for argv[0]
  mkdir -p $W/ref $W/tiny-c; cp $W/$b.ref $W/ref/$b; cp $W/$b.exe $W/tiny-c/$b
  want=$(cd $W/ref && timeout 10 ./$b one two 2>&1; echo "exit $?")
  got=$(cd $W/tiny-c && timeout 10 ./$b one two 2>&1; echo "exit $?")
  if [ "$want" = "$got" ]; then echo "ok $b"; else echo "FAIL $b"; /usr/bin/diff <(echo "$want") <(echo "$got") | /usr/bin/head -10; failures=$((failures + 1)); fi
done
echo "$failures failure(s)"
[ $failures = 0 ]
