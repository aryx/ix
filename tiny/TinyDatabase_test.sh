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
# The tests of TinyDatabase.ml, against SQLite (Python's sqlite3):
#
#  - random sessions: statements drawn at random (inserts, some with a
#    duplicate key, deletes, sets, queries with where, select, join,
#    group, sort, take), each written in the pipeline language for
#    tiny-db and in SQL for SQLite, the rows compared (as sets,
#    unless the query sorts), and each session's tables at the end;
#    enough rows in some for trees of three levels, an index on some;
#  - persistence: each statement run by a new process on the same file;
#  - crashes: a statement run on a copy, then the copy's header put
#    back as it was before, as if the machine stopped before the
#    commit's one write: the database must read as before the statement.
#
# Usage: TinyDatabase_test.sh [sessions] [seed]

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TD=${TD:-$ROOT/_build/default/tiny/TinyDatabase.exe}
exec python3 - "$TD" "${1:-40}" "${2:-1}" <<'EOF'
import os, random, shutil, sqlite3, subprocess, sys, tempfile

td, sessions, seed = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
failures = 0

def tiny(path, lines):
    p = subprocess.run([td, path], input="".join(l + "\n" for l in lines),
                       capture_output=True, text=True)
    return p.stdout.splitlines(), p.stderr

def rows_of(lines):
    return [tuple(l.split("|")) for l in lines]

def sql_rows(cur):
    return [tuple(str(v) for v in r) for r in cur.fetchall()]

OPS = ["=", "!=", "<", "<=", ">", ">="]
WORDS = ["ant", "bee", "cat", "dog", "eel", "fox"]

def cond(r, cols):
    """a where: its pipeline form, its SQL form"""
    parts = []
    for _ in range(r.randint(1, 3)):
        c = r.choice(cols)
        op = r.choice(OPS)
        if c == "b":
            v = '"%s"' % r.choice(WORDS)
        else:
            v = str(r.randint(-5, 3000 if c == "k" else 40))
        parts.append("%s %s %s" % (c, op, v) if r.random() < 0.8 else "%s %s %s" % (v, op, c))
    conn = r.choice([" and ", " or "]) if r.random() < 0.3 else " and "
    t = conn.join(parts)
    return t, t.replace("!=", "<>").replace('"', "'")

def query(r, has_u):
    """a random query: pipeline, SQL, whether its order is defined"""
    pipe, cols = ["t"], ["k", "a", "b"]
    frm, where, order, limit = "t", None, None, None
    if has_u and r.random() < 0.3:
        pipe.append("join u")
        frm = "t natural join u"
        cols = cols + ["c"]
    if r.random() < 0.8:
        pt, st = cond(r, cols)
        pipe.append("where " + pt)
        where = st
    kind = r.random()
    if kind < 0.3:
        agg = [("n", "count", "count(*)"), ("s", "sum a", "total(a)"),
               ("lo", "min a", "min(a)"), ("hi", "max k", "max(k)")]
        pipe.append("group b (%s)" % ", ".join("%s = %s" % (n, p) for n, p, _ in agg))
        sql = "select b, %s from %s%s group by b" % (
            ", ".join(s for _, _, s in agg), frm, " where " + where if where else "")
        # sum of nothing: never, a group has a row; total() is a float
        return pipe, sql, False, True
    sel = "*"
    ordered = False
    if r.random() < 0.4:
        c = r.choice(["a", "b"])
        desc = r.random() < 0.5
        # the key breaks ties, so the order is one
        pipe.append("sort %s%s, k" % (c, " desc" if desc else ""))
        order = "%s%s, k" % (c, " desc" if desc else "")
        ordered = True
        if r.random() < 0.5:
            limit = r.randint(0, 10)
            pipe.append("take %d" % limit)
    # last: each stage sees only the columns of the one before
    if kind < 0.6:
        pipe.append("select k, b, x = a * 2 - k / 3")
        sel = "k, b, a * 2 - k / 3"
    sql = "select %s from %s" % (sel, frm)
    if where: sql += " where " + where
    if order: sql += " order by " + order
    if limit is not None: sql += " limit %d" % limit
    return pipe, sql, ordered, False

