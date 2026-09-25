#!/bin/sh
# Claude Code
#
# Copyright (C) 2026 Yoann Padioleau
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Library General Public License
# (LGPL) as published by the Free Software Foundation; either version
# 2 of the License, or (at your option) any later version.
#
# mk -n in every directory of a tree that has a mkfile, through 9base's
# mk (with -i: mini-mk does not pretend, see Build.mli) and mini-mk; each
# directory's stdout and exit status compared exactly.
#
#   tree_differential.sh ~/xix        # (a copy of) xix, or principia
#
# One line per directory: "same" or "diff", 9base's and mini-mk's exit
# statuses, and the directory; the outputs are left in $OUT (default
# /tmp/tree_differential) for the ones that differ. Runs with MKSHELL
# unset, because 9base ignores it and mini-mk does not (Mkfile.mli).
# -n runs no recipes, but a mkfile's backquotes and <| still run.

ROOT=${1:?usage: tree_differential.sh dir}
HERE=$(cd "$(dirname "$0")/../.." && pwd)
MINIMK=${MINIMK:-$HERE/_build/default/builder/Main.exe}
MK=${MK:-/usr/lib/plan9/bin/mk}
OUT=${OUT:-/tmp/tree_differential}
rm -rf "$OUT"; mkdir -p "$OUT"
unset MKSHELL
export PATH="$ROOT/bin:$PATH"

cd "$ROOT" || exit 1
find -L . -name mkfile -not -path './_build/*' 2>/dev/null | sort | while read -r f; do
  d=$(dirname "$f"); k=$(echo "$d" | sed -e 's|^\./||' -e 's|/|_|g' -e 's|^\.$|top|')
  ( cd "$d" || exit
    timeout 30 "$MK" -n -i > "$OUT/$k.mk" 2> "$OUT/$k.mk.err"; echo $? > "$OUT/$k.mk.st"
    timeout 30 "$MINIMK" -n > "$OUT/$k.tiny" 2> "$OUT/$k.tiny.err"; echo $? > "$OUT/$k.tiny.st" )
  st="$(cat "$OUT/$k.mk.st") $(cat "$OUT/$k.tiny.st")"
  if cmp -s "$OUT/$k.mk" "$OUT/$k.tiny" && cmp -s "$OUT/$k.mk.st" "$OUT/$k.tiny.st"
  then r=same; rm -f "$OUT/$k".*; else r=diff; fi
  echo "$r $st $d"
done
