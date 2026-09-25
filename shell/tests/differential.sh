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
# The differential tests of mini-rc: the same scripts through mini-rc
# and 9base's rc (plan9port's, as Debian packages it), like
# builder/tests/differential.sh for mk.
#
#   differential.sh record [case.rc ...]  write case.out from 9base's rc
#   differential.sh check  [case.rc ...]  compare mini-rc with case.out
#                                         (or case.mini.out, where mini-rc
#                                         differs from 9base on purpose)
#   differential.sh live   [case.rc ...]  compare both, live (and orc)
#
# Each case runs in a fresh directory, with the arguments a1 a2, an
# environment emptied but for PATH and HOME, and its output (stdout
# and stderr) followed by its exit status. What differs by nature is
# masked: pids, the /dev/fd numbers, and the name rc was run as.

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CORPUS=$ROOT/shell/tests/corpus
MINIRC=${MINIRC:-$ROOT/_build/default/shell/Main.exe}
RC=${RC:-/usr/lib/plan9/bin/rc}
ORC=${ORC:-$(command -v orc)}

mode=${1:-check}
[ $# -gt 0 ] && shift
cases=${*:-$CORPUS/*.rc}

run_case() {
  prog=$1 case=$2
  dir=$(mktemp -d)
  cp "$case" "$dir/case.rc"
  (
    cd "$dir" || exit 1
    touch a.c b.c .hidden; mkdir d1 d2; touch d1/x.c d2/y.c
    env -i PATH="/usr/local/bin:/usr/bin:/bin" HOME=/nonexistent \
      timeout 20 $prog ./case.rc a1 a2 2>&1 </dev/null
    echo "[exit $?]"
  ) | sed -e "s|$dir|DIR|g" -e 's/^[0-9][0-9]*: signal/PID: signal/' \
          -e 's|rc ([^)]*)|rc (ARGV0)|g' -e 's|/dev/fd/[0-9][0-9]*|/dev/fd/N|g'
  rm -rf "$dir"
}

status=0
for case in $cases; do
  name=$(basename "$case" .rc)
  out=${case%.rc}.out
  case $mode in
    record) run_case "$RC" "$case" > "$out"; echo "recorded $name";;
    check)
      [ -f "${case%.rc}.mini.out" ] && out=${case%.rc}.mini.out
      if run_case "$MINIRC" "$case" | diff -u "$out" - > /tmp/$$.diff; then echo "ok   $name"
      else echo "FAIL $name"; cat /tmp/$$.diff; status=1; fi;;
    live)
      run_case "$RC" "$case" > /tmp/$$.rc
      run_case "$MINIRC" "$case" > /tmp/$$.mini
      if cmp -s /tmp/$$.rc /tmp/$$.mini; then r="mini-rc=rc"; else r="mini-rc!=rc"; status=1; fi
      if [ -n "$ORC" ]; then
        run_case "$ORC" "$case" | sed 's/\x1b\[[0-9;]*m//g' > /tmp/$$.orc
        if cmp -s /tmp/$$.rc /tmp/$$.orc; then r="$r orc=rc"; else r="$r orc!=rc"; fi
      fi
      echo "$r  $name";;
  esac
done
rm -f /tmp/$$.*
exit $status
