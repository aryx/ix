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
#   session.py [--until S] [--timeout N] [--out F] [--screendump P]
#              [--usb] [--move DX,DY;...] [--prompt P] LINES... -- EMULATOR...
#
# --prompt: the shell's prompt, "$ " by default (mini-9pi's rc: "% ");
# --lines F: the lines to type from a file (after LINES).
# With --screendump, the emulator is given a QMP socket and, once the
# session is over, the screen is written to P (a PPM), as QMP's
# screendump writes it. With --usb, the lines are typed on the USB
# keyboard (QMP's send-key, a key at a time; a US keyboard's printable
# characters, a shifted one with shift) instead of the serial line; --move, the mouse moved (QMP's
# input-send-event) once they are done, before the screendump.
#
# mini-xv6 against xv6 arm-pi1's own C kernel (Makefile's compare,
# usertests).

import json, os, select, socket, subprocess, sys, tempfile, time

# a QMP client: its commands, a key typed (pressed, held 100ms, as
# QEMU's send-key; then half a second, so that no two overlap however
# slow the emulator)
class Qmp:
    QCODES = dict([(c, c) for c in "abcdefghijklmnopqrstuvwxyz0123456789"] +
                  [(" ", "spc"), ("\n", "ret"), ("-", "minus"), (".", "dot"), ("/", "slash"),
                   ("'", "apostrophe"), ("=", "equal"), (",", "comma"), (";", "semicolon"), ("[", "bracket_left"),
                   ("]", "bracket_right"), ("\\", "backslash"), ("`", "grave_accent")])
    # claude: the shifted ones, typed as shift and their key together (a
    # US keyboard's)
    SHIFTED = dict(list(zip("ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz")) +
                   list(zip("!@#$%^&*()_+:\"<>?{}|~", ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "minus",
                        "equal", "semicolon", "apostrophe", "comma", "dot", "slash", "bracket_left", "bracket_right",
                        "backslash", "grave_accent"])))
    def __init__(self, sock):
        self.c = socket.socket(socket.AF_UNIX)
        self.c.connect(sock)
        self.f = self.c.makefile("rw")
        self.f.readline()
        self.cmd({"execute": "qmp_capabilities"})
    def cmd(self, obj):
        self.f.write(json.dumps(obj) + "\n"); self.f.flush()
        while True:
            r = json.loads(self.f.readline())
            if "return" in r or "error" in r: return r
    def key(self, ch):
        if ch in self.SHIFTED:
            keys = [{"type": "qcode", "data": "shift"}, {"type": "qcode", "data": self.SHIFTED[ch]}]
        else:
            keys = [{"type": "qcode", "data": self.QCODES[ch]}]
        self.cmd({"execute": "send-key", "arguments": {"keys": keys}})
        time.sleep(0.5)
    def close(self):
        self.c.close()

def main():
    args = sys.argv[1:]
    until, timeout, out, dump, usb, moves, prompt, more = None, 60, None, None, False, [], "$ ", []
    while args and args[0].startswith("--") and args[0] != "--":
        if args[0] == "--usb":
            usb = True; args = args[1:]; continue
        opt, val = args[0], args[1]
        args = args[2:]
        if opt == "--until": until = val
        elif opt == "--timeout": timeout = float(val)
        elif opt == "--out": out = val
        elif opt == "--screendump": dump = os.path.abspath(val)
        elif opt == "--prompt": prompt = val
        elif opt == "--lines": more = open(val).read().splitlines()
        elif opt == "--move": moves = [tuple(map(int, m.split(","))) for m in val.split(";") if m]
    k = args.index("--")
    lines, cmd = args[:k] + more, args[k + 1:]
    sock = None
    if dump or usb:
        sock = os.path.join(tempfile.mkdtemp(), "qmp.sock")
        cmd = cmd + ["-qmp", "unix:%s,server,nowait" % sock]
    qmp = None
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
        # a prompt ("$ ") ending the output, after what was typed last,
        # and a second of quiet (a file's text may hold one: cat README's
        # does, and a slow emulator may pause right after it)
        if len(text) > mark and text.endswith(prompt.encode()) and time.time() - last > 1:
            if seen < len(lines):
                if usb:
                    if qmp is None: qmp = Qmp(sock)
                    for ch in lines[seen] + "\n": qmp.key(ch)
                else:
                    p.stdin.write(lines[seen].encode() + b"\r"); p.stdin.flush()
                seen += 1
                mark = len(text)
            elif until is None:
                ok = True; break
    if moves and ok:
        if qmp is None: qmp = Qmp(sock)
        for dx, dy in moves:
            qmp.cmd({"execute": "input-send-event", "arguments": {"events": [
                {"type": "rel", "data": {"axis": "x", "value": dx}}, {"type": "rel", "data": {"axis": "y", "value": dy}}]}})
            time.sleep(1)
        time.sleep(2)
    # one QMP connection a session: QEMU serves a single client, and
    # takes no second one after the first closes
    if dump and ok:
        if qmp is None: qmp = Qmp(sock)
        ok = "return" in qmp.cmd({"execute": "screendump", "arguments": {"filename": dump}})
    if qmp: qmp.close()
    p.kill()
    text = buf.replace(b"\r", b"").decode("latin-1")
    if out: open(out, "w").write(text)
    else: sys.stdout.write(text)
    sys.exit(0 if ok else 1)

# claude: importable (9pi/graphics.py uses its Qmp)
if __name__ == "__main__":
    main()
