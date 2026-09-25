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
# mini-qemu's graphics and USB keyboard against QEMU (plan_pi.md,
# phase B), headless: each port booted under QEMU and under mini-qemu with
# a keyboard (-device usb-kbd) and QMP, no window (-display none);
# once at the prompt, a screendump, "ls" and Enter typed by QMP's
# send-key, another screendump. The serial output (the USB devices
# enumerated, the command echoed, its listing) and both screendumps
# must be byte for byte QEMU's.
#
# xv6's own graphical check (scripts/test_qemu_graphics.py: pixels on
# the screen, more after typing, the command on the serial console),
# which opens a window on $DISPLAY, runs unchanged with
# MAKEFLAGS=QEMU_ARM=mini-qemu.
#
# Usage: graphics.py [port...]   (default arm-pi1-bis arm-pi1)

import os, subprocess, sys, tempfile, time

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../..")
TP = os.path.join(ROOT, "_build/default/raspberry/Main.exe")
XV6 = os.environ.get("XV6", os.path.expanduser("~/xv6"))
sys.path.insert(0, os.path.join(XV6, "scripts"))
import qemu_graphics as qg  # noqa: E402

IMAGES = {"arm-pi1": "kernel-qemu.img"}

def session(port, cmd, d):
    """the serial log and the two screendumps of one run"""
    sock = os.path.join(d, "qmp.sock"); log_path = os.path.join(d, "serial.log")
    log = open(log_path, "wb")
    args = ["-M", "raspi1ap", "-kernel", IMAGES.get(port, "kernel.img"), "-serial", "mon:stdio",
            "-device", "usb-kbd", "-display", "none", "-qmp", "unix:%s,server,nowait" % sock]
    p = subprocess.Popen(cmd + args, cwd=os.path.join(XV6, "forks", port), stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.DEVNULL)
    try:
        for _ in range(900):
            if b"\n$ " in open(log_path, "rb").read(): break
            time.sleep(0.1)
        m = qg.QMP(sock)
        m.screendump(os.path.join(d, "before.ppm"))
        m.type_text("ls\r")
        # the listing ends with the next prompt
        for _ in range(300):
            if open(log_path, "rb").read().count(b"\n$ ") >= 2: break
            time.sleep(0.1)
        time.sleep(1)
        m.screendump(os.path.join(d, "after.ppm"))
        m.close()
    finally:
        p.terminate(); p.wait()
    read = lambda f: open(os.path.join(d, f), "rb").read()
    return read("serial.log"), read("before.ppm"), read("after.ppm")

failures = 0
for port in sys.argv[1:] or ["arm-pi1-bis", "arm-pi1"]:
    with tempfile.TemporaryDirectory() as q, tempfile.TemporaryDirectory() as t:
        want = session(port, ["qemu-system-arm"], q)
        got = session(port, [TP], t)
    names = ["serial output", "boot screendump", "screendump after typing ls"]
    bad = [n for n, a, b in zip(names, want, got) if a != b]
    if bad:
        failures += 1
        print("FAIL %s: %s differ from QEMU's" % (port, ", ".join(bad)))
    else:
        print("ok %s: keyboard, serial output and screendumps as QEMU's" % port)
print("graphics: %d failures" % failures)
sys.exit(1 if failures else 0)
