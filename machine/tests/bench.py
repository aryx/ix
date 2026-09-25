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
# The interpreters' speed (plan_arm.md, decision 3 and phase 6): a
# static ELF looping N times over 7 instructions (add, eor shifted,
# ldr, str, multiply-accumulate, subs, bne), for arm32 (5) or arm64
# (7), run under mini-5i with -s (its MIPS), under qemu-user, and on
# the CPU, whose checksum mini-5i's must equal.
#
# Usage: bench.py 5|7 [iterations, default 20000000] [-o program]
# (-o: the program written, for a profiler, and nothing run)

import os, shutil, struct, subprocess, sys, tempfile, time

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../..")
TA = os.path.join(ROOT, "_build/default/machine/Main.exe")
ARCH = sys.argv[1]
N = int(sys.argv[2]) if len(sys.argv) > 2 else 20000000
BASE = 0x10000

if ARCH == "7":
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
        # write(1, sp, 8): the checksum; exit(0)
        0xf90003e4,                                    # str x4, [sp]
        0xd2800020, 0x910003e1, 0xd2800102, 0xd2800808, 0xd4000001,
        0xd2800000, 0xd2800ba8, 0xd4000001,
    ]
    qemu = "qemu-aarch64"
else:
    code = [
        0xe59f0000, 0xea000000, N,                     # ldr r0, =N
        0xe24dd020,                                    # sub sp, sp, #32
        # loop:
        0xe0811000,                                    # add r1, r1, r0
        0xe0222181,                                    # eor r2, r2, r1, lsl #3
        0xe59d3008,                                    # ldr r3, [sp, #8]
        0xe58d1010,                                    # str r1, [sp, #16]
        0xe0243291,                                    # mla r4, r1, r2, r3
        0xe2500001,                                    # subs r0, r0, #1
        0x1afffff8,                                    # bne loop (-32)
        # write(1, sp, 4): the checksum; exit(0)
        0xe58d4000,                                    # str r4, [sp]
        0xe3a00001, 0xe1a0100d, 0xe3a02004, 0xe3a07004, 0xef000000,
        0xe3a00000, 0xe3a07001, 0xef000000,
    ]
    qemu = "qemu-arm"
size = 0x100 + 4 * len(code)
img = bytearray(size)
if ARCH == "7":
    img[0:64] = struct.pack("<4sBBBB8xHHIQQQIHHHHHH", b"\x7fELF", 2, 1, 1, 0, 2, 183, 1, BASE + 0x100, 64, 0, 0, 64, 56, 1, 0, 0, 0)
    img[64:120] = struct.pack("<IIQQQQQQ", 1, 5, 0, BASE, BASE, size, size, 0x1000)
else:
    img[0:52] = struct.pack("<4sBBBB8xHHIIIIIHHHHHH", b"\x7fELF", 1, 1, 1, 0, 2, 40, 1, BASE + 0x100, 52, 0, 0x05000000, 52, 32, 1, 0, 0, 0)
    img[52:84] = struct.pack("<IIIIIIII", 1, 0, BASE, BASE, size, size, 5, 0x1000)
img[0x100:] = b"".join(struct.pack("<I", w) for w in code)
if "-o" in sys.argv:
    out = sys.argv[sys.argv.index("-o") + 1]
    open(out, "wb").write(img); os.chmod(out, 0o755); sys.exit(0)
d = tempfile.mkdtemp()
prog = os.path.join(d, "bench" + ARCH)
open(prog, "wb").write(img); os.chmod(prog, 0o755)
def timed(cmd):
    t = time.time(); out = subprocess.run(cmd, capture_output=True); return out, time.time() - t
(native, tn) = timed([prog])
native = native.stdout
tiny, _ = timed([TA, "-s", prog])
insns = 7 * N
print(tiny.stderr.decode().strip())
print("native: %.3f s, %.0f MIPS" % (tn, insns / tn / 1e6))
if shutil.which(qemu):
    _, tq = timed([qemu, prog])
    print("%s: %.3f s, %.0f MIPS" % (qemu, tq, insns / tq / 1e6))
os.remove(prog); os.rmdir(d)
print("checksum %s" % ("same as native" if tiny.stdout == native else "DIFFERS from native"))
sys.exit(0 if tiny.stdout == native else 1)
