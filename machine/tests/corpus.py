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
# Phases 2 and 3: each program of the corpus run on the CPU (this
# machine runs arm32 and arm64 natively) and under mini-5i, in fresh
# directories, with the same arguments and standard input: standard
# output, the exit status, and the sequence of system calls (strace on
# the native run, mini-5i's -y log; the main process's) compared.
#
# Usage: corpus.py 5|7 program...

import os, re, shutil, subprocess, sys, tempfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../..")
TA = os.path.join(ROOT, "_build/default/machine/Main.exe")
arch, progs = sys.argv[1], sys.argv[2:]
failures = 0
ARGS = ["one", "two"]
# the native runs without address randomization: mini-5i's layout is
# fixed, and goken's brk takes any answer at or above its request as
# success, so under a randomized heap mem.exe uses memory it never got
# (it segfaults on arm64; on arm32 it happens to stay in its last page)
NATIVE = ["setarch", "-R"] if shutil.which("setarch") else []
# the system calls' names, from the kernel's header for the guest
HEADER = {"5": "/usr/arm-linux-gnueabihf/include/asm/unistd-eabi.h",
          "7": "/usr/aarch64-linux-gnu/include/asm-generic/unistd.h"}[arch]
NAMES = {}
if os.path.exists(HEADER):
    for line in open(HEADER):
        m = re.match(r"#define __NR_(\w+)\s+\(?(?:__NR_SYSCALL_BASE\s*\+\s*)?(\d+)\)?", line)
        if m: NAMES[int(m.group(2))] = m.group(1)

def native_calls(p, d):
    out = os.path.join(d, ".strace")
    subprocess.run(NATIVE + ["strace", "-qq", "-o", out, p] + ARGS, cwd=d, input=b"a line\n", capture_output=True, timeout=30)
    calls = []
    for line in open(out):
        m = re.match(r"(\w+)\(", line)
        if m: calls.append(m.group(1))
    os.remove(out)
    return calls[1:] if calls and calls[0] == "execve" else calls

def tiny_calls(p, d):
    q = subprocess.run([TA, "-y", p] + ARGS, cwd=d, input=b"a line\n", capture_output=True, timeout=30)
    lines = [l for l in q.stderr.decode(errors="replace").splitlines() if l.startswith("[")]
    if not lines: return []
    main = lines[0].split("]")[0]
    return [NAMES.get(int(re.match(r"\[\d+\] (\d+)\(", l).group(1)), "?") for l in lines if l.startswith(main + "]")]

def run(cmd):
    d = tempfile.mkdtemp()
    try:
        p = subprocess.run(cmd, cwd=d, input=b"a line\n", capture_output=True, timeout=30)
        return p.stdout, p.returncode, p.stderr
    except subprocess.TimeoutExpired:
        return b"", "timeout", b""
    finally:
        shutil.rmtree(d, ignore_errors=True)

for p in progs:
    name = os.path.basename(os.path.dirname(p)) + "/" + os.path.basename(p)
    want = run(NATIVE + [p] + ARGS)
    got = run([TA, p] + ARGS)
    if (want[0], want[1]) != (got[0], got[1]):
        failures += 1
        err = got[2].decode(errors="replace").strip().splitlines()
        print("FAIL %s: status native %s, mini-5i %s%s\n    %s" % (name, want[1], got[1],
              "" if want[0] == got[0] else ", stdout differs", err[-1] if err else ""))
    else:
        d1, d2 = tempfile.mkdtemp(), tempfile.mkdtemp()
        a, b = native_calls(p, d1), tiny_calls(p, d2)
        shutil.rmtree(d1, ignore_errors=True); shutil.rmtree(d2, ignore_errors=True)
        if NAMES and a != b:
            failures += 1
            i = next((k for k in range(min(len(a), len(b))) if a[k] != b[k]), min(len(a), len(b)))
            print("FAIL %s: system calls differ at %d: native %s, mini-5i %s" % (name, i, a[i:i+3], b[i:i+3]))
        else:
            print("ok %s (%d system calls)" % (name, len(a)))
print("corpus: %d programs, %d failures" % (len(progs), failures))
sys.exit(1 if failures else 0)
