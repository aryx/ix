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
# mini-qemu against QEMU on principia's 9pi with its graphics (plan_pi.md,
# phase J): booted as principia's graphical "mk run" boots it, with a
# USB keyboard and mouse, but headless (-display none, QMP on a Unix
# socket): 9pi draws its console ("Plan 9 Console", the draw device's)
# in the framebuffer, its usb/kb reads the keyboard's and the mouse's
# interrupt endpoints.
# Screendumps are taken until the screen is still (three alike); then
# the steps: lines typed by QMP's send-key, a key a second (so no two
# overlap in either emulator, whose clocks differ), the mouse moved and
# its buttons pressed by QMP's input-send-event -- in the console, then
# in rio, started from it: its menu, a window swept out, a command
# typed in the window -- each followed by a still screen. Every screen,
# and the console's bytes, must be QEMU's.
#
# Needs ~/principia (9pi built: kernel/COMPILE/9/bcm/9pi, qemu-sd.img),
# and ~/xv6/scripts/qemu_graphics.py (its QMP client).
#
# Usage: 9pi_graphics.py

import concurrent.futures, hashlib, os, subprocess, sys, tempfile, time

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../..")
TP = os.path.join(ROOT, "_build/default/raspberry/Main.exe")
P = os.environ.get("PRINCIPIA", os.path.expanduser("~/principia"))
sys.path.insert(0, os.path.join(os.environ.get("XV6", os.path.expanduser("~/xv6")), "scripts"))
import qemu_graphics as qg  # noqa: E402

ARGS = ["-M", "raspi1ap", "-device", "loader,file=kernel/COMPILE/9/bcm/9pi,addr=0x8000,cpu-num=0,force-raw=on",
        "-drive", "file=qemu-sd.img,if=sd,format=raw,snapshot=on", "-serial", "null", "-serial", "mon:stdio",
        "-device", "usb-kbd", "-device", "usb-mouse", "-display", "none"]
# the steps, each followed by a still screen: a line typed (then
# Enter); the mouse moved; buttons pressed, released (a step's events
# a second apart). In the console, then rio: its menu (button 3, on
# "New"), a window swept (button 3 held, dragged), a command in it.
STEPS = [("type", "ls /"), ("type", "echo hi"), ("move", 200, 100), ("move", -50, 120),
         ("type", "rio"), ("move", -50, -140), ("buttons", [("down", "right")]), ("buttons", [("up", "right")]),
         ("buttons", [("down", "right"), ("move", 300, 200), ("up", "right")]),
         ("type", "echo hello from rio")]
STEP = {"qemu": 4, "mini-qemu": 10}          # seconds between screendumps

def run(name, emu, d):
    """the console's bytes and the screens: booted, then after each line"""
    sock = os.path.join(d, "qmp.sock")
    serial = os.path.join(d, "serial.log")
    p = subprocess.Popen([emu] + ARGS + ["-qmp", "unix:%s,server,nowait" % sock], cwd=P,
                         stdin=subprocess.PIPE, stdout=open(serial, "wb"), stderr=subprocess.DEVNULL)
    screens = []
    try:
        for _ in range(100):
            if os.path.exists(sock): break
            time.sleep(0.1)
        m = qg.QMP(sock)
        def still(tag):
            last, same, k, t0 = None, 0, 0, time.time()
            while time.time() - t0 < 900:
                time.sleep(STEP[name])
                f = os.path.join(d, "%s%d.ppm" % (tag, k)); k += 1
                m.screendump(f)
                h = hashlib.md5(open(f, "rb").read()).hexdigest()
                same = same + 1 if h == last else 0
                last = h
                if same >= 3: return open(f, "rb").read()
            return None
        screens.append(still("boot"))
        def mouse(events):
            m.cmd({"execute": "input-send-event", "arguments": {"events": events}})
        def move(dx, dy):
            mouse([{"type": "rel", "data": {"axis": "x", "value": dx}}, {"type": "rel", "data": {"axis": "y", "value": dy}}])
        for i, step in enumerate(STEPS):
            if step[0] == "type":
                m.type_text(step[1] + "\n", delay=1.0)
            elif step[0] == "move":
                move(step[1], step[2])
            else:
                for e in step[1]:
                    if e[0] == "move": move(e[1], e[2])
                    else: mouse([{"type": "btn", "data": {"down": e[0] == "down", "button": e[1]}}])
                    time.sleep(2)
            screens.append(still("step%d" % i))
        m.close()
    finally:
        p.kill(); p.wait()
    # QEMU's own warnings are not the console's
    out = b"".join(l for l in open(serial, "rb").read().splitlines(keepends=True) if not l.startswith(b"qemu-system-arm:"))
    return out, screens

with tempfile.TemporaryDirectory() as dq, tempfile.TemporaryDirectory() as dm:
    with concurrent.futures.ThreadPoolExecutor(2) as ex:
        want = ex.submit(run, "qemu", "qemu-system-arm", dq)
        got = ex.submit(run, "mini-qemu", TP, dm)
        (wout, wscreens), (gout, gscreens) = want.result(), got.result()

names = ["the boot's screen"] + ["the screen after step %d, %r" % (i + 1, s) for i, s in enumerate(STEPS)]
failures = [n for n, a, b in zip(names, wscreens, gscreens) if a is None or a != b]
if wout != gout: failures.append("the console's bytes")
if failures:
    for f in failures: print("FAIL 9pi graphics: %s differs from QEMU's" % f)
    sys.exit(1)
print("ok 9pi graphics: the draw console, then rio (its menu, a window swept, a command in it), by the USB keyboard"
      " and mouse; %d screens and the console byte for byte QEMU's" % len(wscreens))
