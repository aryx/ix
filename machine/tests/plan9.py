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
# Phase 8: mini-5i's Plan 9 personality. Each Plan 9 a.out of the
# corpus (goken's hello_libc tests linked with GOOS=plan9 -H2, by
# linker/tests/libc.sh) is run three ways, in fresh directories, with
# the same arguments and standard input:
#
#   - under mini-5i;
#   - under goken's 5i, the twin (its own lines -- "5i", "exits(...)",
#     "stopped at ..." -- removed);
#   - the same C program's Linux build, on the CPU: the tests print the
#     same lines on every system, so it is the oracle where 5i lacks a
#     system call (10 of the 17).
#
# mini-5i must print what the Linux build prints and exit as it does
# (0, or nonzero for an exits string), but where Plan 9 means otherwise
# (DESIGN below); 5i's agreement is reported, not required.
#
# Usage: plan9.py plan9-dir linux-dir   (their g/*.exe)

import os, re, shutil, subprocess, sys, tempfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../..")
TA = os.path.join(ROOT, "_build/default/machine/Main.exe")
FIVEI = os.path.expanduser("~/goken/machines/5i/o.out")
P9, LINUX = sys.argv[1], sys.argv[2]
ARGS = ["one", "two"]
NATIVE = ["setarch", "-R"] if shutil.which("setarch") else []

# where the Linux build is no oracle for another reason: goken's own
# bugs, found here (the reason, and what mini-5i must then do)
GOKEN = {
    # goken's Plan 9 exits() is the raw system call, so atexit handlers
    # never run (real Plan 9's exits() runs them, then _exits); 5i and
    # mini-5i agree
    "atexit": ("goken's Plan 9 exits() is the system call: no atexit handlers", "5i"),
    # the Linux build fails natively, arm32 and arm64 alike, creating
    # directories with garbage names (mkdir("\7"), unlink("dirread_tmp_\1"):
    # strace); the test's own checks are the oracle
    "dirread": ("goken's Linux build fails natively (garbage path names)", "self"),
}

# where Plan 9's semantics are not Linux's, the Linux build's output
# is not the oracle: what Plan 9's kernel does instead (the reason, the
# output expected as a regular expression, the exit status expected)
DESIGN = {
    # exit(42) is exits("error") in Plan 9's libc (no exit codes), and
    # wait's message is the kernel's "name pid: error", not "42"
    "fork": ("exit codes are exit strings: wait's message is 'fork.exe PID: error'",
             r"wait reported wrong exit status: fork\.exe \d+: error\n", 1),
    # a note no handler accepts kills the process (noted(NDFLT)), where
    # Linux's postnote of an unknown note fails: after the two handled
    # notes, the third kills it, before its last line
    "notify": ("an unrecognized note kills the process, as noted(NDFLT) does", r"", 1),
}

def run(cmd):
    d = tempfile.mkdtemp()
    try:
        p = subprocess.run(cmd, cwd=d, input=b"a line\n", capture_output=True, timeout=30)
        return p.returncode, p.stdout.decode(errors="replace")
    except subprocess.TimeoutExpired:
        return "timeout", ""
    finally:
        shutil.rmtree(d, ignore_errors=True)

def fivei(prog):
    code, out = run(["bash", "-c", "printf ':c\\n$q\\n' | %s %s %s" % (FIVEI, prog, " ".join(ARGS))])
    lines = [l for l in out.splitlines(True) if l.strip() != "5i" and not re.match(r"(exits\(|stopped at |No system call|TODO )", l)]
    return "".join(lines)

failures = 0
agree5i = 0
progs = sorted(f for f in os.listdir(os.path.join(P9, "g")) if f.endswith(".exe"))
for f in progs:
    name = f[:-4]
    p9 = os.path.abspath(os.path.join(P9, "g", f))
    tiny = run([TA, p9] + ARGS)
    linux = run(NATIVE + [os.path.abspath(os.path.join(LINUX, "g", f))] + ARGS)
    five = fivei(p9) if os.path.exists(FIVEI) else None
    same = tiny[1] == linux[1] and (tiny[0] == 0) == (linux[0] == 0)
    if five is not None and five == tiny[1]: agree5i += 1
    tag = "5i agrees" if five == tiny[1] else "5i differs"
    if same:
        print("ok %s (%s)" % (name, tag))
    elif name in GOKEN:
        why, oracle = GOKEN[name]
        good = (five == tiny[1]) if oracle == "5i" else (tiny[0] == 0 and tiny[1].strip().endswith("ok"))
        if good: print("ok %s: %s; %s (%s)" % (name, why, "as 5i" if oracle == "5i" else "its own checks pass", tag))
        else:
            failures += 1
            print("FAIL %s: %s, and mini-5i: %s" % (name, why, tiny[1].strip()))
    elif name in DESIGN:
        why, want, status = DESIGN[name]
        if re.fullmatch(want, tiny[1]) and tiny[0] == status:
            print("ok %s: as Plan 9, not Linux: %s (%s)" % (name, why, tag))
        else:
            failures += 1
            print("FAIL %s: %s expected; mini-5i: status %s, %r" % (name, why, tiny[0], tiny[1]))
    else:
        failures += 1
        print("FAIL %s: status mini-5i %s, linux %s (%s)" % (name, tiny[0], linux[0], tag))
        print("    mini-5i: " + tiny[1].strip().replace("\n", "\n             "))
        print("    linux:   " + linux[1].strip().replace("\n", "\n             "))
print("plan9: %d programs, %d failures; 5i agrees with mini-5i on %d" % (len(progs), failures, agree5i))
sys.exit(1 if failures else 0)
