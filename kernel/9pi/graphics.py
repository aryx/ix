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
#
# mini-9pi's graphics against the C 9pi's (plan_9pi.md, stage D): a
# kernel booted with QEMU's USB keyboard and mouse, then
# raspberry/tests/9pi_graphics.py's steps -- lines typed at the console,
# the mouse moved, rio started from it, its menu (button 3 on "New"), a
# window swept out, a command typed in it -- each followed by a still
# screen (screendumps every few seconds until three alike), written to
# DIR as boot.ppm, step1.ppm... The console's bytes to DIR/console.txt.
#
#   graphics.py [--step SECONDS] DIR -- EMULATOR ARGS...

import hashlib, os, shutil, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "../lib"))
from session import Qmp  # noqa: E402

STEPS = [("type", "ls /"), ("type", "echo hi"), ("move", 200, 100), ("move", -50, 120),
         ("type", "rio"), ("move", -50, -140), ("buttons", [("down", "right")]), ("buttons", [("up", "right")]),
         ("buttons", [("down", "right"), ("move", 300, 200), ("up", "right")]),
         ("type", "echo hello from rio")]

def main():
    args = sys.argv[1:]
    step = 4.0
    if args[0] == "--step":
        step = float(args[1]); args = args[2:]
    d, cmd = args[0], args[2:]
    os.makedirs(d, exist_ok=True)
    sock = os.path.join(tempfile.mkdtemp(), "qmp.sock")
    serial = open(os.path.join(d, "console.txt"), "wb")
    p = subprocess.Popen(cmd + ["-qmp", "unix:%s,server,nowait" % sock], stdin=subprocess.PIPE, stdout=serial,
                         stderr=subprocess.DEVNULL)
    try:
        for _ in range(100):
            if os.path.exists(sock): break
            time.sleep(0.1)
        m = Qmp(sock)
        def still(name):
            last, same, k, t0 = None, 0, 0, time.time()
            f = os.path.join(d, name + ".ppm")
            while time.time() - t0 < 900:
                time.sleep(step)
                t = os.path.join(d, "tmp%d.ppm" % k); k += 1
                m.cmd({"execute": "screendump", "arguments": {"filename": os.path.abspath(t)}})
                h = hashlib.md5(open(t, "rb").read()).hexdigest()
                same = same + 1 if h == last else 0
                last = h
                if same >= 3:
                    shutil.move(t, f)
                    break
            for x in os.listdir(d):
                if x.startswith("tmp"): os.remove(os.path.join(d, x))
        def mouse(events):
            m.cmd({"execute": "input-send-event", "arguments": {"events": events}})
        def move(dx, dy):
            mouse([{"type": "rel", "data": {"axis": "x", "value": dx}}, {"type": "rel", "data": {"axis": "y", "value": dy}}])
        still("boot")
        for i, s in enumerate(STEPS):
            if s[0] == "type":
                for ch in s[1] + "\n": m.key(ch)
            elif s[0] == "move":
                move(s[1], s[2])
            else:
                for e in s[1]:
                    if e[0] == "move": move(e[1], e[2])
                    else: mouse([{"type": "btn", "data": {"down": e[0] == "down", "button": e[1]}}])
                    time.sleep(2)
            still("step%d" % (i + 1))
        m.close()
    finally:
        p.kill(); p.wait()

main()
