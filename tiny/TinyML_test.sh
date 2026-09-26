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
# The tests of TinyML.ml, which need goken (~/goken, built, with its
# arm64 libc): each program of languages/ml/tests/tiny/ compiled by
# tiny-ml, linked with the runtime (TinyML_runtime.c, by tiny-c) and
# all of goken's libc (7c -S) by TinyAssembler, run, and its output and
# exit status compared with the recorded ones (prog.out), which are
# ocaml-light's arm64 ocamlopt's: RECORD=1 records them again, from
# $OCL (default /tmp/ix-ocaml-light-arm64, built by
# kernel/ocaml-light.sh arm64). Then the collector's law: each program
# again with a heap of 64 words, where it collects all the time, the
# same output.
# usage: TinyML_test.sh [prog.ml...]

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TML=${TML:-$ROOT/_build/default/tiny/TinyML.exe}
TC=${TC:-$ROOT/_build/default/tiny/TinyC.exe}
TA=${TA:-$ROOT/_build/default/tiny/TinyAssembler.exe}
GOKEN=${GOKEN:-$HOME/goken}
OCL=${OCL:-/tmp/ix-ocaml-light-arm64}
export PATH=$GOKEN/bin:$GOKEN/ROOT/arch/boot-gcc/bin:$PATH
W=${W:-$(mktemp -d)}
[ -n "${KEEP:-}" ] || trap 'rm -rf $W' EXIT
failures=0
progs=("$@")

# the libc's assembly, in its mkfile's order, 7c's listing being the
# lines with a tab (TinyC_test.sh's)
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

$TC -o $W/runtime.s $ROOT/tiny/TinyML_runtime.c || { echo "FAIL the runtime: tiny-c TinyML_runtime.c"; exit 1; }

T=$ROOT/languages/ml/tests/tiny
[ ${#progs[@]} = 0 ] && progs=($T/*.ml)
for ml in "${progs[@]}"; do
  ml=$(realpath $ml); b=$(basename $ml .ml)
  out=${ml%.ml}.out
  if [ -n "${RECORD:-}" ]; then
    (cd $W && cp $ml $b.ml && $OCL/bin/ocamlopt -o $b.ref $b.ml 2>/dev/null) || { echo "FAIL $b: ocamlopt"; failures=$((failures + 1)); continue; }
    (cd $W && timeout 10 ./$b.ref 2>&1; echo "exit $?") > $out
  fi
  $TML -o $W/$b.s $ml || { echo "FAIL $b: tiny-ml"; failures=$((failures + 1)); continue; }
  $TA -o $W/$b $W/$b.s $W/runtime.s "${libc[@]}" || { echo "FAIL $b: assembling"; failures=$((failures + 1)); continue; }
  want=$(cat $out)
  got=$(cd $W && timeout 10 ./$b 2>&1; echo "exit $?")
  if [ "$want" = "$got" ]; then echo "ok $b"; else echo "FAIL $b"; /usr/bin/diff <(echo "$want") <(echo "$got") | /usr/bin/head -10; failures=$((failures + 1)); continue; fi
  got=$(cd $W && ML_HEAP=64 timeout 20 ./$b 2>&1; echo "exit $?")
  if [ "$want" = "$got" ]; then echo "ok $b ML_HEAP=64"; else echo "FAIL $b ML_HEAP=64"; /usr/bin/diff <(echo "$want") <(echo "$got") | /usr/bin/head -10; failures=$((failures + 1)); fi
done
echo "$failures failure(s)"
[ $failures = 0 ]
