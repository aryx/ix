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
# The differential tests of TinyEd: the same scripts through tinyed and
# 9base's ed (plan9port's, as Debian packages it), like shell/'s.
#
#   differential.sh record [case.ed ...]  write case.out from 9base's ed
#   differential.sh check  [case.ed ...]  compare tinyed with case.out
#                                         (or case.tiny.out, where TinyEd
#                                         differs from 9base on purpose)
#   differential.sh live   [case.ed ...]  compare both, live
#
# A case is case.ed, the commands, and optionally case.txt, the file to
# edit, and case.args, ed's arguments (default: case.txt if there is
# one). It runs in a fresh directory, the commands on standard input
# from a file, or through a pipe if there is a case.pipe; recorded are
# stdout and stderr, the exit status, then every file of the directory
# after (case.ed aside), each after a "--- name" line.

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CORPUS=$ROOT/editor/tests/corpus
TINYED=${TINYED:-$ROOT/_build/default/editor/Main.exe}
ED=${ED:-/usr/lib/plan9/bin/ed}

mode=${1:-check}
[ $# -gt 0 ] && shift
cases=${*:-$CORPUS/*.ed}

run_case() {
  prog=$1 case=$2 base=${2%.ed}
  dir=$(mktemp -d)
  cp "$case" "$dir/case.ed"
  [ -f "$base.txt" ] && cp "$base.txt" "$dir/case.txt"
  if [ -f "$base.args" ]; then args=$(cat "$base.args")
  elif [ -f "$base.txt" ]; then args=case.txt
  else args=; fi
  (
    cd "$dir" || exit 1
    if [ -f "$base.pipe" ]; then
      cat case.ed | env -i PATH="/usr/bin:/bin" HOME=/nonexistent timeout -s KILL 10 $prog $args 2>&1
    else
      env -i PATH="/usr/bin:/bin" HOME=/nonexistent timeout -s KILL 10 $prog $args < case.ed 2>&1
    fi
    echo "[exit $?]"
    for f in $(ls -A | sort); do
      [ "$f" = case.ed ] && continue
      echo "--- $f"; cat -v "$f"
    done
  ) | sed -e "s|$dir|DIR|g"
  rm -rf "$dir"
}

status=0
for case in $cases; do
  name=$(basename "$case" .ed)
  out=${case%.ed}.out
  case $mode in
    record) run_case "$ED" "$case" > "$out"; echo "recorded $name";;
    check)
      [ -f "${case%.ed}.tiny.out" ] && out=${case%.ed}.tiny.out
      if run_case "$TINYED" "$case" | diff -u "$out" - > /tmp/$$.diff; then echo "ok   $name"
      else echo "FAIL $name"; cat /tmp/$$.diff; status=1; fi;;
    live)
      run_case "$ED" "$case" > /tmp/$$.ed
      run_case "$TINYED" "$case" > /tmp/$$.tiny
      if cmp -s /tmp/$$.ed /tmp/$$.tiny; then echo "same  $name"
      else echo "DIFF  $name"; diff /tmp/$$.ed /tmp/$$.tiny | head -20; status=1; fi;;
  esac
done
rm -f /tmp/$$.*
exit $status
