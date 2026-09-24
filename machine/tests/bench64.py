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
# The arm64 interpreter's speed (plan_arm.md, decision 3 and phase 6):
# a static ELF looping N times over 7 instructions (add, eor shifted,
# ldr, str, madd, subs, b.ne), run under TinyArm with -s (its MIPS),
# and natively for the checksum it writes.
#
# Usage: bench64.py [iterations, default 20000000]

import os, struct, subprocess, sys, tempfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../..")
TA = os.path.join(ROOT, "_build/default/machine/Main.exe")
N = int(sys.argv[1]) if len(sys.argv) > 1 else 20000000
BASE = 0x10000

code = [
    0xd2800000 | (N & 0xffff) << 5,                # movz x0, #N & 0xffff
    0xf2a00000 | (N >> 16 & 0xffff) << 5,          # movk x0, #N >> 16, lsl #16
    0xd10083ff,                                    # sub sp, sp, #32
    # loop:
    0x8b000021,                                    # add x1, x1, x0
    0xca010c42,                                    # eor x2, x2, x1, lsl #3
    0xf94007e3,                                    # ldr x3, [sp, #8]
    0xf9000be1,                                    # str x1, [sp, #16]
    0x9b020c24,                                    # madd x4, x1, x2, x3
    0xf1000400,                                    # subs x0, x0, #1
    0x54ffff41,                                    # b.ne loop (-24)
    # write(1, &x4, 8): the checksum; exit(0)
    0xf90003e4,                                    # str x4, [sp]
    0xd2800020, 0x910003e1, 0xd2800102, 0xd2800808, 0xd4000001,
    0xd2800000, 0xd2800ba8, 0xd4000001,
]
size = 0x100 + 4 * len(code)
img = bytearray(size)
img[0:64] = struct.pack("<4sBBBB8xHHIQQQIHHHHHH", b"\x7fELF", 2, 1, 1, 0, 2, 183, 1, BASE + 0x100, 64, 0, 0, 64, 56, 1, 0, 0, 0)
img[64:120] = struct.pack("<IIQQQQQQ", 1, 5, 0, BASE, BASE, size, size, 0x1000)
img[0x100:] = b"".join(struct.pack("<I", w) for w in code)
d = tempfile.mkdtemp()
prog = os.path.join(d, "bench64")
open(prog, "wb").write(img); os.chmod(prog, 0o755)
native = subprocess.run([prog], capture_output=True).stdout
tiny = subprocess.run([TA, "-s", prog], capture_output=True)
os.remove(prog); os.rmdir(d)
print(tiny.stderr.decode().strip())
print("checksum %s" % ("same as native" if tiny.stdout == native else "DIFFERS from native"))
sys.exit(0 if tiny.stdout == native else 1)
