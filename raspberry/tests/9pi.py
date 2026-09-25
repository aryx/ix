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
# mini-qemu against QEMU on principia's 9pi (plan_pi.md, phase C):
# the kernel loaded as principia's mkfile-target-pi runs it (-device
# loader at 0x8000, the SD card image, the mini UART the console), the
# card's writes kept in memory (snapshot=on); boot to rc's prompt, then
# a session of commands, each sent when the prompt is back: the file
# system read (ls, cat, wc), written (echo > file, back with cat: the
# SD card's writes through DMA), a pipe, the card's control file, and a
# floating point program (5c's code is FPA, which 9pi does not emulate:
# it dies of an undefined instruction, the same way on both). The
# console's bytes must be QEMU's.
#
# Needs ~/principia (9pi built: kernel/COMPILE/9/bcm/9pi, qemu-sd.img).
#
# Usage: 9pi.py

import os, subprocess, sys, time, fcntl

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../..")
TP = os.path.join(ROOT, "_build/default/raspberry/Main.exe")
P = os.environ.get("PRINCIPIA", os.path.expanduser("~/principia"))
ARGS = ["-M", "raspi1ap", "-device", "loader,file=kernel/COMPILE/9/bcm/9pi,addr=0x8000,cpu-num=0,force-raw=on",
        "-drive", "file=qemu-sd.img,if=sd,format=raw,snapshot=on", "-serial", "null", "-serial", "mon:stdio", "-display", "none"]
SESSION = ["ls /", "echo hello from mini-qemu", "ls -l /dev/sdM0", "cat /dev/sdM0/ctl",
           "echo written by the emulator > /x.txt", "cat /x.txt", "ls /arch/arm/bin | wc", "cat /CONFIG.TXT | wc",
           "echo 1.5*2 | hoc"]

def run(cmd):
    p = subprocess.Popen(cmd + ARGS, cwd=P, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    fl = fcntl.fcntl(p.stdout, fcntl.F_GETFL); fcntl.fcntl(p.stdout, fcntl.F_SETFL, fl | os.O_NONBLOCK)
    out = b""
    def wait_prompt(n, timeout):
        nonlocal out
        deadline = time.time() + timeout
        while time.time() < deadline and out.count(b"% ") < n:
            try:
                data = p.stdout.read()
                if data: out += data
            except (BlockingIOError, TypeError):
                pass
            time.sleep(0.05)
        return out.count(b"% ") >= n
    ok = wait_prompt(1, 120)
    for i, c in enumerate(SESSION):
        if not ok: break
        p.stdin.write((c + "\n").encode()); p.stdin.flush()
        ok = wait_prompt(i + 2, 60)
    time.sleep(0.5)
    p.kill(); p.wait()
    return ok, out

want_ok, want = run(["qemu-system-arm"])
got_ok, got = run([TP])
if not want_ok: print("QEMU did not complete the session"); sys.exit(1)
if want == got:
    print("ok 9pi: boot and a session of %d commands, byte for byte QEMU's (%d bytes)" % (len(SESSION), len(got)))
    sys.exit(0)
a, b = want.decode(errors="replace").splitlines(), got.decode(errors="replace").splitlines()
i = next((k for k in range(min(len(a), len(b))) if a[k] != b[k]), min(len(a), len(b)))
print("FAIL 9pi: differs from QEMU at line %d:\n  qemu:   %r\n  mini-qemu: %r" % (i + 1, a[i] if i < len(a) else None, b[i] if i < len(b) else None))
sys.exit(1)
