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
# Phase 4: random blocks of arm32 instructions run on the CPU (this
# machine runs AArch32 natively) and under TinyArm, the final states
# compared. The corpus executes few of the operand forms, flag cases
# and conditions; here every data processing form, multiplies, clz,
# mrs/msr, and loads and stores of every size and addressing mode run
# from random registers and flags.
#
# Each block is its own static ELF, written here:
#
#   prologue   flags <- random (msr), sp <- the state area,
#              ldm sp, {r0-r12, lr}  (random values; r12 = the buffer)
#   block      N random instructions
#   epilogue   stm sp, {r0-r12, lr}; mrs; write(1, state + buffer)
#
# The block never writes r12 (the base of every transfer), sp or pc;
# a transfer writing back r12 is unconditional, so its value here is
# always known and every address stays inside the 512-byte buffer.
# On a difference, the shortest differing prefix is the culprit.
#
# With -64: arm64 blocks (Arm64): every data processing form decoded,
# the flags through msr/mrs nzcv, loads and stores of every size and
# addressing mode (x27 the base), pairs, and conditional branches over
# one instruction. A64 has no conditional execution, so every
# writeback's value is known here. Registers: x0-x30 and nzcv out.
#
# Usage: random_blocks.py [-64] [blocks] [length] [seed]

import concurrent.futures, os, random, struct, subprocess, sys, tempfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../..")
TA = os.path.join(ROOT, "_build/default/machine/Main.exe")
A64 = len(sys.argv) > 1 and sys.argv[1] == "-64"
argv = sys.argv[2:] if A64 else sys.argv[1:]
BLOCKS = int(argv[0]) if len(argv) > 0 else 500
LENGTH = int(argv[1]) if len(argv) > 1 else 30
SEED = int(argv[2]) if len(argv) > 2 else 1

BASE = 0x10000                  # the segment's address
CODE = 0x100                    # offsets in the file
STATE = 0x2000                  # r0-r12, lr, cpsr: 15 words
BUF = STATE + 64                # the buffer
BUFSIZE = 512
FILE = BUF + BUFSIZE
OUT = BUF + BUFSIZE - STATE     # bytes written
LO, HI = BASE + BUF + 192, BASE + BUF + 320   # r12's range
FORBID = (12, 13, 15)           # never destinations

def lit(rd, value):
    # ldr rd, [pc]; b over the literal; the literal
    return [0xe59f0000 | rd << 12, 0xea000000, value]

def elf(block, flags, regs, buf):
    code = lit(0, flags << 28) + [0xe128f000] + lit(13, BASE + STATE) + [0xe89d5fff]
    code += block
    code += [0xe88d5fff, 0xe10f0000, 0xe58d0038, 0xe3a00001, 0xe1a0100d] + lit(2, OUT)
    code += [0xe3a07004, 0xef000000, 0xe3a00000, 0xe3a07001, 0xef000000]
    img = bytearray(FILE)
    img[0:52] = struct.pack("<4sBBBB8xHHIIIIIHHHHHH", b"\x7fELF", 1, 1, 1, 0,
                            2, 40, 1, BASE + CODE, 52, 0, 0x05000000, 52, 32, 1, 0, 0, 0)
    img[52:84] = struct.pack("<IIIIIIII", 1, 0, BASE, BASE, FILE, FILE, 7, 0x1000)
    img[CODE:CODE + 4 * len(code)] = b"".join(struct.pack("<I", w) for w in code)
    img[STATE:STATE + 56] = b"".join(struct.pack("<I", v) for v in regs)
    img[BUF:BUF + BUFSIZE] = buf
    return bytes(img)

