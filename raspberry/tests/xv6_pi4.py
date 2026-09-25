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
# mini-qemu against QEMU on xv6 arm64-pi4, fast (plan_pi.md, phase G4):
# the boot, then usertests' tests one by one, the console's output
# under mini-qemu (one core) byte for byte QEMU's (raspi4b, its four
# cores; its other cores' "hart N starting" dropped).
#
# The test's constant lowered: xv6's kernel uses the RAM up to PHYSTOP,
# 128MB, and the cost of both its boot (kinit fills every page, a byte
# at a time) and of each usertests run (countfree allocates every free
# page, then frees it: three byte loops a page) grows with it: 21s and
# 70s under mini-qemu's 27 MIPS. So the kernel tested is a copy with
# PHYSTOP at 4MB (2.3MB free, 590 pages): booted in 1.4s, a test in
# about 4s. The copy is built here, in a mirror of ~/xv6 (symbolic
# links, arm64-pi4 copied, its memlayout.h edited): ~/xv6 itself is
# untouched.
#
# The tests: the default set covers what the kernel's paths are made of
# (faults and page tables, copies between user and kernel, sbrk, exec,
# files and directories, pipes, the timer's preemption, fork) in about a
# minute; -a runs every test that passes on 4MB and takes under a
# minute here (those left out: sbrkmuch wants 100MB; manywrites,
# execout, reparent2, badarg, reparent, twochildren, forkfork and
# concreate take minutes under mini-qemu, 2s to 18s under QEMU; the
# full usertests on the real kernel is xv6.sh -u's). Timings measured
# 2026-09-25 (docs/plans/plan_pi.md, phase G's status).
#
# Needs ~/xv6 (its arm64-pi4 port built once, for its tools), the
# aarch64-linux-gnu toolchain, and a qemu-system-aarch64 with raspi4b
# ($QEMU64; without one, the outputs are only checked to pass).
#
# Usage: xv6_pi4.py [-a] [test...]

import os, re, select, shutil, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "../..")
XV6 = os.environ.get("XV6", os.path.expanduser("~/xv6"))
MINI = os.path.join(ROOT, "_build/default/raspberry/Main.exe")
QEMU64 = os.environ.get("QEMU64", "/media/pad/extradrive1/pad/work/TOOLCHAINS/qemu/build/qemu-system-aarch64")
if not os.access(QEMU64, os.X_OK): QEMU64 = shutil.which("qemu-system-aarch64")
PHYSTOP_MB = 4

DEFAULT = ["MAXVAplus", "copyin", "copyinstr2", "rwsbrk", "sbrkbasic", "sbrkarg", "truncate1", "subdir",
           "linktest", "exectest", "bigargtest", "pipe1", "preempt", "stacktest", "mem", "forktest"]
ALL = ["MAXVAplus", "copyin", "copyout", "copyinstr1", "copyinstr2", "copyinstr3", "rwsbrk", "truncate1",
       "truncate2", "truncate3", "pgbug", "sbrkbugs", "forkforkfork", "argptest", "createdelete", "linkunlink",
       "linktest", "unlinkread", "subdir", "fourfiles", "sharedfd", "dirtest", "exectest", "bigargtest",
       "bigwrite", "bsstest", "sbrkbasic", "kernmem", "sbrkfail", "sbrkarg", "sbrklast", "sbrk8000",
       "validatetest", "stacktest", "opentest", "writetest", "writebig", "createtest", "openiput", "exitiput",
       "iput", "mem", "pipe1", "killstatus", "preempt", "exitwait", "rmdot", "fourteen", "bigfile", "dirfile",
       "iref", "forktest"]

