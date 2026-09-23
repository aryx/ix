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
# The counts behind plan_mk.md's feature table: how many of the
# mkfiles reachable from ~/xix (xix's own, and principia's through the
# xix/principia link) use each feature of mk, by `grep -l` on a regular
# expression per feature. Counts of files, not of meaning: a crude
# pattern can miscount, and each is the one written here.
#
#   builder/tests/count_features.sh [dir]     # default ~/xix
#
# Rewritten after the fact (the first count was typed at a shell): its
# numbers are close to the table's, and where they differ, the plan
# says so.

DIR=${1:-$HOME/xix}
files=$(find -L "$DIR" \( -name mkfile -o -path '*/mkfiles/*' \) -type f -not -path '*/_build/*' 2>/dev/null)
echo "$(echo "$files" | wc -l) mkfiles under $DIR"

count() {
  n=$(echo "$files" | xargs grep -lE -e "$2" 2>/dev/null | wc -l)
  printf '%5d  %s\n' "$n" "$1"
}

count '<file include'              '^<[^|]'
count ':V: virtual'                '^[^#=]*:[A-Za-z]*V[A-Za-z]*:'
count '% metarules'                '^[^\t#]*%'
count '$target'                    '\$target'
count '$prereq'                    '\$prereq'
count '$stem'                      '\$stem'
count '${v:A%B=C%D} substitution'  '\$\{[A-Za-z_][A-Za-z_0-9]*:'
count '`{cmd} backquote'           '`'
count ':D: delete on error'        '^[^#=]*:[A-Za-z]*D[A-Za-z]*:'
count ':Q: quiet'                  '^[^#=]*:[A-Za-z]*Q[A-Za-z]*:'
count '$NPROC'                     'NPROC'
count '<|cmd pipe include'         '^<\|'
count '& metarules'                '^[^#=\t]*&[^=]*:'
count ':N:'                        '^[^#=]*:[A-Za-z]*N[A-Za-z]*:'
count '$newprereq'                 '\$newprereq'
count '$newmember'                 '\$newmember'
count 'archives, lib.a(foo.o)'     '\.a\([^)]|\$LIB\('
count ':R: regexp rules'           '^[^#=]*:[A-Za-z]*R[A-Za-z]*:'
count ':P: custom test'            '^[^#=]*:P[^:]*:'
count ':E:'                        '^[^#=]*:[A-Za-z]*E[A-Za-z]*:'
count ':n:'                        '^[^#=]*:[A-Za-z]*n[A-Za-z]*:'
count ':U:'                        '^[^#=]*:[A-Za-z]*U[A-Za-z]*:'
count 'var=U=value'                '^[A-Za-z_]+=U='
