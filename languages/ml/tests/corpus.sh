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
# mini-ml's front end over its corpus (plan_ml.md, phase 2): every .ml
# and .mli of mini-9pi (kernel/9pi, kernel/lib), of ocaml-light's
# stdlib (the one the kernels are built with: $OCL/src/stdlib, from
# kernel/ocaml-light.sh) and of its test/ ($OCAML_LIGHT/test), through
# mini-ml (parsed, and a .ml's names resolved), with the kernel's and
# the stdlib's directories as -I; each failure printed, then
# the counts. The files outside the subset are expected to fail:
# EXPECTED lists them.
# usage: corpus.sh [file...]

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
ML=${ML:-$ROOT/_build/default/languages/ml/Main.exe}
OCL=${OCL:-/tmp/ix-ocaml-light-arm64}
OCAML_LIGHT=${OCAML_LIGHT:-$HOME/ocaml-light}
files=("$@")
if [ ${#files[@]} = 0 ]; then
  files=($ROOT/kernel/9pi/*.ml $ROOT/kernel/9pi/*.mli $ROOT/kernel/lib/*.ml $ROOT/kernel/lib/*.mli)
  [ -d $OCL/src/stdlib ] && files+=($OCL/src/stdlib/*.ml $OCL/src/stdlib/*.mli)
  [ -d $OCAML_LIGHT/test ] && files+=($(find $OCAML_LIGHT/test -name '*.ml' -o -name '*.mli' | sort))
fi
# outside the subset: let-operators (letstar), a functor (sets: Set.Make),
# Caml Light's #open (testmain); and Lex's main, whose Scanner and Grammar
# are generated (ocamllex, ocamlyacc)
EXPECTED=" letstar.ml sets.ml testmain.ml main.ml "
ok=0; expected=0; failures=0
for f in "${files[@]}"; do
  if out=$($ML -I $ROOT/kernel/lib -I $OCL/src/stdlib $f 2>&1 >/dev/null); then ok=$((ok + 1))
  elif [[ "$EXPECTED" == *" $(basename $f) "* ]]; then expected=$((expected + 1))
  else echo "FAIL $out"; failures=$((failures + 1)); fi
done
echo "$ok ok, $expected outside the subset, $failures failure(s)"
[ $failures = 0 ]