def build():
    """the kernel with PHYSTOP lowered, in a mirror of ~/xv6 kept
    between runs (make rebuilds what changed)"""
    mirror = os.path.join(tempfile.gettempdir(), "ix-xv6-pi4-%dmb" % PHYSTOP_MB)
    fork = os.path.join(mirror, "forks/arm64-pi4")
    if not os.path.isdir(fork):
        os.makedirs(os.path.join(mirror, "forks"))
        for e in os.listdir(XV6):
            if e != "forks": os.symlink(os.path.join(XV6, e), os.path.join(mirror, e))
        shutil.copytree(os.path.join(XV6, "forks/arm64-pi4"), fork, symlinks=True)
    layout = os.path.join(fork, "kernel/memlayout.h")
    text = open(os.path.realpath(os.path.join(XV6, "forks/arm64-pi4/kernel/memlayout.h"))).read()
    lowered = re.sub(r"#define PHYSTOP +\(EXTMEM\+128\*1024\*1024\)", "#define PHYSTOP   (EXTMEM+%d*1024*1024)" % PHYSTOP_MB, text)
    if lowered == text: sys.exit("xv6_pi4: PHYSTOP not found in memlayout.h")
    if os.path.islink(layout) or open(layout).read() != lowered:
        os.remove(layout); open(layout, "w").write(lowered)
    r = subprocess.run(["make", "TOOLPREFIX=aarch64-linux-gnu-", "kernel/kernel"], cwd=fork, capture_output=True, text=True)
    if r.returncode != 0: sys.exit("xv6_pi4: the build failed\n" + r.stdout[-2000:] + r.stderr[-2000:])
    return os.path.join(fork, "kernel/kernel")

class Console:
    """an emulator's console: characters sent, output waited for"""
    def __init__(self, argv):
        self.p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.buf = b""
    def wait(self, pattern, timeout):
        end = time.time() + timeout
        while time.time() < end:
            m = re.search(pattern, self.buf)
            if m:
                out, self.buf = self.buf[:m.end()], self.buf[m.end():]
                return out
            r, _, _ = select.select([self.p.stdout], [], [], 0.2)
            if r:
                d = os.read(self.p.stdout.fileno(), 65536)
                if not d: break
                self.buf += d
        return None
    def send(self, s):
        self.p.stdin.write(s.encode()); self.p.stdin.flush()
    def kill(self):
        self.p.kill(); self.p.wait()

def session(argv, tests, results):
    """boot, then each test: its output until the verdict, or None"""
    c = Console(argv)
    try:
        boot = c.wait(rb"\$ ", 60)
        results["boot"] = boot and re.sub(rb"hart [123] starting\r?\n", b"", boot)
        if boot is None: return
        for t in tests:
            c.send("usertests %s\n" % t)
            out = c.wait(rb"(ALL TESTS PASSED|SOME TESTS FAILED|panic[^\n]*)\r?\n", 60)
            results[t] = out
            if out is None or c.wait(rb"\$ ", 30) is None: return
    finally:
        c.kill()

def main():
    args = sys.argv[1:]
    tests = ALL if args[:1] == ["-a"] else (args or DEFAULT)
    kernel = build()
    mini, qemu = {}, {}
    runs = [threading.Thread(target=session, args=([MINI, "-cpu", "cortex-a72", "-M", "raspi4b", "-m", "2G", "-smp", "1",
                                                     "-nographic", "-kernel", kernel], tests, mini))]
    if QEMU64:
        runs.append(threading.Thread(target=session, args=([QEMU64, "-cpu", "cortex-a72", "-M", "raspi4b", "-m", "2G", "-smp", "4",
                                                             "-nographic", "-kernel", kernel], tests, qemu)))
    start = time.time()
    for r in runs: r.start()
    for r in runs: r.join()
    failures = 0
    clean = lambda b: b.replace(b"\r", b"")
    if mini.get("boot") is None or (QEMU64 and qemu.get("boot") is not None and clean(qemu["boot"]) != clean(mini["boot"])):
        print("FAIL boot: %s" % ("no prompt (60s)" if mini.get("boot") is None else "the output differs from QEMU's"))
        failures += 1
    else:
        print("ok boot%s" % (", as QEMU's" if QEMU64 else ""))
    for t in tests:
        out = mini.get(t)
        if out is None or b"ALL TESTS PASSED" not in out:
            print("FAIL %s: %s" % (t, "no verdict (60s)" if out is None else clean(out).decode(errors="replace").strip()[-300:]))
            failures += 1
        elif QEMU64 and qemu.get(t) is not None and clean(qemu[t]) != clean(out):
            print("FAIL %s: the output differs from QEMU's" % t)
            failures += 1
        else:
            print("ok %s%s" % (t, ", as QEMU's" if QEMU64 else ""))
    print("xv6_pi4: %d tests, %d failures, %.0fs (PHYSTOP %dMB)" % (len(tests), failures, time.time() - start, PHYSTOP_MB))
    sys.exit(1 if failures else 0)

main()
