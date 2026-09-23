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
# Milestone 1 of plan_rc.md: principia's rc scripts (the 133 of
# count_features.py), each run with no arguments, in an empty
# directory, under 9base's rc and tinyrc; one line per script, "same"
# or "diff", and the two outputs of each diff in $OUT.
#
#   shell/tests/principia_scripts.sh      # takes a few minutes
#
# A sandbox of a kind: commands that destroy or change the system (rm,
# kill, git, mount, ...) are stubs that print what they were asked,
# first in $PATH, and the environment is emptied. 10 s each, with
# SIGKILL: 9base's rc ignores timeout's SIGTERM (it spins forever after
# a failed exec). Masked: pids, the /dev/fd numbers, argv0, the temp
# directory. Not in make test: the scripts are principia's, not ix's.

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TINYRC=${TINYRC:-$ROOT/_build/default/shell/Main.exe}
RC=${RC:-/usr/lib/plan9/bin/rc}
OUT=${OUT:-/tmp/principia_scripts}
rm -rf "$OUT"; mkdir -p "$OUT/stubs"
for c in rm mv cp dd kill chmod chown ln rmdir shutdown reboot halt mkfs mount umount tar git; do
  printf '#!/bin/sh\necho "[stub] %s $*"\n' $c > "$OUT/stubs/$c"; chmod +x "$OUT/stubs/$c"
done

run() {
  prog=$1 f=$2
  d=$(mktemp -d)
  (cd "$d" && env -i PATH="$OUT/stubs:/usr/bin:/bin" HOME=/nonexistent \
     timeout -s KILL 10 $prog "$HOME/principia/$f" </dev/null >out 2>&1; echo "[exit $?]" >> out
   sed -e 's/^[0-9][0-9]*: signal/PID: signal/' -e 's|rc ([^)]*)|rc (ARGV0)|g' -e "s|$d|DIR|g" \
       -e 's|/dev/fd/[0-9]*|/dev/fd/N|g' -e 's/[0-9]\{5,\}/PID/g' out)
  rm -rf "$d"
}

same=0 diff=0
for f in $("$ROOT/shell/tests/count_features.py" scripts --list | sed 's|^\./||'); do
  run "$RC" "$f" > "$OUT/rc.out"; run "$TINYRC" "$f" > "$OUT/tinyrc.out"
  if cmp -s "$OUT/rc.out" "$OUT/tinyrc.out"; then echo "same $f"; same=$((same + 1))
  else
    echo "diff $f"; diff=$((diff + 1))
    k=$(echo "$f" | tr / _); cp "$OUT/rc.out" "$OUT/$k.rc"; cp "$OUT/tinyrc.out" "$OUT/$k.tinyrc"
  fi
done
echo "$same the same, $diff different (outputs in $OUT)"
