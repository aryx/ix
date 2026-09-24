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
# The tests of TinyVCS.ml: its laws, on random work.
#
#  - diff: random pairs of files (few distinct lines, a last line
#    without its newline at times); GNU patch applied to the old file
#    with tinyvcs's diff gives the new one;
#  - switch: random commits on random branches; switching to a branch
#    gives back exactly the files (and x bits) it had when committed;
#  - merge: two branches editing different files, and different ends
#    of one file; merged both ways, the same files, both edits in,
#    no conflict; edits of the same line: a conflict, committed, shown
#    by status, resolved by editing;
#  - undo: after any command, undo gives back the branches before it;
#    a crash before head's rename (the old head put back) leaves the
#    repository as it was;
#  - clone, pull, push: the same log on both sides.
#
# Usage: TinyVCS_test.sh [rounds] [seed]

ROOT=$(cd "$(dirname "$0")/.." && pwd)
V=${V:-$ROOT/_build/default/tiny/TinyVCS.exe}
exec python3 - "$V" "${1:-20}" "${2:-1}" <<'EOF'
import os, random, shutil, subprocess, sys, tempfile

V, rounds, seed = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
r = random.Random(seed)
failures = 0
WORDS = ["a", "b", "c", "let x = 1", "}", "", "  y"]

def fail(what):
    global failures
    failures += 1
    print("FAIL", what)

def tv(d, *args, ok=True):
    p = subprocess.run([V] + list(args), cwd=d, capture_output=True, text=True,
                       env=dict(os.environ, TINYVCS_AUTHOR="glenda", TINYVCS_DATE=str(1600000000 + r.randrange(10**6))))
    if ok and p.returncode != 0:
        raise RuntimeError("tinyvcs %s: %s" % (" ".join(args), p.stderr.strip()))
    return p.stdout

def text(n):
    s = "".join(r.choice(WORDS) + "\n" for _ in range(n))
    return s[:-1] if s and r.random() < 0.2 else s

def edit(s):
    ls = s.split("\n")
    for _ in range(r.randint(1, 4)):
        i = r.randint(0, len(ls))
        k = r.random()
        if k < 0.4: ls[i:i] = [r.choice(WORDS) for _ in range(r.randint(1, 3))]
        elif k < 0.7: del ls[i:i + r.randint(1, 3)]
        else: ls[i:i + 1] = [r.choice(WORDS)]
    return "\n".join(ls)

def snapshot(d):
    out = {}
    for dp, dns, fns in os.walk(d):
        dns[:] = [x for x in dns if not x.startswith(".")]
        for f in fns:
            p = os.path.join(dp, f)
            out[os.path.relpath(p, d)] = (open(p, "rb").read(), os.stat(p).st_mode & 0o100)
    return out

def write(d, path, s, x=False):
    p = os.path.join(d, path)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w").write(s)
    os.chmod(p, 0o755 if x else 0o644)

