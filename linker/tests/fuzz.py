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
# The encoders' fuzzer: random programs of the subset's instructions,
# through goken (5a/5l, 7a/7l -H7 -s) and through ix (mini-asm, mini-ld);
# the executables must be the same (elfcmp.py's rule). A program goken
# rejects is skipped; one only ix rejects is a gap, and one whose bytes
# differ a bug; each is kept in the work directory.
#
# usage: fuzz.py 5|7 [count] [seed]   (needs goken)

import os, random, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
IX = os.path.join(HERE, '..', '..', '_build', 'default')
GOKEN = os.path.expanduser('~/goken')
ENV = dict(os.environ, PATH=f"{GOKEN}/bin:{GOKEN}/ROOT/arch/boot-gcc/bin:" + os.environ['PATH'])

def const(r, wide):
    return r.choice([0, 1, 42, 255, 256, 0x3fc, 0x400, 0xfff, 0x1000, 0xfff000, 0x12345, 0xff00, 0xffff, 0x10000,
                     0x7fffffff, 0x80000000, 0xffffffff, -1, -2, -256, -4096, r.randrange(-5000, 5000),
                     r.randrange(0, 1 << 32), 7, 0xf0, 0x0f0f0f0f, 0x5555] +
                    ([0x100000000, 0xffff0000ffff, 0x0101010101010101, -0x100000000, r.randrange(0, 1 << 63)] if wide else []))

def arm(r, nfuncs):
    R = lambda: f"R{r.choice([0, 1, 2, 3, 4, 5, 6, 7, 8, 9])}"
    c = lambda: f"${const(r, False)}"
    cond = lambda: r.choice(["", "", "", ".EQ", ".NE", ".LT", ".HS"])
    off = lambda: r.choice([0, 4, 8, -4, 100, 4000, 4096, 8192, -300, 255, 256, 1 << 16])
    lines = []
    for i in range(r.randrange(3, 12)):
        k = r.randrange(16)
        if k == 0: lines.append(f"MOVW{cond()} {c()}, {R()}")
        elif k == 1: lines.append(f"MOVW{cond()} {R()}, {R()}")
        elif k == 2: lines.append(f"{r.choice(['ADD', 'SUB', 'AND', 'ORR', 'EOR', 'RSB', 'BIC'])}{cond()}{r.choice(['', '.S'])} {c()}, {R()}, {R()}")
        elif k == 3: lines.append(f"{r.choice(['ADD', 'SUB', 'AND', 'ORR', 'EOR'])} {R()}{r.choice(['', '<<2', '>>3', '->1'])}, {R()}, {R()}")
        elif k == 4: lines.append(f"{r.choice(['CMP', 'CMN', 'TST'])} {r.choice([c(), R()])}, {R()}")
        elif k == 5:
            w = r.choice(['MOVW', 'MOVB', 'MOVBU', 'MOVH', 'MOVHU'])
            m = r.choice([f"{off()}({R()})", f"x+{r.choice([0, 4, 8])}(SB)", f"y+{r.choice([0, 4])}(SB)", f"a+{r.choice([0, 4, 8])}(FP)", f"l-{r.choice([4, 8, 12])}(SP)"])
            lines.append(r.choice([f"{w} {m}, {R()}", f"{w} {R()}, {m}"]))
        elif k == 6: lines.append(f"MOVW ${r.choice(['x', 'y', 'f0'])}+{r.choice([0, 4])}(SB), {R()}")
        elif k == 7: lines.append(f"MOVW $l-{r.choice([4, 8])}(SP), {R()}")
        elif k == 8: lines.append(r.choice([f"MUL {R()}, {R()}, {R()}", f"{r.choice(['MULL', 'MULLU'])} {R()}, {R()}, ({R()}, {R()})"]))
        elif k == 9: lines.append(f"{r.choice(['SLL', 'SRL', 'SRA'])} {r.choice(['$3', '$31', R()])}, {R()}, {R()}")
        elif k == 10: lines.append(f"MVN {r.choice([c(), R()])}, {R()}")
        elif k == 11: lines.append(f"BL f{r.randrange(nfuncs)}(SB)")
        elif k == 12: lines.append(f"B{r.choice(['', 'EQ', 'NE', 'LT'])} 2(PC)")
        elif k == 13: lines.append(f"MOVM.IA.W [R1,R2,R3], (R{r.choice([4, 5])})" if r.random() < .5 else "MOVM.IA (R4), [R1,R2]")
        elif k == 14: lines.append(f"{r.choice(['MOVD', 'MOVF'])} {r.choice([f'{off() & ~3}(R1)', 'x+0(SB)'])}, F{r.randrange(4)}")
        else: lines.append(f"{r.choice(['ADDD', 'MULD', 'SUBF'])} F{r.randrange(4)}, F{r.randrange(4)}")
    return lines

