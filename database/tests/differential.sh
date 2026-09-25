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
# mini-chidb against chidb: each corpus/*.sql session run by both, in a
# fresh directory, on a new database; their standard output, standard
# error and database files compared, byte for byte; and SQLite (Python's
# sqlite3) reading every table of the file. Needs ~/github/chidb built.
# usage: differential.sh [case.sql...]
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TDB=${TDB:-$ROOT/_build/default/database/Main.exe}
CHIDB=${CHIDB:-$HOME/github/chidb/chidb}
CORPUS=$ROOT/database/tests/corpus
W=$(mktemp -d)
trap 'rm -rf $W' EXIT
failures=0
cases=("$@")
[ ${#cases[@]} = 0 ] && cases=($CORPUS/*.sql)
sqlite_dump() {
  python3 - "$1" <<'PY' 2>&1
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
for name, typ in c.execute("select name, type from sqlite_master order by rowid"):
    if typ == "table":
        print(name, list(c.execute(f'select * from "{name}"')))
PY
}
for f in "${cases[@]}"; do
  f=$(realpath "$f")
  name=$(basename $f .sql)
  mkdir -p $W/c $W/t
  (cd $W/c && $CHIDB db.cdb < $f > out 2> err)
  (cd $W/t && $TDB db.cdb < $f > out 2> err)
  bad=""
  cmp -s $W/c/out $W/t/out || bad="$bad stdout"
  cmp -s $W/c/err $W/t/err || bad="$bad stderr"
  cmp -s $W/c/db.cdb $W/t/db.cdb || bad="$bad file"
  if [ -s $W/t/db.cdb ] && [ "$(sqlite_dump $W/t/db.cdb)" != "$(sqlite_dump $W/c/db.cdb)" ]; then bad="$bad sqlite"; fi
  if [ -z "$bad" ]; then echo "ok   $name"
  else
    echo "FAIL $name:$bad"; failures=$((failures + 1))
    /usr/bin/diff $W/c/out $W/t/out | head -${DIFFLINES:-10}
    /usr/bin/diff $W/c/err $W/t/err | head -${DIFFLINES:-10}
  fi
  rm -rf $W/c $W/t
done
echo "$failures failure(s)"
[ $failures = 0 ]
