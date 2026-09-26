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
# mini-ml's type checker against ocaml-light's (plan_ml.md, phase 4):
# - each program's toplevel values' types, mini-ml -i against ocamlopt
#   -i ($OCL, the arm64 one), the val lines only, the type variables
#   renamed in their order ('a, 'b...; '_a... for the weak ones);
# - each program of typing/bad/ rejected by both.
# usage: types.sh [prog.ml...]   (default: tests/tiny/, ocaml-light's
#   test/'s single files, typing/bad/)

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
ML=${ML:-$ROOT/_build/default/languages/ml/Main.exe}
OCL=${OCL:-/tmp/ix-ocaml-light-arm64}
S=$OCL/src/stdlib
W=$(mktemp -d); trap 'rm -rf $W' EXIT
T=$(cd "$(dirname "$0")" && pwd)
failures=0

# the val lines, a line each, the variables renamed in order
norm() {
  python3 -c '
import re, sys
text = sys.stdin.read()
items = re.split(r"\n(?=\S)", text)
for it in items:
    it = " ".join(it.split())
    if not it.startswith("val "): continue
    names = {}
    def ren(m):
        v = m.group(0)
        if v not in names:
            weak = v.startswith("\x27_")
            n = sum(1 for k in names if k.startswith("\x27_") == weak)
            names[v] = ("\x27_" if weak else "\x27") + chr(97 + n)
        return names[v]
    print(re.sub(r"\x27_?[a-z][a-z0-9_]*", ren, it))
'
}

progs=("$@")
[ ${#progs[@]} = 0 ] && progs=($T/tiny/*.ml $(ls $HOME/ocaml-light/test/*.ml) $T/typing/bad/*.ml)
for ml in "${progs[@]}"; do
  b=$(basename $ml .ml)
  cp $ml $W/$b.ml
  ref=$(cd $W && $OCL/bin/ocamlopt -i -c $b.ml 2>/dev/null); rs=$?
  got=$($ML -i -I $S $W/$b.ml 2>/dev/null); gs=$?
  if [[ $ml == */bad/* ]]; then
    if [ $rs != 0 ] && [ $gs != 0 ]; then echo "ok $b rejected"
    elif [ $rs = 0 ]; then echo "FAIL $b: ocamlopt accepts it"; failures=$((failures + 1))
    else echo "FAIL $b: mini-ml accepts it"; failures=$((failures + 1)); fi
    continue
  fi
  [ $rs = 0 ] || { echo "skip $b: ocamlopt rejects it"; continue; }
  [ $gs = 0 ] || { echo "FAIL $b: mini-ml rejects it: $($ML -i -I $S $W/$b.ml 2>&1 | head -1)"; failures=$((failures + 1)); continue; }
  if [ "$(echo "$ref" | norm)" = "$(echo "$got" | norm)" ]; then echo "ok $b"
  else echo "FAIL $b"; diff <(echo "$ref" | norm) <(echo "$got" | norm) | head -6; failures=$((failures + 1)); fi
done
echo "$failures failure(s)"
[ $failures = 0 ]
