#!/usr/bin/env python3
# Claude Code
#
# Copyright (C) 2026 Yoann Padioleau
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Library General Public License
# (LGPL) as published by the Free Software Foundation; either version
# 2 of the License, or (at your option) any later version.
#
# fuzz.py [SEED] [COUNT]: random sessions run by chidb and by mini-chidb,
# their stdout, stderr and database files compared. A session: two
# tables of random integer and text columns, rows enough to split pages
# and roots, indexes made before or after the rows, and queries of every
# shape chidb compiles (scans, seeks, ranges, joins, EXPLAIN), with
# some it refuses. A failing session is kept under /tmp/mini-chidb-fuzz-SEED-N.
import os, random, shutil, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TDB = os.environ.get("TDB", os.path.join(ROOT, "_build/default/database/Main.exe"))
CHIDB = os.environ.get("CHIDB", os.path.expanduser("~/github/chidb/chidb"))

def session(r):
    lines = []
    names = ["alpha", "beta", "gamma", "delta", "eps", "zeta", "eta", "theta"]
    words = ["a", "b", "ab", "zz", "hello", "world", "x" * 30, "tiny", "database", "q"]
    tables = []
    shared = "k"
    # a name has one type in the session: a natural join of a text
    # column with an integer one crashes chidb (strcmp on an integer)
    types = {n: r.choice(["INTEGER", "TEXT"]) for n in names}
    for t in ["t", "u"]:
        cols = [("id", "INTEGER")]
        for c in r.sample(names, r.randint(1, 4)):
            cols.append((c, types[c]))
        if r.random() < 0.7:
            cols.insert(r.randint(1, len(cols)), (shared, "INTEGER"))
        tables.append((t, cols))
        decl = ", ".join(f"{n} {ty}" + (" PRIMARY KEY" if n == "id" else "") for n, ty in cols)
        lines.append(f"CREATE TABLE {t}({decl});")
    def value(ty):
        if ty == "INTEGER":
            return str(r.choice([r.randint(-5, 50), r.randint(0, 1000000), r.randint(-2**31, 2**31 - 1)]))
        w = r.choice(words) + (str(r.randint(0, 99)) if r.random() < 0.5 else "")
        return f"'{w}'" if r.random() < 0.5 else f'"{w}"'
    def ints(cols):
        return [n for n, ty in cols if ty == "INTEGER"]
    def insert(t, cols, pk):
        vals = [str(pk) if n == "id" else (str(r.randint(0, 6)) if n == shared else value(ty)) for n, ty in cols]
        lines.append(f"INSERT INTO {t} VALUES({', '.join(vals)});")
    indexed = []
    for t, cols in tables:
        n = r.choice([3, 20, 60, r.randint(0, 400)])
        keys = r.sample(range(1, 5 * n + 10), n)
        early = r.random() < 0.5
        idx_cols = r.sample(ints(cols), min(len(ints(cols)), r.randint(0, 2)))
        if early:
            for c in idx_cols:
                lines.append(f"CREATE INDEX i{t}{c} ON {t}({c});")
        for k in keys:
            insert(t, cols, k)
        if r.random() < 0.3:
            insert(t, cols, r.choice(keys))       # a duplicate key
        if not early:
            for c in idx_cols:
                lines.append(f"CREATE INDEX i{t}{c} ON {t}({c});")
        indexed += [(t, c) for c in idx_cols]
    ops = ["=", "<", ">", "<=", ">="]
    def cond(t, cols, qualify=False):
        n, ty = r.choice(cols)
        v = value(ty) if r.random() < 0.9 else value("TEXT" if ty == "INTEGER" else "INTEGER")
        col = f"{t}.{n}" if qualify else n
        op = r.choice(ops)
        return f"{v} {op} {col}" if r.random() < 0.2 else f"{col} {op} {v}"
    def where(t, cols, qualify=False):
        k = r.choice([0, 1, 1, 2, 2, 3])
        if k == 2 and ints(cols) and r.random() < 0.5:
            c = r.choice(ints(cols))
            a, b = sorted([r.randint(-10, 60), r.randint(-10, 60)])
            c = f"{t}.{c}" if qualify else c
            return [f"{c} {r.choice(['>', '>='])} {a}", f"{c} {r.choice(['<', '<='])} {b}"][:: r.choice([1, -1])]
        return [cond(t, cols, qualify) for _ in range(k)]
    for _ in range(r.randint(5, 25)):
        explain = "EXPLAIN " if r.random() < 0.25 else ""
        if r.random() < 0.6:
            t, cols = r.choice(tables)
            proj = "*" if r.random() < 0.3 else ", ".join(r.sample([n for n, _ in cols], r.randint(1, len(cols))))
            w = where(t, cols)
            q = f"SELECT {proj} FROM {t}" + (" WHERE " + " AND ".join(w) if w else "")
        else:
            (t1, c1), (t2, c2) = tables if r.random() < 0.5 else tables[::-1]
            all_cols = [f"{t1}.{n}" for n, _ in c1] + [f"{t2}.{n}" for n, _ in c2]
            proj = "*" if r.random() < 0.4 else ", ".join(r.sample(all_cols, r.randint(1, min(4, len(all_cols)))))
            w = where(t1, c1, True) + where(t2, c2, True)
            r.shuffle(w)
            q = f"SELECT {proj} FROM {t1} NATURAL JOIN {t2}" + (" WHERE " + " AND ".join(w) if w else "")
        if explain and r.random() < 0.5:
            lines.append(".explain on")
            lines.append(explain + q + ";")
            lines.append(".explain off")
        else:
            lines.append(explain + q + ";")
        if r.random() < 0.1:
            lines.append(f".opt \"{q};\"")
    return "\n".join(lines) + "\n"

def run(prog, script, d):
    os.makedirs(d)
    with open(os.path.join(d, "s.sql"), "w") as f:
        f.write(script)
    p = subprocess.run([prog, "db.cdb"], cwd=d, input=script.encode(), capture_output=True, timeout=120)
    with open(os.path.join(d, "db.cdb"), "rb") as f:
        return p.stdout, p.stderr, f.read()

def main():
    seed = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 50
    r = random.Random(seed)
    stats = {"same": 0, "diff": 0}
    for i in range(count):
        script = session(r)
        w = tempfile.mkdtemp()
        c = run(CHIDB, script, os.path.join(w, "c"))
        t = run(TDB, script, os.path.join(w, "t"))
        if c == t:
            stats["same"] += 1
            shutil.rmtree(w)
        else:
            stats["diff"] += 1
            keep = f"/tmp/mini-chidb-fuzz-{seed}-{i}"
            shutil.rmtree(keep, ignore_errors=True)
            shutil.move(w, keep)
            what = [n for n, a, b in zip(["stdout", "stderr", "file"], c, t) if a != b]
            print(f"DIFF session {i} ({', '.join(what)}): {keep}")
    print(stats)
    return 1 if stats["diff"] else 0

sys.exit(main())
