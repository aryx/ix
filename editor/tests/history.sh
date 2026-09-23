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
# Milestone 2 of plan_ed.md: a repository's history, replayed. For each
# .ml file changed by each of the last N commits, the ed script of
# `diff -e old new` is run by tinyed and by 9base's ed on old; both
# must give new, and print the same (the counts).
#
#   history.sh [repo] [N]      default: ~/github/xix, 300
#
# A file without a final newline is skipped (diff -e can't say it).

REPO=${1:-$HOME/github/xix}
N=${2:-300}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TINYED=${TINYED:-$ROOT/_build/default/editor/Main.exe}
ED=${ED:-/usr/lib/plan9/bin/ed}
dir=$(mktemp -d)
total=0 same=0 skipped=0 bad=0

for c in $(git -C "$REPO" rev-list --no-merges -n "$N" HEAD); do
  for f in $(git -C "$REPO" diff-tree --no-commit-id --name-only -r --diff-filter=M "$c" -- '*.ml'); do
    git -C "$REPO" show "$c^:$f" > "$dir/old" 2>/dev/null || continue
    git -C "$REPO" show "$c:$f" > "$dir/new" 2>/dev/null || continue
    if [ -n "$(tail -c1 "$dir/old")" ] || [ -n "$(tail -c1 "$dir/new")" ]; then
      skipped=$((skipped + 1)); continue
    fi
    { diff -e "$dir/old" "$dir/new"; printf 'w\nq\n'; } > "$dir/script"
    total=$((total + 1))
    cp "$dir/old" "$dir/a"; cp "$dir/old" "$dir/b"
    (cd "$dir" && $ED a < script > out.a 2>&1)
    (cd "$dir" && $TINYED b < script > out.b 2>&1)
    if cmp -s "$dir/a" "$dir/new" && cmp -s "$dir/b" "$dir/new" && cmp -s "$dir/out.a" "$dir/out.b"; then
      same=$((same + 1))
    else
      bad=$((bad + 1))
      echo "DIFF $c $f"
    fi
  done
done
rm -rf "$dir"
echo "$total scripts: $same the same, $bad different; $skipped files skipped"
[ $bad -eq 0 ]
