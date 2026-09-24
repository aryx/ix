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
# The B-tree layer against chidb, byte for byte: the same tables and
# indexes built by chidb from SQL and by Btree_check through Btree
# alone, in key order and shuffled, until the roots and the internal
# nodes split. Needs ~/github/chidb built.
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CHK=$ROOT/_build/default/database/tests/Btree_check.exe
CHIDB=${CHIDB:-$HOME/github/chidb/chidb}
W=$(mktemp -d)
trap 'rm -rf $W' EXIT
failures=0
check() {   # name, sql, btree_check args...
  name=$1 sql=$2; shift 2
  printf '%s\n' "$sql" | $CHIDB $W/c.cdb > /dev/null
  $CHK $W/o.cdb "$@"
  if cmp -s $W/c.cdb $W/o.cdb; then echo "ok   $name ($(stat -c %s $W/o.cdb) bytes)"
  else echo "FAIL $name"; failures=$((failures + 1)); fi
  rm -f $W/c.cdb $W/o.cdb
}
shuffled() { python3 -c "import random; random.seed($1); l=list(range(1,$2+1)); random.shuffle(l); print(','.join(map(str,l)))"; }
sample() { python3 -c "import random; random.seed($1); print(','.join(map(str,random.sample(range(1,10000000),$2))))"; }
table_sql() { echo 'CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT);'; for k in ${1//,/ }; do echo "INSERT INTO t VALUES($k, \"name number $k padded to be longer\");"; done; }
index_sql() {
  echo 'CREATE TABLE t(id INTEGER PRIMARY KEY, v INTEGER);'
  i=0; for v in ${2//,/ }; do i=$((i + 1)); [ $i -eq $(($1 + 1)) ] && echo 'CREATE INDEX iv ON t(v);'; echo "INSERT INTO t VALUES($i, $v);"; done
}
for n in 1 20 21 32 200; do keys=$(seq -s, 1 $n); check "table, $n in order" "$(table_sql $keys)" table $keys; done
for seed in 1 2; do keys=$(shuffled $seed 3000); check "table, 3000 shuffled, seed $seed" "$(table_sql $keys)" table $keys; done
for m in 0 50 700; do vals=$(sample 1 2000); check "index after $m of 2000" "$(index_sql $m $vals)" index $m $vals; done
vals=$(sample 7 6000); check "index after 100 of 6000" "$(index_sql 100 $vals)" index 100 $vals
echo "$failures failure(s)"
[ $failures = 0 ]
