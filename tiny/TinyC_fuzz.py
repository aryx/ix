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
# Random programs for TinyC_test.sh: integers of every width and sign,
# their operators, conversions, conditions, loops, arrays, pointers and
# calls, each value printed. No undefined behaviour the two compilers
# could take differently: a divisor is never 0, a shift is by less than
# the width, and the arithmetic wraps as the machine does. With --32,
# no long long: programs for tiny-c -tm too (TinyCPU is 32 bits), whose
# output must be arm64's.
# usage: TinyC_fuzz.py [--32] dir count [seed]
import os, random, sys

W32 = "--32" in sys.argv
if W32: sys.argv.remove("--32")
TYPES = ["char", "uchar", "short", "unsigned short", "int", "unsigned", "long", "ulong"] + ([] if W32 else ["vlong", "uvlong"])
BIG = "int" if W32 else "vlong"
BIN = ["+", "-", "*", "&", "|", "^", "<", ">", "<=", ">=", "==", "!="]

def expr(r, vs, d):
    if d <= 0 or r.random() < 0.25:
        k = r.random()
        if k < 0.5:
            return r.choice(vs)
        if k < 0.6:
            return "a[%s & 7]" % r.choice(vs)
        return str(r.choice([0, 1, 2, 3, 7, 100, 255, 256, 65535, -1, -128, 2147483647, 1000003]))
    k = r.random()
    a, b = expr(r, vs, d - 1), expr(r, vs, d - 1)
    if k < 0.45:
        return "(%s %s %s)" % (a, r.choice(BIN), b)
    if k < 0.55:
        return "(%s %s (%s | 1))" % (a, r.choice(["/", "%"]), b)
    if k < 0.65:
        return "(%s %s (%s & 15))" % (a, r.choice(["<<", ">>"]), b)
    if k < 0.75:
        return "((%s)%s)" % (r.choice(TYPES), a)
    if k < 0.82:
        return "(%s ? %s : %s)" % (a, b, expr(r, vs, d - 1))
    if k < 0.88:
        return "(%s %s %s)" % (a, r.choice(["&&", "||"]), b)
    if k < 0.94:
        return "%s(%s)" % (r.choice(["-", "~", "!"]), a)
    return "f(%s, %s)" % (a, b)

def program(r):
    vs = ["x%d" % i for i in range(6)]
    tys = [r.choice(TYPES) for _ in vs]
    libc = os.path.join(os.path.dirname(os.path.abspath(__file__)), "TinyC_tests", "libc.h")
    out = ['#include "%s"' % libc, "",
           "typedef unsigned short ushort;", "",
           "%s a[8];" % BIG, "",
           "long", "f(long p, int q)", "{", "\treturn p * 3 - q;", "}", "",
           "void", "main(int argc, char *argv[])", "{", "\tint i;"]
    for v, t in zip(vs, tys):
        out.append("\t%s %s;" % (t, v))
    out.append("\tfor(i = 0; i < 8; i++) a[i] = i * 1000003 - 17;")
    for v in vs:
        out.append("\t%s = %s;" % (v, expr(r, vs[:1] + ["i"], 1)))
    for _ in range(r.randint(3, 8)):
        k = r.random()
        v = r.choice(vs)
        if k < 0.6:
            out.append("\t%s %s %s;" % (v, r.choice(["=", "+=", "-=", "*=", "^=", "|="]), expr(r, vs, 3)))
        elif k < 0.8:
            out.append("\tfor(i = 0; i < %d; i++) %s = %s;" % (r.randint(1, 5), v, expr(r, vs + ["i"], 2)))
        elif k < 0.9:
            out.append("\tif(%s) %s++; else %s--;" % (expr(r, vs, 2), v, r.choice(vs)))
        else:
            out.append("\ta[%s & 7] = %s;" % (r.choice(vs), expr(r, vs, 2)))
    big = "%d" if W32 else "%lld"
    for v, t in zip(vs, tys):
        out.append('\tprint("%s\\n", (%s)%s);' % (big, BIG, v))
    out.append('\tprint("%s\\n", a[3] + a[5]);' % big)
    out.append("\texits(0);")
    out.append("}")
    return "\n".join(out) + "\n"

d, n = sys.argv[1], int(sys.argv[2])
seed = int(sys.argv[3]) if len(sys.argv) > 3 else 1
for i in range(n):
    r = random.Random(seed * 100000 + i)
    open("%s/fuzz%d.c" % (d, i), "w").write(program(r))
