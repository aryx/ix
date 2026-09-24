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
# Phase 4: TinyGit's revision language against C git, on random
# histories built by git commit-tree (branches, merges of two or
# three parents, dates never decreasing from parent to child, as
# git9's walk by time assumes; equal dates in some sessions):
#
#   A B @        one of git merge-base --all A B
#   A..B         git rev-list B ^A, as a set; oldest first when the
#                dates are distinct
#   A~ A^^ ...   git rev-parse A~1, A~2 (a root's parent: the empty tree)
#   abbrev       the first 10 digits, HEAD, a branch name
#
# Usage: query.py [sessions] [seed]

import os, random, subprocess, sys, tempfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../..")
TG = os.path.join(ROOT, "_build/default/version_control/Main.exe")
sessions = int(sys.argv[1]) if len(sys.argv) > 1 else 30
seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
EMPTY = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
failures = 0

def git(d, *args, env=None, input=None):
    e = dict(os.environ); e.update(env or {})
    return subprocess.run(["git"] + list(args), cwd=d, env=e, input=input,
                          capture_output=True, text=True).stdout.split()

def tg(d, *args):
    p = subprocess.run([TG] + list(args), cwd=d, capture_output=True, text=True)
    return p.stdout.split(), p.returncode

def fail(n, what, got, want):
    global failures
    failures += 1
    print("FAIL session %d: %s\n  got:  %s\n  want: %s" % (n, what, got, want))

def session(n):
    r = random.Random(seed * 1000 + n)
    d = tempfile.mkdtemp()
    subprocess.run(["git", "init", "-q", d])
    commits, dates = [], {}
    distinct = r.random() < 0.5
    t = 1600000000
    for i in range(r.randint(3, 40)):
        k = 0 if not commits else (1 if r.random() < 0.75 or len(commits) < 2 else r.choice([2, 2, 3]))
        parents = r.sample(commits, min(k, len(commits))) if k else []
        # recent commits more likely, so branches grow
        if k == 1 and r.random() < 0.7: parents = [commits[-r.randint(1, min(3, len(commits)))]]
        t += r.randint(1, 1000) if distinct else r.choice([0, 0, 60])
        date = max([t] + [dates[p] for p in parents])
        env = {"GIT_AUTHOR_DATE": "%d +0000" % date, "GIT_COMMITTER_DATE": "%d +0000" % date,
               "GIT_AUTHOR_NAME": "a", "GIT_AUTHOR_EMAIL": "a@b", "GIT_COMMITTER_NAME": "a", "GIT_COMMITTER_EMAIL": "a@b"}
        args = ["commit-tree", EMPTY, "-m", "c%d" % i]
        for p in parents: args += ["-p", p]
        h = git(d, *args, env=env)[0]
        commits.append(h); dates[h] = date
    for i, c in enumerate(r.sample(commits, min(5, len(commits)))):
        git(d, "update-ref", "refs/heads/b%d" % i, c)
    git(d, "update-ref", "refs/heads/master", commits[-1])
    for _ in range(25):
        a, b = r.choice(commits), r.choice(commits)
        got, _ = tg(d, "query", a, b, "@")
        want = git(d, "merge-base", "--all", a, b)
        if not (got and got[0] in want and len(got) == 1) and not (not got and not want):
            fail(n, "%s %s @" % (a[:8], b[:8]), got, want)
        got, _ = tg(d, "query", "%s..%s" % (a, b))
        want = git(d, "rev-list", b, "^" + a)
        if distinct:
            want = sorted(want, key=lambda h: dates[h])
            if got != want: fail(n, "%s..%s" % (a[:8], b[:8]), got, want)
        elif sorted(got) != sorted(want):
            fail(n, "%s..%s (as sets)" % (a[:8], b[:8]), got, want)
        k = r.randint(1, 4)
        got, _ = tg(d, "query", a + "~" * k)
        w = git(d, "rev-parse", "--verify", "-q", a + "~%d" % k)
        if not w:
            w = git(d, "rev-parse", "--verify", "-q", a + "~%d" % (k - 1))
            w = [EMPTY] if w and k >= 1 and not git(d, "rev-parse", "-q", "--verify", w[0] + "^") else w
            # past the empty tree: git9 errors
            if k >= 2 and not git(d, "rev-parse", "--verify", "-q", a + "~%d" % (k - 1)): w = []
        if got != w: fail(n, "%s~%d" % (a[:8], k), got, w)
    for q, want in [(commits[-1][:10], [commits[-1]]), ("HEAD", [commits[-1]]), ("master", [commits[-1]]),
                    ("heads/b0", git(d, "rev-parse", "b0")), ("b0 b1", git(d, "rev-parse", "b0", "b1"))]:
        got, _ = tg(d, "query", *q.split())
        if got != want: fail(n, q, got, want)
    subprocess.run(["rm", "-rf", d])

for n in range(sessions):
    session(n)
print("query: %d sessions, %d failures" % (sessions, failures))
sys.exit(1 if failures else 0)
