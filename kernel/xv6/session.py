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
# A session with an xv6 on an emulator: each line typed at sh's prompt
# ("$ "), with CR as a terminal sends it, the console's output saved,
# CRs dropped. It ends at the prompt after the last line, or at [--until]
# (a string), or at the timeout (exit 1: not reached).
#
#   session.py [--until S] [--timeout N] [--out F] LINES... -- EMULATOR...
#
# mini-xv6 against xv6 arm-pi1's own C kernel (Makefile's compare,
# usertests).

import os, select, subprocess, sys, time

def main():
    args = sys.argv[1:]
    until, timeout, out = None, 60, None
    while args and args[0].startswith("--") and args[0] != "--":
        opt, val = args[0], args[1]
        args = args[2:]
        if opt == "--until": until = val
        elif opt == "--timeout": timeout = float(val)
        elif opt == "--out": out = val
    k = args.index("--")
    lines, cmd = args[:k], args[k + 1:]
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    buf = b""
    seen = 0            # the lines typed
    mark = 0            # the output's length when the last was
    end = time.time() + timeout
    ok = False
    last = time.time()  # when output last came
    while time.time() < end:
        r, _, _ = select.select([p.stdout], [], [], 0.2)
        if r:
            data = os.read(p.stdout.fileno(), 4096)
            if not data: break
            buf += data
            last = time.time()
        text = buf.replace(b"\r", b"")
        if until is not None and until.encode() in text:
            ok = True; break
        # a prompt: "$ " ending the output, after what was typed last,
        # and a second of quiet (a file's text may hold one: cat README's
        # does, and a slow emulator may pause right after it)
        if len(text) > mark and text.endswith(b"$ ") and time.time() - last > 1:
            if seen < len(lines):
                p.stdin.write(lines[seen].encode() + b"\r"); p.stdin.flush()
                seen += 1
                mark = len(text)
            elif until is None:
                ok = True; break
    p.kill()
    text = buf.replace(b"\r", b"").decode("latin-1")
    if out: open(out, "w").write(text)
    else: sys.stdout.write(text)
    sys.exit(0 if ok else 1)

main()
