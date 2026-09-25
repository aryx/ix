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
# Phase 6: mini-diff against principia's own diff and merge3, built for
# Linux by goken (build_plan9_diff.sh). Random files -- few distinct
# lines, so that the longest common subsequence has choices; runs
# inserted, deleted, changed; a last line without its newline; blanks
# for -b and -w; now and then a NUL, for the binary check -- through
# every format (default, -e -f -n -c -a -u), -m, and directory trees
# with and without -r; stdout and the exit status compared. And three
# files through merge3: the base, and two sides edited from it.
#
# Usage: diff_fuzz.py [count] [seed]

import os, random, shutil, subprocess, sys, tempfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../..")
TD = os.path.join(ROOT, "_build/default/version_control/Diffmain.exe")
TM = os.path.join(ROOT, "_build/default/version_control/Merge3main.exe")
REF = os.environ.get("P9DIFF", "/tmp/ix-p9diff")
subprocess.run([os.path.join(os.path.dirname(os.path.abspath(__file__)), "build_plan9_diff.sh"), REF], check=True)
count = int(sys.argv[1]) if len(sys.argv) > 1 else 300
r = random.Random(int(sys.argv[2]) if len(sys.argv) > 2 else 1)
failures = 0
WORDS = ["a", "b", "c", "if (x)", "}", "", "  indented", "tab\there", "a  b", "x y ", "return 0;"]

def lines(n):
    return [r.choice(WORDS) for _ in range(n)]

def edit(ls):
    ls = list(ls)
    for _ in range(r.randint(0, 5)):
        k = r.random()
        i = r.randint(0, len(ls))
        if k < 0.35: ls[i:i] = lines(r.randint(1, 4))
        elif k < 0.7: del ls[i:i + r.randint(1, 4)]
        else: ls[i:i + r.randint(1, 3)] = lines(r.randint(1, 3))
        if r.random() < 0.1:
            ls = [l.replace(" ", "  ") if r.random() < 0.5 else l for l in ls]
    return ls

def text(ls):
    s = "".join(l + "\n" for l in ls)
    if s and r.random() < 0.15: s = s[:-1]
    if r.random() < 0.02: s = s[:5] + "\0" + s[5:]
    return s

def run(cmd, cwd):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True)
    return p.stdout, (0 if p.returncode == 0 else 1)

def check(what, a, b, d):
    global failures
    if a != b:
        failures += 1
        print("FAIL %s (kept in %s)\n  C: %r\n  tiny: %r" % (what, d, a[0][:300], b[0][:300]))
        return False
    return True

for n in range(count):
    d = tempfile.mkdtemp()
    base = lines(r.randint(0, 25))
    kind = r.random()
    ok = True
    if kind < 0.6:
        open(os.path.join(d, "old"), "w").write(text(base))
        open(os.path.join(d, "new"), "w").write(text(edit(base)))
        flags = [f for f in [r.choice(["", "-e", "-f", "-n", "-c", "-a", "-u"]), r.choice(["", "", "-b", "-w"]), r.choice(["", "", "-m"])] if f]
        ok = check("diff %s (case %d)" % (" ".join(flags), n), run([os.path.join(REF, "pdiff")] + flags + ["old", "new"], d), run([TD] + flags + ["old", "new"], d), d)
    elif kind < 0.75:
        # directories: common files, one side's, subdirectories
        for side in ("A", "B"):
            os.makedirs(os.path.join(d, side, "sub"))
        for f in ["x", "y", "sub/z"]:
            ls = lines(r.randint(0, 8))
            if r.random() < 0.85: open(os.path.join(d, "A", f), "w").write(text(ls))
            if r.random() < 0.85: open(os.path.join(d, "B", f), "w").write(text(edit(ls)))
        flags = [f for f in [r.choice(["", "-n", "-u", "-e"]), r.choice(["", "-r"])] if f]
        ok = check("diff %s A B (case %d)" % (" ".join(flags), n), run([os.path.join(REF, "pdiff")] + flags + ["A", "B"], d), run([TD] + flags + ["A", "B"], d), d)
    else:
        open(os.path.join(d, "base"), "w").write(text(base).replace("\0", ""))
        open(os.path.join(d, "ours"), "w").write(text(edit(base)).replace("\0", ""))
        open(os.path.join(d, "theirs"), "w").write(text(edit(base)).replace("\0", ""))
        ok = check("merge3 (case %d)" % n, run([os.path.join(REF, "pmerge3"), "ours", "base", "theirs"], d), run([TM, "ours", "base", "theirs"], d), d)
    if ok: shutil.rmtree(d)
print("diff_fuzz: %d cases, %d failures" % (count, failures))
sys.exit(1 if failures else 0)