class Gen:
    def __init__(self, r):
        self.r = r
        self.base = (LO + HI) // 2 & ~7

    def reg(self, avoid=()):
        return self.r.choice([k for k in range(15) if k not in avoid])

    def dest(self, avoid=()):
        return self.reg(FORBID + tuple(avoid))

    def cond(self):
        return self.r.randrange(15) << 28

    def dp(self):
        r = self.r
        op = r.randrange(16)
        s = 1 if 8 <= op <= 11 else r.randrange(2)
        rd = 0 if 8 <= op <= 11 else self.dest()
        rn = 0 if op in (13, 15) else r.randrange(16)
        k = r.randrange(3)
        if k == 0:
            # 25% of the values rotated: the carry out of the rotation
            op2 = 1 << 25 | (r.randrange(16) if r.random() < 0.5 else 0) << 8 | r.randrange(256)
        elif k == 1:
            op2 = r.randrange(32) << 7 | r.randrange(4) << 5 | r.randrange(16)
        else:
            if rn == 15: rn = self.reg()
            op2 = self.reg() << 8 | r.randrange(4) << 5 | 1 << 4 | self.reg()
        return self.cond() | op << 21 | s << 20 | rn << 16 | rd << 12 | op2

    def mul(self):
        r = self.r
        if r.random() < 0.5:
            rd = self.dest()
            return self.cond() | r.randrange(4) << 20 | rd << 16 | self.reg() << 12 | self.reg() << 8 | 0x90 | self.reg()
        lo = self.dest(); hi = self.dest((lo,))
        return self.cond() | 1 << 23 | r.randrange(8) << 20 | hi << 16 | lo << 12 | self.reg() << 8 | 0x90 | self.reg()

    def misc(self):
        r = self.r
        k = r.randrange(3)
        if k == 0: return self.cond() | 0x016f0f10 | self.dest() << 12 | self.reg()
        if k == 1:
            # the flags of the CPSR only: its other bits are the
            # machine's (this one's ARMv8 SSBS, bit 23; the mode reads 0)
            rd = self.dest()
            return [self.cond() | 0x010f0000 | rd << 12, 0xe200020f | rd << 16 | rd << 12]
        # msr CPSR_f, #N << 28: the flags only (not Q, which TinyArm lacks)
        return self.cond() | 0x0328f200 | r.randrange(16)

    def transfer(self, span, align):
        """an offset, its sign, indexing and writeback, the base kept in
        [LO, HI] and the address in the buffer"""
        r = self.r
        while True:
            up = r.randrange(2)
            pre, wb = r.choice([(1, 0), (1, 0), (1, 1), (0, 0)])
            # r12 stays word-aligned, for ldm and ldrd
            off = r.randrange(0, span + 1, align if pre and not wb else max(align, 4))
            moved = self.base + off if up else self.base - off
            if (pre == 0 or wb) and not (LO <= moved <= HI): continue
            return off, up, pre, wb, moved

    def mem(self):
        r = self.r
        kind = r.choice(["w", "b", "h", "sb", "sh", "d"])
        load = 1 if kind in ("sb", "sh") else r.randrange(2)
        # words and halfwords unaligned too (ARMv7 and later allow them);
        # ldrd needs a word
        align = {"w": 1, "b": 1, "h": 1, "sb": 1, "sh": 1, "d": 4}[kind]
        off, up, pre, wb, moved = self.transfer(128 if kind in ("w", "b") else 124, align)
        if kind == "d":
            rd = r.choice([k for k in (0, 2, 4, 6, 8, 10)])
        else:
            rd = self.dest() if load else self.reg((12, 15))
        # the stored or loaded register is never the base written back
        writes = pre == 0 or wb
        cond = 0xe0000000 if writes else self.cond()
        if writes: self.base = moved
        if kind in ("w", "b"):
            return cond | 1 << 26 | pre << 24 | up << 23 | (kind == "b") << 22 | wb << 21 | load << 20 | 12 << 16 | rd << 12 | off
        sh = {"h": 1, "sb": 2, "sh": 3, "d": 2 if load else 3}[kind]
        l = 0 if kind == "d" else load
        return cond | pre << 24 | up << 23 | 1 << 22 | wb << 21 | l << 20 | 12 << 16 | rd << 12 | (off >> 4) << 8 | 1 << 7 | sh << 5 | 1 << 4 | (off & 15)

    def block(self):
        r = self.r
        load = r.randrange(2)
        regs = 0
        for k in range(15):
            if k in (12, 13) and load: continue
            if k == 12: continue
            if r.random() < 0.3: regs |= 1 << k
        if regs == 0: regs = 1
        n = bin(regs).count("1")
        p, u = r.randrange(2), r.randrange(2)
        wb = r.randrange(2)
        final = self.base + 4 * n if u else self.base - 4 * n
        if wb and not (LO <= final <= HI): wb = 0
        cond = 0xe0000000 if wb else self.cond()
        if wb: self.base = final
        return cond | 4 << 25 | p << 24 | u << 23 | wb << 21 | load << 20 | 12 << 16 | regs

    def insn(self):
        k = self.r.random()
        if k < 0.5: return self.dp()
        if k < 0.6: return self.mul()
        if k < 0.7: return self.misc()
        if k < 0.9: return self.mem()
        return self.block()