def fix_total(rows, grouped):
    # SQLite's total() is a float: 12.0 -> 12
    if not grouped: return rows
    return [(r[0], r[1], str(int(float(r[2])))) + r[3:] for r in rows]

def session(n):
    global failures
    r = random.Random(seed * 1000 + n)
    d = tempfile.mkdtemp()
    path = os.path.join(d, "t.db")
    db = sqlite3.connect(":memory:")
    stmts = [("table t (k int key, a int, b text)", "create table t (k integer primary key, a int, b text)")]
    has_u = r.random() < 0.5
    if has_u:
        stmts.append(("table u (b text key, c int)", "create table u (b text primary key, c int)"))
        ws = r.sample(WORDS, 4)
        vals = ", ".join('("%s", %d)' % (w, r.randint(0, 9)) for w in ws)
        stmts.append(("insert u " + vals, "insert into u values " + vals.replace('"', "'")))
    indexed = r.random() < 0.6
    if indexed and r.random() < 0.5:
        stmts.append(("index t a", "create index ta on t(a)"))
    # one session in 8 big: 3,000 keys, a tree of three levels
    big = n % 8 == 0
    keys = list(range(3000 if big else 300))
    r.shuffle(keys)
    for i in range(r.randint(20, 45)):
        x = r.random()
        if x < 0.4:
            batch = [keys.pop() if keys and r.random() < 0.95 else r.randint(0, 299)
                     for _ in range(r.randint(1, 200 if big else 20))]
            vals = ", ".join('(%d, %d, "%s")' % (k, r.randint(0, 40), r.choice(WORDS)) for k in batch)
            stmts.append(("insert t " + vals, "insert into t values " + vals.replace('"', "'")))
        elif x < 0.47 and indexed:
            stmts.append(("index t b", "create index tb on t(b)") if not any(s[0] == "index t b" for s in stmts)
                         else ("index t a", "create index ta on t(a)"))
        elif x < 0.55:
            pt, st = cond(r, ["k", "a", "b"])
            stmts.append(("t | where %s | delete" % pt, "delete from t where " + st))
        elif x < 0.62:
            pt, st = cond(r, ["k", "a", "b"])
            stmts.append(('t | where %s | set a = a + 7, b = "set"' % pt,
                          "update t set a = a + 7, b = 'set' where " + st))
        else:
            pipe, sql, ordered, grouped = query(r, has_u)
            stmts.append((" | ".join(pipe), sql, ordered, grouped))
    stmts.append(("t", "select * from t", False, False))
    for s in stmts:
        # SQLite: the reference; an error (a duplicate key, an index that
        # exists) must be one in tiny-db too, and change nothing
        try:
            cur = db.execute(s[1])
            want, err = sql_rows(cur), False
            db.commit()
        except sqlite3.Error:
            db.rollback()
            want, err = [], True
        # the crash: the statement on a copy, then the old header back
        crash = os.path.join(d, "crash.db")
        if os.path.exists(path) and len(s) == 2:
            shutil.copy(path, crash)
            header = open(path, "rb").read(16)
            tiny(crash, [s[0]])
            with open(crash, "r+b") as f: f.write(header)
            before, _ = tiny(path, ["t"])
            after, e = tiny(crash, ["t"])
            if before != after or e:
                failures += 1
                print("FAIL crash, session %d: %s" % (n, s[0]))
        out, e = tiny(path, [s[0]])
        got = rows_of(out)
        if len(s) == 4:
            want = fix_total(want, s[3])
            if not s[2]: got, want = sorted(got), sorted(want)
        if got != want or bool(e) != err:
            failures += 1
            print("FAIL session %d: %s\n  sql: %s\n  got: %s\n  want: %s\n  stderr: %s"
                  % (n, s[0], s[1], got[:8], want[:8], e.strip() or (err and "(none; SQLite: an error)")))
            return
    shutil.rmtree(d)

for n in range(sessions):
    session(n)
print("TinyDatabase: %d sessions, %d failures" % (sessions, failures))
sys.exit(1 if failures else 0)
EOF
