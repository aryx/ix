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
# How alike two C compilers' sources are, once comments and layout are
# gone: for each file pair, and each function in both, the share of
# lines that match, in order (difflib) and in any order (as a multiset:
# a switch's cases are often reordered), and the functions in one only. The
# evidence behind plan_cc.md's "one code generator for 5c and 7c".
#
# usage: compare_c.py dirA dirB file.c...   (a file may be a:b, for
# different names in A and B)

import collections, difflib, re, sys

def normalize(text):
    text = re.sub(r'/\*.*?\*/', ' ', text, flags=re.S)
    text = re.sub(r'//[^\n]*', '', text)
    lines = []
    for l in text.split('\n'):
        l = re.sub(r'\s+', ' ', l).strip()
        if l and l not in ('{', '}'):
            lines.append(l)
    return lines

# a function starts at column 0 with a name and a (, the Plan 9 way
# (its type on the line before); it ends at the next such name
def functions(text):
    text = re.sub(r'/\*.*?\*/', ' ', text, flags=re.S)
    funcs, name, body = {}, None, []
    for l in text.split('\n'):
        m = re.match(r'^([a-zA-Z_][a-zA-Z0-9_]*)\(', l)
        if m and not l.rstrip().endswith(';'):
            if name: funcs[name] = body
            name, body = m.group(1), []
        elif name:
            body.append(l)
    if name: funcs[name] = body
    return {k: normalize('\n'.join(v)) for k, v in funcs.items()}

def same(a, b):
    m = difflib.SequenceMatcher(None, a, b, autojunk=False)
    return sum(x.size for x in m.get_matching_blocks())

# the same lines in any order: the cases of a switch move around
def shared(a, b):
    return sum((collections.Counter(a) & collections.Counter(b)).values())

a_dir, b_dir = sys.argv[1], sys.argv[2]
ta = tb = tm = tk = 0
for f in sys.argv[3:]:
    fa, fb = (f.split(':') + [f])[:2] if ':' in f else (f, f)
    sa, sb = open(f"{a_dir}/{fa}", errors='replace').read(), open(f"{b_dir}/{fb}", errors='replace').read()
    la, lb = normalize(sa), normalize(sb)
    m, k = same(la, lb), shared(la, lb)
    ta, tb, tm, tk = ta + len(la), tb + len(lb), tm + m, tk + k
    big = max(1, max(len(la), len(lb)))
    print(f"{fa:12} {len(la):5} {len(lb):5}  {100 * m // big:3}% the same in order, {100 * k // big:3}% in any order")
    fa_, fb_ = functions(sa), functions(sb)
    for n in sorted(set(fa_) | set(fb_)):
        if n not in fb_: print(f"    {n}: in A only ({len(fa_[n])} lines)")
        elif n not in fa_: print(f"    {n}: in B only ({len(fb_[n])} lines)")
        else:
            x, y = fa_[n], fb_[n]
            big = max(1, max(len(x), len(y)))
            p, q = 100 * same(x, y) // big, 100 * shared(x, y) // big
            if q < 90: print(f"    {n}: {len(x)} / {len(y)} lines, {p}% in order, {q}% in any order")
big = max(1, max(ta, tb))
print(f"{'total':12} {ta:5} {tb:5}  {100 * tm // big:3}% the same in order, {100 * tk // big:3}% in any order")
