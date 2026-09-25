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
# The differential tests: the same mkfiles through mini-mk, 9base's mk
# (plan9port's, as packaged by Debian) and xix's omk.
#
#   differential.sh record [case.mk ...]  write case.out from 9base's mk
#   differential.sh check  [case.mk ...]  compare mini-mk with case.out
#                                         (or case.mini.out, where mini-mk
#                                         differs from 9base on purpose)
#   differential.sh live   [case.mk ...]  compare all three, live
#
# A case is a mkfile in corpus/ whose first lines are directives,
# comments to mk, run in order:
#
#   #!setup touch -d '2026-01-01 10:00:00' foo.c    (sh, in a fresh dir)
#   #!args -n foo                                   (one run of mk each)
#
# Each run's output (stdout and stderr) is printed after "$ mk args",
# with its exit status, the directory replaced by DIR. The environment
# is emptied but for PATH and HOME, so NPROC, MKSHELL and the rest come
# from the case.

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CORPUS=$ROOT/builder/tests/corpus
MINIMK=${MINIMK:-$ROOT/_build/default/builder/Main.exe}
MK=${MK:-/usr/lib/plan9/bin/mk}
OMK=${OMK:-$(command -v omk)}

mode=${1:-check}
[ $# -gt 0 ] && shift
cases=${*:-$CORPUS/*.mk}

run_case() {
  prog=$1 case=$2
  dir=$(mktemp -d)
  cp "$case" "$dir/mkfile"
  (
    cd "$dir" || exit 1
    grep '^#!' mkfile | while IFS= read -r line; do
      case $line in
        '#!setup '*) sh -c "${line#'#!setup '}";;
        '#!args'*)
          args=${line#'#!args'}; args=${args# }
          echo "\$ mk $args"
          # shellcheck disable=SC2086
          env -i PATH="$PATH" HOME=/nonexistent timeout 20 $prog $args 2>&1 </dev/null
          echo "[exit $?]";;
      esac
    done
  ) | sed "s|$dir|DIR|g"
  rm -rf "$dir"
}

status=0
for case in $cases; do
  name=$(basename "$case" .mk)
  out=${case%.mk}.out
  case $mode in
    record)
      run_case "$MK" "$case" > "$out"
      echo "recorded $name";;
    check)
      # a documented difference from 9base: mini-mk's own expected output
      [ -f "${case%.mk}.mini.out" ] && out=${case%.mk}.mini.out
      if run_case "$MINIMK" "$case" | diff -u "$out" - > /tmp/$$.diff; then
        echo "ok   $name"
      else
        echo "FAIL $name"; cat /tmp/$$.diff; status=1
      fi;;
    live)
      run_case "$MK" "$case" > /tmp/$$.mk
      run_case "$MINIMK" "$case" > /tmp/$$.mini
      # omk prints a recipe as |recipe| and colours its errors: strip both
      if [ -n "$OMK" ]; then
        run_case "$OMK" "$case" | sed -e 's/^|\(.*\)|$/\1/' -e 's/\x1b\[[0-9;]*m//g' > /tmp/$$.omk
      fi
      if cmp -s /tmp/$$.mk /tmp/$$.mini; then r="mini-mk=mk"; else r="mini-mk!=mk"; status=1; fi
      if [ -n "$OMK" ]; then
        if cmp -s /tmp/$$.mk /tmp/$$.omk; then r="$r omk=mk"; else r="$r omk!=mk"; fi
      fi
      echo "$r  $name";;
  esac
done
rm -f /tmp/$$.*
exit $status
