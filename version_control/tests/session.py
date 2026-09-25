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
# Phase 5: the same random work through mini-git and through C git, in
# two work trees: files written, appended to, deleted, made executable,
# a file turned into a directory and back, directories emptied;
# commits (same author, date, message), branches made and switched.
# After each commit, both HEADs must be the same hash; after each
# switch, both work trees the same files and x bits; at the end,
# git fsck --strict on mini-git's repository and git log reading it.
#
# Usage: session.py [sessions] [seed] [session to trace]

import os, random, shutil, stat, subprocess, sys, tempfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../..")
TG = os.path.join(ROOT, "_build/default/version_control/Main.exe")
sessions = int(sys.argv[1]) if len(sys.argv) > 1 else 20
seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
failures = 0

NAMES = ["a", "b", "c.txt", "d", "e.ml", "sub"]
WORDS = ["alpha", "beta", "gamma", "delta", "x", "", "  trailing  "]

class Failed(Exception): pass

def env(date):
    e = dict(os.environ)
    e.update({"GIT_AUTHOR_DATE": "%d +0000" % date, "GIT_COMMITTER_DATE": "%d +0000" % date,
              "GIT_AUTHOR_NAME": "Glenda", "GIT_AUTHOR_EMAIL": "glenda@9front.org",
              "GIT_COMMITTER_NAME": "Glenda", "GIT_COMMITTER_EMAIL": "glenda@9front.org"})
    return e

trace = []

def run(cmd, cwd, date=1600000000):
    p = subprocess.run(cmd, cwd=cwd, env=env(date), capture_output=True, text=True)
    if TG in cmd[0]: trace.append("mini-git %s -> %d %s" % (" ".join(repr(a) for a in cmd[1:]), p.returncode, (p.stdout + p.stderr).strip().replace("\n", " / ")))
    return p

def snapshot(d):
    out = {}
    for dp, dns, fns in os.walk(d):
        if ".git" in dns: dns.remove(".git")
        for f in fns:
            p = os.path.join(dp, f)
            out[os.path.relpath(p, d)] = (open(p, "rb").read(), os.stat(p).st_mode & 0o100)
    return out

def rmrf(p):
    if os.path.isdir(p) and not os.path.islink(p): shutil.rmtree(p)
    elif os.path.exists(p): os.remove(p)

def session(n):
    r = random.Random(seed * 1000 + n)
    trace.clear()
    top = tempfile.mkdtemp()
    A, B = os.path.join(top, "tiny"), os.path.join(top, "git")
    os.mkdir(A); os.mkdir(B)
    run([TG, "init"], A)
    with open(os.path.join(A, ".git/config"), "a") as f:
        f.write("[user]\n\tname = Glenda\n\temail = glenda@9front.org\n")
    run(["git", "init", "-q", "-b", "master"], B)
    date = 1600000000
    branches = ["master"]
    current = "master"
    def both(fn):
        fn(A); fn(B)
    def paths():
        return sorted(snapshot(A).keys())
    try:
        for step in range(r.randint(10, 40)):
            k = r.random()
            if k < 0.35:
                # write a file, maybe in a directory
                p = r.choice(NAMES) if r.random() < 0.6 else r.choice(NAMES) + "/" + r.choice(NAMES)
                text = "\n".join(r.choice(WORDS) for _ in range(r.randint(0, 6))) + ("\n" if r.random() < 0.8 else "")
                def w(d):
                    full = os.path.join(d, p)
                    # a file where a directory is wanted, or the reverse
                    for q in [os.path.dirname(full)]:
                        if os.path.isfile(q): os.remove(q)
                    if os.path.isdir(full): shutil.rmtree(full)
                    os.makedirs(os.path.dirname(full), exist_ok=True)
                    with open(full, "a" if r2 < 0.3 else "w") as f: f.write(text)
                r2 = r.random()
                new = p not in paths()
                both(w)
                trace.append("write %s%s" % (p, " (append)" if r2 < 0.3 else ""))
                if new or True:
                    run([TG, "add", p], A)
            elif k < 0.45 and paths():
                p = r.choice(paths())
                both(lambda d: os.remove(os.path.join(d, p)))
                trace.append("rm %s" % p)
                for d in (A, B):
                    parent = os.path.dirname(os.path.join(d, p))
                    if parent != d and not os.listdir(parent): os.rmdir(parent)
            elif k < 0.52 and paths():
                p = r.choice(paths())
                bit = r.choice([0o755, 0o644])
                both(lambda d: os.chmod(os.path.join(d, p), bit))
                trace.append("chmod %o %s" % (bit, p))
            elif k < 0.8:
                date += r.randint(1, 100000)
                msg = r.choice(["fix", "add a feature", "two\n\nparagraphs", "  indented", "trailing  \n\n\n"])
                ta = run([TG, "commit", "-m", msg, "."], A, date)
                run(["git", "add", "-A"], B)
                tb = run(["git", "commit", "-q", "-m", msg], B, date)
                ha = run([TG, "query", "HEAD"], A).stdout.strip()
                hb = run(["git", "rev-parse", "-q", "--verify", "HEAD"], B).stdout.strip()
                if (ta.returncode == 0) != (tb.returncode == 0) or ha != hb:
                    raise Failed("commit %r: mini-git %s (%s %s), git %s (%s)" % (msg, ha, ta.returncode, (ta.stderr + ta.stdout).strip(), hb, tb.returncode))
            else:
                # a branch: new, or switch to one, with a clean tree
                if run([TG, "walk", "-q"], A).returncode != 0 or run(["git", "rev-parse", "HEAD"], B).returncode != 0:
                    continue
                if r.random() < 0.4 or len(branches) == 1:
                    b = "br%d" % len(branches)
                    branches.append(b)
                    ta = run([TG, "branch", "-n", b], A)
                    tb = run(["git", "checkout", "-q", "-b", b], B)
                else:
                    b = r.choice(branches)
                    ta = run([TG, "branch", b], A)
                    tb = run(["git", "checkout", "-q", b], B)
                if ta.returncode != 0 or tb.returncode != 0:
                    raise Failed("branch %s: %s / %s" % (b, ta.stderr.strip(), tb.stderr.strip()))
                current = b
                if snapshot(A) != snapshot(B):
                    sa, sb = snapshot(A), snapshot(B)
                    diff = sorted(set(k for k in set(sa) | set(sb) if sa.get(k) != sb.get(k)))
                    raise Failed("after branch %s, trees differ: %s" % (b, diff))
        f = run(["git", "fsck", "--strict"], A)
        if f.returncode != 0 or f.stdout.strip():
            raise Failed("fsck: %s %s" % (f.stdout, f.stderr))
    except Failed as e:
        global failures
        failures += 1
        print("FAIL session %d: %s  (kept in %s)" % (n, e, top))
        if os.environ.get("TRACE"): print("\n".join("  " + t for t in trace))
        return
    shutil.rmtree(top)

# a third argument: that session only, traced
only = int(sys.argv[3]) if len(sys.argv) > 3 else None
if only is not None: os.environ["TRACE"] = "1"
for n in ([only] if only is not None else range(sessions)):
    session(n)
print("session: %d sessions, %d failures" % (sessions, failures))
sys.exit(1 if failures else 0)
