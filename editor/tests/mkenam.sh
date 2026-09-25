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
# Milestone 1 of plan_ed.md: principia's mkenam scripts, the ed
# scripts that make an assembler's opcode table (enam.c) from its
# header, run by 9base's ed and by mini-ed; the two enam.c must be the
# same. The headers are given where they are now (include/obj/): the
# scripts still name the old paths.
#
#   editor/tests/mkenam.sh [principia]   # default ~/github/principia-softwarica

P=${1:-$HOME/github/principia-softwarica}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MINIED=${MINIED:-$ROOT/_build/default/editor/Main.exe}
ED=${ED:-/usr/lib/plan9/bin/ed}
d=$(mktemp -d)
status=0
for arch in 5c:5 8c:8; do
  c=${arch%:*} n=${arch#*:}
  # the ed script: the here document of mkenam
  sed -n '2,/^!$/p' "$P/compilers/$c/mkenam" | sed '$d' > "$d/$c.ed"
  for prog in "$ED" "$MINIED"; do
    k=$(basename "$prog")
    sed "s|w enam.c|w $d/enam.$c.$k|" "$d/$c.ed" | $prog - "$P/include/obj/$n.out.h" > "$d/out.$c.$k" 2>&1
  done
  if cmp -s "$d/enam.$c.ed" "$d/enam.$c.Main.exe" 2>/dev/null && cmp -s "$d/out.$c.ed" "$d/out.$c.Main.exe"; then
    echo "same $c: $(wc -l < "$d/enam.$c.ed") lines"
  elif [ ! -f "$d/enam.$c.ed" ] && [ ! -f "$d/enam.$c.Main.exe" ] && cmp -s "$d/out.$c.ed" "$d/out.$c.Main.exe"; then
    echo "same $c: both fail alike ($(grep -c '?' "$d/out.$c.ed") errors)"
  else
    echo "DIFF $c"; status=1
  fi
done
rm -rf "$d"
exit $status