#############################################################################
# arm64
#############################################################################

STATE64 = 0x2000                # x0-x30, nzcv: 32 doublewords
BUF64 = STATE64 + 256
FILE64 = BUF64 + BUFSIZE
OUT64 = FILE64 - STATE64
LO64, HI64 = BASE + BUF64 + 192, BASE + BUF64 + 320   # x27's range
M64 = (1 << 64) - 1

def lit64(rd, value):
    # ldr xd, [pc, #8]; b over the literal; the literal
    return [0x58000040 | rd, 0x14000003, value & 0xffffffff, value >> 32]

def elf64(block, flags, regs, buf):
    sp = 31
    code = lit64(0, BASE + STATE64) + [0x9100001f]          # mov sp, x0
    code += [0xf9407fe0, 0xd51b4200]                         # ldr x0, [sp, #248]; msr nzcv, x0
    code += [0xa9400000 | k << 15 | (k + 1) << 10 | sp << 5 | k for k in range(0, 30, 2)]  # ldp
    code += [0xf9407bfe]                                     # ldr x30, [sp, #240]
    code += block
    code += [0xa9000000 | k << 15 | (k + 1) << 10 | sp << 5 | k for k in range(0, 30, 2)]  # stp
    code += [0xf9007bfe, 0xd53b4200, 0xf9007fe0]             # str x30; mrs x0, nzcv; str x0, [sp, #248]
    code += [0xd2800020, 0x910003e1, 0xd2800002 | OUT64 << 5, 0xd2800808, 0xd4000001]  # write(1, sp, OUT)
    code += [0xd2800000, 0xd2800ba8, 0xd4000001]             # exit(0)
    img = bytearray(FILE64)
    img[0:64] = struct.pack("<4sBBBB8xHHIQQQIHHHHHH", b"\x7fELF", 2, 1, 1, 0,
                            2, 183, 1, BASE + CODE, 64, 0, 0, 64, 56, 1, 0, 0, 0)
    img[64:120] = struct.pack("<IIQQQQQQ", 1, 7, 0, BASE, BASE, FILE64, FILE64, 0x1000)
    img[CODE:CODE + 4 * len(code)] = b"".join(struct.pack("<I", w) for w in code)
    img[STATE64:STATE64 + 256] = b"".join(struct.pack("<Q", v & M64) for v in regs + [flags << 28])
    img[BUF64:BUF64 + BUFSIZE] = buf
    return bytes(img)

def bitmask_ok(sf, n, imms):
    v = n << 6 | (~imms & 0x3f)
    if v == 0: return False
    length = v.bit_length() - 1
    if length < 1 or (not sf and n): return False
    levels = (1 << length) - 1
    return imms & levels != levels

