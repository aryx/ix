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
# The tests of TinyAssembler.ml, which need goken (~/goken, built, with
# its arm64 libc): goken's exit and hello for arm64, run; then goken's
# libc through 7c -S, all of it, with each of goken's hello_libc
# programs, run in a copy of their directory and compared with their
# *_expected.txt, as goken's own test does.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TA=${TA:-$ROOT/_build/default/tiny/TinyAssembler.exe}
GOKEN=${GOKEN:-$HOME/goken}
export PATH=$GOKEN/bin:$GOKEN/ROOT/arch/boot-gcc/bin:$PATH
W=$(mktemp -d)
trap 'rm -rf $W' EXIT
failures=0
check() { if [ "$2" = "$3" ]; then echo "ok $1"; else echo "FAIL $1: $3"; failures=$((failures + 1)); fi; }

$TA -e _start -o $W/exit $GOKEN/tests/s/exit/exit_linux_arm64.s; $W/exit
check exit 42 $?
$TA -e _start -o $W/hello $GOKEN/tests/s/hello_arch/hello_linux_arm64.s
check hello "Hello, world" "$($W/hello)"

# the libc's assembly, in its mkfile's order (which decides the first of
# two strtod), 7c's listing being the lines with a tab
mkdir $W/libc
libc=()
cd $GOKEN/lib_core/libc
while read -r line; do
  set -- $line
  src=${@: -1}; b=$(echo ${src%.*} | tr / _)
  case $1 in
  7c) flags=$(echo "$line" | sed -e 's/^7c //' -e 's/ -o [^ ]* [^ ]*$//' -e 's/\$CFLAGS_EXTRA//')
      7c $flags -S -o $W/libc/$b.7 $src 2>/dev/null | grep '^	' > $W/libc/$b.s; libc+=($W/libc/$b.s) ;;
  7a) libc+=($GOKEN/lib_core/libc/$src) ;;
  esac
done < <(mk -a -n objtype=arm64 cputype=arm64 2>/dev/null)
cd - > /dev/null

T=$GOKEN/tests/c/hello_libc
cp -r $T $W/hello_libc
for c in $T/*.c; do
  b=$(basename $c .c)
  (cd $T && 7c -I$GOKEN/include -I$GOKEN/include/ALL -I$GOKEN/include/arch/arm64 -S -o $W/$b.7 $b.c 2>/dev/null | grep '^	' > $W/$b.s)
  $TA -o $W/$b.exe $W/$b.s "${libc[@]}" || { check $b built failed; continue; }
  expected=$b; [ $b = hello ] && expected=""
  out=$(cd $W/hello_libc && timeout 10 $W/$b.exe one two three 2>/dev/null)
  check $b "$(cat $T/${expected:+${expected}_}expected.txt)" "$out"
done
echo "$failures failure(s)"
[ $failures = 0 ]