def arm64(r, nfuncs):
    R = lambda: f"R{r.choice([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10])}"
    F = lambda: f"F{r.randrange(8)}"
    c = lambda: f"${const(r, True)}"
    off = lambda: r.choice([0, 8, 16, -8, 3, 100, 4000, 4096, 8192, 32760, -300, 255, 256, 1 << 16])
    w = lambda: r.choice(['', 'W'])
    lines = []
    for i in range(r.randrange(3, 12)):
        k = r.randrange(17)
        if k == 0: lines.append(f"{r.choice(['MOV', 'MOVW', 'MOVWU'])} {c()}, {R()}")
        elif k == 1: lines.append(f"{r.choice(['MOV', 'MOVW', 'MOVWU', 'MOVB', 'MOVBU', 'MOVH', 'MOVHU', 'SXTW'])} {R()}, {R()}")
        elif k == 2: lines.append(f"{r.choice(['ADD', 'SUB', 'ADDS', 'SUBS'])}{w()} {c()}, {R()}, {R()}")
        elif k == 3: lines.append(f"{r.choice(['ADD', 'SUB', 'AND', 'ORR', 'EOR'])}{w()} {R()}, {R()}, {R()}")
        elif k == 4: lines.append(f"{r.choice(['AND', 'ORR', 'EOR'])}{w()} {c()}, {R()}{r.choice(['', ', ' + R()])}")
        elif k == 5: lines.append(f"{r.choice(['CMP', 'CMN'])}{w()} {r.choice([c(), R()])}, {R()}")
        elif k == 6:
            op = r.choice(['MOV', 'MOVW', 'MOVWU', 'MOVB', 'MOVBU', 'MOVH', 'MOVHU'])
            m = r.choice([f"{off()}({R()})", f"x+{r.choice([0, 8])}(SB)", f"y+{r.choice([0, 4])}(SB)", f"a+{r.choice([0, 8, 16])}(FP)", f"l-{r.choice([8, 16, 24])}(SP)"])
            lines.append(r.choice([f"{op} {m}, {R()}", f"{op} {R()}, {m}", f"{op} $0, {m}"]))
        elif k == 7: lines.append(f"MOV ${r.choice(['x', 'y', 'f0'])}+{r.choice([0, 8])}(SB), {R()}")
        elif k == 8: lines.append(f"MOV $l-{r.choice([8, 16])}(SP), {R()}")
        elif k == 9: lines.append(f"{r.choice(['MUL', 'SDIV', 'UDIV', 'REM', 'UREM'])}{w()} {R()}, {R()}{r.choice(['', ', ' + R()])}")
        elif k == 10: lines.append(f"{r.choice(['LSL', 'LSR', 'ASR'])}{w()} {r.choice(['$3', '$31', R()])}, {R()}, {R()}")
        elif k == 11: lines.append(f"{r.choice(['NEG', 'MVN'])}{w()} {R()}, {R()}")
        elif k == 12: lines.append(f"BL f{r.randrange(nfuncs)}(SB)")
        elif k == 13: lines.append(r.choice([f"B{r.choice(['', 'EQ', 'NE', 'LT', 'HS'])} 2(PC)", f"CBZ {R()}, 2(PC)"]))
        elif k == 14: lines.append(f"{r.choice(['FMOVD', 'FMOVS'])} {r.choice([f'{off() & ~7}(R1)', 'x+0(SB)', 'l-8(SP)'])}, {F()}")
        elif k == 15: lines.append(r.choice([f"{r.choice(['FADDD', 'FMULD', 'FSUBS'])} {F()}, {F()}", f"FCMPD {F()}, {F()}",
                                             f"SCVTFD {R()}, {F()}", f"FCVTZSD {F()}, {R()}", f"FMOVD $1.5, {F()}"]))
        else: lines.append(f"UMULL {R()}, {R()}, {R()}")
    return lines

def program(m, r):
    n = r.randrange(1, 4)
    gen = arm if m == '5' else arm64
    ret = 'RET' if m == '5' else 'RETURN'
    text = []
    for i in range(n):
        name = '_start' if i == 0 else f"f{i}"
        text.append(f"TEXT {name}(SB), ${r.choice([0, 0, 8, 16, 20, 100, 5000, -4 if m == '5' else -8])}")
        text += ['\t' + l for l in gen(r, n)] + [f"\t{ret}"]
    # the BLs' f0, a leaf
    text.append(f"TEXT f0(SB), $0")
    text.append(f"\t{ret}")
    text += ["GLOBL x(SB), $64", "DATA x+0(SB)/8, $\"abcdefgh\"", "DATA x+8(SB)/4, $12345",
             "GLOBL y(SB), $8", f"DATA y+0(SB)/{4 if m == '5' else 8}, $x+8(SB)"]
    return '\n'.join(text) + '\n'

def run(cmd, cwd):
    return subprocess.run(cmd, cwd=cwd, env=ENV, capture_output=True, text=True)

def main():
    m = sys.argv[1]
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 200
    seed = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    r = random.Random(seed)
    work = tempfile.mkdtemp(prefix=f'fuzz{m}-')
    stats = {'same': 0, 'skipped': 0, 'gap': 0, 'bug': 0}
    for i in range(count):
        d = os.path.join(work, str(i))
        os.makedirs(d)
        with open(os.path.join(d, 'p.s'), 'w') as f:
            f.write(program(m, r))
        g = run([f'{m}a', '-r', 'p.s'], d)
        if g.returncode == 0:
            g = run([f'{m}l', '-H7', '-s', '-E', '_start', '-o', 'g.exe', f'p.{m}'], d)
        if g.returncode != 0 or 'illegal' in g.stdout + g.stderr or not os.path.exists(os.path.join(d, 'g.exe')):
            stats['skipped'] += 1
            continue
        t = run([f'{IX}/assembler/Main.exe', '-m', m, '-o', 't.o', 'p.s'], d)
        if t.returncode == 0:
            t = run([f'{IX}/linker/Main.exe', '-m', m, '-H7', '-E', '_start', '-o', 't.exe', 't.o'], d)
        if t.returncode != 0:
            stats['gap'] += 1
            print(f"gap {d}: {(t.stdout + t.stderr).strip()[:150]}")
            continue
        c = run(['python3', os.path.join(HERE, 'elfcmp.py'), 'g.exe', 't.exe'], d)
        if c.returncode == 0:
            stats['same'] += 1
            subprocess.run(['rm', '-rf', d])
        else:
            stats['bug'] += 1
            print(f"bug {d}: {c.stdout.strip()}")
    print(m, stats, work)

main()