class Gen64:
    def __init__(self, r):
        self.r = r
        self.base = (LO64 + HI64) // 2 & ~15

    def reg(self): return self.r.randrange(32)            # 31: zr (or sp)
    def dest(self, sp=False):
        """a destination: never x27; 31 is sp when [sp], and sp is never written"""
        return self.r.choice([k for k in range(32) if k != 27 and not (sp and k == 31)])

    def dp(self):
        r = self.r
        sf = r.randrange(2)
        width = 64 if sf else 32
        k = r.randrange(16)
        if k == 0:                                           # add/sub immediate
            s = r.randrange(2)
            return sf << 31 | r.randrange(2) << 30 | s << 29 | 0b100010 << 23 | r.randrange(2) << 22 | r.randrange(4096) << 10 | self.reg() << 5 | self.dest(sp=not s)
        if k == 1:                                           # logical immediate
            while True:
                n = r.randrange(2) if sf else 0
                imms = r.randrange(64 if sf else 32)
                if bitmask_ok(sf, n, imms): break
            opc = r.randrange(4)
            return sf << 31 | opc << 29 | 0b100100 << 23 | n << 22 | r.randrange(width) << 16 | imms << 10 | self.reg() << 5 | self.dest(sp=opc != 3)
        if k == 2:                                           # move wide
            return sf << 31 | r.choice([0, 2, 3]) << 29 | 0b100101 << 23 | r.randrange(4 if sf else 2) << 21 | r.getrandbits(16) << 5 | self.dest()
        if k == 3:                                           # bitfield
            return sf << 31 | r.randrange(3) << 29 | 0b100110 << 23 | sf << 22 | r.randrange(width) << 16 | r.randrange(width) << 10 | self.reg() << 5 | self.dest()
        if k == 4:                                           # extr
            return sf << 31 | 0b100111 << 23 | sf << 22 | self.reg() << 16 | r.randrange(width) << 10 | self.reg() << 5 | self.dest()
        if k == 5:                                           # adr, adrp
            return r.randrange(2) << 31 | r.randrange(4) << 29 | 0b10000 << 24 | r.getrandbits(19) << 5 | self.dest()
        if k == 6:                                           # add/sub shifted register
            return sf << 31 | r.randrange(4) << 29 | 0b01011 << 24 | r.randrange(3) << 22 | self.reg() << 16 | r.randrange(width) << 10 | self.reg() << 5 | self.dest()
        if k == 7:                                           # add/sub extended register
            s = r.randrange(2)
            return sf << 31 | r.randrange(2) << 30 | s << 29 | 0b01011001 << 21 | self.reg() << 16 | r.randrange(8) << 13 | r.randrange(5) << 10 | self.reg() << 5 | self.dest(sp=not s)
        if k == 8:                                           # logical shifted register
            return sf << 31 | r.randrange(4) << 29 | 0b01010 << 24 | r.randrange(4) << 22 | r.randrange(2) << 21 | self.reg() << 16 | r.randrange(width) << 10 | self.reg() << 5 | self.dest()
        if k == 9:                                           # adc, sbc
            return sf << 31 | r.randrange(4) << 29 | 0b11010000 << 21 | self.reg() << 16 | self.reg() << 5 | self.dest()
        if k == 10:                                          # ccmp, ccmn
            return sf << 31 | r.randrange(2) << 30 | 1 << 29 | 0b11010010 << 21 | self.reg() << 16 | r.randrange(16) << 12 | r.randrange(2) << 11 | self.reg() << 5 | r.randrange(16)
        if k == 11:                                          # csel, csinc, csinv, csneg
            return sf << 31 | r.randrange(2) << 30 | 0b11010100 << 21 | self.reg() << 16 | r.randrange(16) << 12 | r.randrange(2) << 10 | self.reg() << 5 | self.dest()
        if k == 12:                                          # rbit, rev16, rev32, rev, clz, cls
            op = r.choice([0, 1, 2, 3, 4, 5] if sf else [0, 1, 2, 4, 5])
            return sf << 31 | 1 << 30 | 0b11010110 << 21 | op << 10 | self.reg() << 5 | self.dest()
        if k == 13:                                          # udiv, sdiv, lslv, lsrv, asrv, rorv
            return sf << 31 | 0b11010110 << 21 | self.reg() << 16 | r.choice([2, 3, 8, 9, 10, 11]) << 10 | self.reg() << 5 | self.dest()
        if k == 14:                                          # madd, msub; the long and high multiplies
            if r.randrange(2) or not sf:
                return sf << 31 | 0b11011 << 24 | self.reg() << 16 | r.randrange(2) << 15 | self.reg() << 10 | self.reg() << 5 | self.dest()
            op31, o0 = r.choice([(1, 0), (1, 1), (5, 0), (5, 1), (2, 0), (6, 0)])
            ra = 31 if op31 in (2, 6) else self.reg()
            return 1 << 31 | 0b11011 << 24 | op31 << 21 | self.reg() << 16 | o0 << 15 | ra << 10 | self.reg() << 5 | self.dest()
        if r.randrange(2): return 0xd53b4200 | self.dest()     # mrs xN, nzcv
        return 0xd51b4200 | self.reg()                         # msr nzcv, xN

    def moved(self, lo, hi, align):
        """an offset in [lo, hi], aligned, keeping the base in range"""
        while True:
            off = self.r.randrange(lo // align, hi // align + 1) * align
            if LO64 <= self.base + off <= HI64: return off

    def mem(self):
        r = self.r
        size = r.randrange(4)
        # (opc, is a load) for the size: stores, loads, signed loads
        opc = r.choice([0, 1, 2, 3] if size < 2 else [0, 1, 2] if size == 2 else [0, 1])
        load = opc != 0
        kind = r.choice(["uoff", "unscaled", "pre", "post", "reg"])
        wb = kind in ("pre", "post")
        rt = self.dest() if load else r.choice([k for k in range(32) if not (wb and k == 27)])
        top = 0b111 << 27 | size << 30 | opc << 22 | 27 << 5 | rt
        if kind == "uoff":
            off = r.randrange(0, 129 >> size) << size
            return top | 1 << 24 | (off >> size) << 10
        if kind == "unscaled":
            return top | (r.randrange(-128, 129) & 0x1ff) << 12
        if kind == "reg":
            # the index register xzr: offset 0, every extend and shift
            return top | 1 << 21 | 31 << 16 | r.choice([2, 3, 6, 7]) << 13 | r.randrange(2) << 12 | 0b10 << 10
        off = self.moved(-128, 128, 1)
        self.base += off
        return top | (off & 0x1ff) << 12 | (0b11 if kind == "pre" else 0b01) << 10

    def pair(self):
        r = self.r
        opc, load = r.choice([(0, 0), (0, 1), (2, 0), (2, 1), (1, 1)])
        scale = 8 if opc == 2 else 4
        mode = r.choice([0, 1, 2, 3])                          # nontemporal, post, offset, pre
        wb = mode in (1, 3)
        if load:
            rt = self.dest(); rt2 = r.choice([k for k in range(32) if k not in (27, rt)])
        else:
            rt = r.choice([k for k in range(32) if not (wb and k == 27)]); rt2 = r.choice([k for k in range(32) if not (wb and k == 27)])
        if mode == 0 and opc == 1: mode = 2                   # ldpsw has no nontemporal form
        if wb:
            off = self.moved(-128, 128, scale); self.base += off
        else:
            off = r.randrange(-128 // scale, 128 // scale + 1) * scale
        return opc << 30 | 0b101 << 27 | mode << 23 | load << 22 | ((off // scale) & 0x7f) << 15 | rt2 << 10 | 27 << 5 | rt

    def branch(self):
        """a conditional branch over the next instruction (a data
        processing one: never a writeback, whose base would be unknown)"""
        r = self.r
        k = r.randrange(3)
        if k == 0: b = 0x54000040 | r.randrange(16)                                   # b.cond +8
        elif k == 1: b = r.randrange(2) << 31 | 0b011010 << 25 | r.randrange(2) << 24 | 2 << 5 | self.reg()  # cbz/cbnz +8
        else:
            bit = r.randrange(64)
            b = (bit >> 5) << 31 | 0b011011 << 25 | r.randrange(2) << 24 | (bit & 31) << 19 | 2 << 5 | self.reg()  # tbz/tbnz +8
        return [b, self.dp()]

    def insn(self):
        k = self.r.random()
        if k < 0.6: return self.dp()
        if k < 0.8: return self.mem()
        if k < 0.9: return self.pair()
        return self.branch()

def regs64(r, g):
    special = [0, 1, M64, 1 << 63, (1 << 63) - 1, 0xffffffff, 0x80000000, 0x7fffffff, 64, 32]
    regs = [r.getrandbits(64) if r.random() < 0.8 else r.choice(special) for _ in range(31)]
    regs[27] = g.base
    return regs

#############################################################################
# Running and comparing
#############################################################################

def run(cmd):
    p = subprocess.run(cmd, capture_output=True, timeout=30)
    return p.returncode, p.stdout

def compare(path):
    a, b = run([path]), run([TA, path])
    return a == b, a, b

def check(i):
    r = random.Random(SEED * 1000003 + i)
    g = Gen64(r) if A64 else Gen(r)
    if A64: regs = regs64(r, g)
    else:
        regs = [r.getrandbits(32) if r.random() < 0.8 else r.choice([0, 1, 31, 32, 0x7fffffff, 0x80000000, 0xffffffff])
                for _ in range(14)]
        regs[12] = g.base
    flags = r.randrange(16)
    buf = bytes(r.getrandbits(8) for _ in range(BUFSIZE))
    # groups of instructions (an mrs and its mask), never split
    groups = [x if isinstance(x, list) else [x] for x in (g.insn() for _ in range(LENGTH))]
    with tempfile.TemporaryDirectory() as d:
        return search(d, i, groups, flags, regs, buf)

def search(d, i, groups, flags, regs, buf):
    def prog(n):
        path = os.path.join(d, "b%d" % n)
        with open(path, "wb") as f: f.write((elf64 if A64 else elf)(sum(groups[:n], []), flags, regs, buf))
        os.chmod(path, 0o755)
        return path
    same, a, b = compare(prog(len(groups)))
    if same: return None
    lo, hi = 0, len(groups)             # prefix lo agrees, hi differs
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if compare(prog(mid))[0]: lo = mid
        else: hi = mid
    _, a, b = compare(prog(hi))
    return i, groups[hi - 1][0], flags, regs, a, b

def objdump(w):
    with tempfile.NamedTemporaryFile(suffix=".bin") as f:
        f.write(struct.pack("<I", w)); f.flush()
        out = subprocess.run(["objdump", "-D", "-b", "binary", "-m", "aarch64" if A64 else "arm", f.name], capture_output=True, text=True).stdout
    return out.strip().splitlines()[-1].split("\t", 2)[-1]

def explain(a, b):
    (sa, oa), (sb, ob) = a, b
    if A64:
        if sa != sb or len(oa) != OUT64 or len(ob) != OUT64:
            return "  status %d vs %d, %d vs %d bytes" % (sa, sb, len(oa), len(ob))
        names = ["x%d" % k for k in range(31)] + ["nzcv"]
        lines = []
        for k in range(32):
            x, y = struct.unpack_from("<Q", oa, 8 * k)[0], struct.unpack_from("<Q", ob, 8 * k)[0]
            if x != y: lines.append("  %-4s cpu %016x  tinyarm %016x" % (names[k], x, y))
        for o in range(256, OUT64):
            if oa[o] != ob[o]: lines.append("  buffer+%d cpu %02x  tinyarm %02x" % (o - 256, oa[o], ob[o]))
        return "\n".join(lines[:12])
    names = ["r%d" % k for k in range(13)] + ["lr", "cpsr"]
    if sa != sb or len(oa) != OUT or len(ob) != OUT:
        return "  status %d vs %d, %d vs %d bytes%s" % (sa, sb, len(oa), len(ob), "")
    lines = []
    for k in range(15):
        x, y = struct.unpack_from("<I", oa, 4 * k)[0], struct.unpack_from("<I", ob, 4 * k)[0]
        if k == 14: x, y = x & 0xf0000000, y & 0xf0000000
        if x != y: lines.append("  %-4s cpu %08x  tinyarm %08x" % (names[k], x, y))
    for o in range(64, OUT):
        if oa[o] != ob[o]: lines.append("  buffer+%d cpu %02x  tinyarm %02x" % (o - 64, oa[o], ob[o]))
    return "\n".join(lines[:12])

# the flags compared, not the rest of the CPSR (its mode and mask bits)
def masked(out):
    code, data = out
    if not A64 and len(data) == OUT:
        cpsr = struct.unpack_from("<I", data, 56)[0] & 0xf0000000
        data = data[:56] + struct.pack("<I", cpsr) + data[60:]
    return code, data

_compare = compare
def compare(path):
    _, a, b = _compare(path)
    a, b = masked(a), masked(b)
    return a == b, a, b

# a host that does not run the programs (x86; an arm64 kernel without
# COMPAT for arm32) skips
with tempfile.TemporaryDirectory() as d:
    probe = os.path.join(d, "probe")
    open(probe, "wb").write(elf64([], 0, [0] * 31, bytes(BUFSIZE)) if A64 else elf([], 0, [0] * 14, bytes(BUFSIZE)))
    os.chmod(probe, 0o755)
    try: subprocess.run([probe], capture_output=True)
    except OSError:
        print("random_blocks: this machine does not run %s programs, skipped" % ("arm64" if A64 else "arm32")); sys.exit(0)

# processes, not threads: a program written while another thread forks
# would be busy (ETXTBSY) when run
with concurrent.futures.ProcessPoolExecutor(os.cpu_count()) as ex:
    bad = [x for x in ex.map(check, range(BLOCKS), chunksize=16) if x]
for i, w, flags, regs, a, b in bad[:20]:
    print("block %d: %08x  %s   (flags %x)" % (i, w, objdump(w), flags))
    print(explain(a, b))
print("random_blocks%s: %d blocks of %d instructions, %d differ" % (" -64" if A64 else "", BLOCKS, LENGTH, len(bad)))
sys.exit(1 if bad else 0)