top = tempfile.mkdtemp()
try:
    # diff against GNU patch
    d = os.path.join(top, "diff"); os.mkdir(d); tv(d, "init")
    for n in range(rounds * 5):
        old = {"f%d" % i: text(r.randint(0, 12)) for i in range(4)}
        for f, s in old.items(): write(d, f, s)
        tv(d, "commit", "-m", "old %d" % n, ok=False)
        new = {f: edit(s) for f, s in old.items()}
        for f, s in new.items(): write(d, f, s)
        patch = tv(d, "diff")
        work = os.path.join(top, "patchwork"); shutil.rmtree(work, ignore_errors=True); os.mkdir(work)
        for f, s in old.items(): open(os.path.join(work, f), "w").write(s)
        p = subprocess.run(["patch", "-s", "-p1", "-d", work], input=patch, capture_output=True, text=True)
        got = {f: open(os.path.join(work, f)).read() for f in old}
        if p.returncode != 0 or got != new:
            fail("diff %d: patch %s\n%s" % (n, p.stdout + p.stderr, patch[:500])); break
    else:
        print("ok diff: %d rounds through GNU patch" % (rounds * 5))

    # switch restores; undo restores
    d = os.path.join(top, "switch"); os.mkdir(d); tv(d, "init")
    tips = {}
    branches = ["master"]
    cur = "master"
    bad = False
    for n in range(rounds * 3):
        k = r.random()
        if k < 0.5:
            for _ in range(r.randint(1, 3)):
                path = r.choice(["a", "b.txt", "d/e", "d/f.ml", "g/h/i"])
                if r.random() < 0.2 and os.path.exists(os.path.join(d, path)): os.remove(os.path.join(d, path))
                else:
                    if os.path.isfile(os.path.join(d, os.path.dirname(path))): continue
                    write(d, path, text(r.randint(0, 6)), r.random() < 0.2)
            p = subprocess.run([V, "commit", "-m", "c%d" % n], cwd=d, capture_output=True, text=True)
            if p.returncode == 0: tips[cur] = snapshot(d)
        elif k < 0.7 and cur in tips:
            b = "b%d" % n; tv(d, "branch", b); tv(d, "switch", b); branches.append(b); tips[b] = tips[cur]; cur = b
        elif k < 0.9 and tips:
            b = r.choice([b for b in branches if b in tips])
            before = tv(d, "branch")
            tv(d, "switch", b); cur = b
            if snapshot(d) != tips[b]:
                fail("switch %s: the tree differs from its commit's" % b); bad = True; break
        elif tips:
            before = tv(d, "branch")
            tv(d, "branch", "tmp%d" % n)
            tv(d, "undo")
            if tv(d, "branch") != before:
                fail("undo: branches differ"); bad = True; break
    if not bad: print("ok switch and undo: %d steps" % (rounds * 3))

    # merges
    bad = False
    for n in range(rounds):
        d = os.path.join(top, "merge%d" % n); os.mkdir(d); tv(d, "init")
        long = "".join("line %d\n" % i for i in range(30))
        write(d, "shared", long); write(d, "a", "a\n"); write(d, "b", "b\n")
        tv(d, "commit", "-m", "base")
        tv(d, "branch", "other")
        # ours: file a, the top of shared; theirs: file b, the bottom
        write(d, "a", "a changed\n"); write(d, "shared", long.replace("line 1\n", "line one\n"))
        if r.random() < 0.5: write(d, "new_ours", "n\n", True)
        tv(d, "commit", "-m", "ours")
        tv(d, "switch", "other")
        write(d, "b", "b changed\n"); write(d, "shared", long.replace("line 28\n", "line twenty-eight\n"))
        tv(d, "commit", "-m", "theirs")
        # merge both ways, in two clones
        e = os.path.join(top, "mergeclone%d" % n)
        tv(top, "clone", d, e)
        out1 = tv(d, "merge", "master")
        tv(e, "switch", "master"); out2 = tv(e, "merge", "other")
        s1, s2 = snapshot(d), snapshot(e)
        want = long.replace("line 1\n", "line one\n").replace("line 28\n", "line twenty-eight\n")
        if "conflict" in out1 + out2 or s1 != s2 or s1["shared"][0].decode() != want or s1["a"][0] != b"a changed\n" or s1["b"][0] != b"b changed\n":
            fail("merge %d: %s %s" % (n, out1, out2)); bad = True; break
        # a real conflict: one line changed on both sides of a clone
        x = os.path.join(top, "cx%d" % n); os.mkdir(x); tv(x, "init")
        write(x, "a", "one\ntwo\nthree\n"); tv(x, "commit", "-m", "base")
        y = os.path.join(top, "cy%d" % n); tv(top, "clone", x, y)
        write(x, "a", "one\nmine\nthree\n"); tv(x, "commit", "-m", "mine")
        write(y, "a", "one\nyours\nthree\n"); tv(y, "commit", "-m", "yours")
        d = x
        out = tv(d, "pull", y)
        if "diverged" not in out: fail("pull: not diverged: %s" % out); bad = True; break
        out = tv(d, "merge", "pulled/master")
        st = tv(d, "status")
        if "conflict: a" not in out or "C a" not in st or "<<<<<<<" not in open(os.path.join(d, "a")).read():
            fail("conflict: %s / %s" % (out, st)); bad = True; break
        write(d, "a", "resolved\n"); tv(d, "commit", "-m", "resolved")
        if "C a" in tv(d, "status"): fail("conflict not resolved"); bad = True; break
    if not bad: print("ok merge: %d rounds, both ways, and a conflict" % rounds)

    # crash before the rename: the old head back
    d = os.path.join(top, "switch")
    head = open(os.path.join(d, ".tvcs/head")).read()
    log = tv(d, "log")
    write(d, "crash", "x\n"); tv(d, "commit", "-m", "lost")
    open(os.path.join(d, ".tvcs/head"), "w").write(head)
    os.remove(os.path.join(d, "crash"))
    if tv(d, "log") != log or tv(d, "status") != "": fail("crash: the old state is not whole")
    else: print("ok crash before the head's rename")

    # clone, push, pull: the same log
    a = os.path.join(top, "switch"); b = os.path.join(top, "cloned")
    tv(top, "clone", a, b)
    write(b, "pushed", "p\n"); tv(b, "commit", "-m", "to push"); tv(b, "push", a)
    c = os.path.join(top, "third"); tv(top, "clone", a, c)
    write(b, "pulled", "q\n"); tv(b, "commit", "-m", "to pull"); tv(b, "push", a)
    tv(c, "pull", a)
    if not (tv(a, "log") == tv(b, "log") == tv(c, "log")): fail("clone/push/pull: logs differ")
    else: print("ok clone, push, pull")
finally:
    shutil.rmtree(top)
print("TinyVCS: %d failures" % failures)
sys.exit(1 if failures else 0)
EOF
