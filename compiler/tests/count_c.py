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
# The C that mini-cc must take, counted: over goken's libc (all of
# it), libbio, libregexp, libstring, the hello_libc programs and
# goken's utilities, with their headers, the keywords, Plan 9's extensions and the
# preprocessor's directives, file by file and in all. Tokens, not a
# parse: a construct is found by its tokens (a bitfield is ": number ;"
# inside a struct, an unnamed member is a type name alone before ";").
# The evidence behind plan_cc.md's subset.
#
# usage: count_c.py [dir...]   (default: the corpus above)

import collections, glob, os, re, sys

G = os.path.expanduser('~/goken')
DIRS = sys.argv[1:] or ['lib_core/libc', 'lib_core/libbio', 'lib_strings/libregexp', 'lib_strings/libstring',
                        'tests/c/hello_libc', 'utilities']

KEYWORDS = ('auto break case char const continue default do double else enum extern float for goto if int '
            'long register return short signed sizeof static struct switch typedef union unsigned void volatile '
            'while inline restrict _Bool vlong uvlong uchar ushort uint ulong USED SET nil').split()

TOK = re.compile(r'''\.\.\.|->|\+\+|--|<<=|>>=|<<|>>|<=|>=|==|!=|&&|\|\||[-+*/%&|^]=|
                     [A-Za-z_][A-Za-z0-9_]*|0[xX][0-9a-fA-F]+[uUlL]*|[0-9]+\.[0-9]*([eE][-+]?[0-9]+)?[fFlL]?|
                     \.[0-9]+([eE][-+]?[0-9]+)?|[0-9]+[eE][-+]?[0-9]+|[0-9]+[uUlL]*|\S''', re.X)

def tokens(text):
    text = re.sub(r'/\*.*?\*/', ' ', text, flags=re.S)
    text = re.sub(r'//[^\n]*', ' ', text)
    text = re.sub(r'"(\\.|[^"\\\n])*"', ' "S" ', text)
    text = re.sub(r"'(\\.|[^'\\\n])*'", " 'C' ", text)
    pre, body = collections.Counter(), []
    for line in text.split('\n'):
        s = line.strip()
        if s.startswith('#'):
            m = re.match(r'#\s*(\w+)\s*(\w*)(\()?', s)
            if m:
                d = m.group(1)
                if d == 'define':
                    d = 'define(' if m.group(3) else 'define'
                if d == 'pragma':
                    d = 'pragma ' + m.group(2)
                pre[d] += 1
            continue
        body.append(line)
    return [m.group(0) for m in TOK.finditer('\n'.join(body))], pre

def constructs(toks):
    c = collections.Counter()
    for t in toks:
        if t in KEYWORDS: c[t] += 1
    depth, struct_depths = 0, []
    for i, t in enumerate(toks):
        nxt = toks[i + 1] if i + 1 < len(toks) else ''
        prev = toks[i - 1] if i else ''
        if t in ('struct', 'union') and (nxt == '{' or (i + 2 < len(toks) and toks[i + 2] == '{')):
            struct_depths.append(depth + 1)
        if t == '{': depth += 1
        if t == '}':
            if struct_depths and struct_depths[-1] == depth: struct_depths.pop()
            depth -= 1
        inside = struct_depths and struct_depths[-1] == depth
        if inside and t == ':' and re.match(r'[0-9]', nxt): c['bitfield'] += 1
        # Plan 9's unnamed member: "Lock;" alone in a struct
        if inside and t == ';' and re.match(r'[A-Z]\w*$', prev) and toks[i - 2] in (';', '{'): c['unnamed member'] += 1
        if t == '...': c['varargs (...)'] += 1
        if t == '->': c['->'] += 1
        if t == '?': c['?:'] += 1
        if t == '(' and nxt == '*' and i + 3 < len(toks) and toks[i + 3] == ')' and toks[i + 4] == '(': c['function pointer'] += 1
        if t in ('=', ',', '{') and nxt == '.' and i + 3 < len(toks) and toks[i + 3] == '=': c['designated .x ='] += 1
        if t in (',', '{') and nxt == '[' and i + 4 < len(toks) and toks[i + 3] == ']' and toks[i + 4] == '=': c['designated [n] ='] += 1
        if re.match(r'[0-9]*\.[0-9]|[0-9]+[eE]', t): c['float literal'] += 1
        if t == ':' and re.match(r'[A-Za-z_]\w*$', prev) and toks[i - 2] in (';', '{', '}', ':') and prev not in ('default',) and not inside:
            c['label'] += 1
        if t == 'long' and nxt == 'long': c['long long'] += 1
    return c

files = []
for d in DIRS:
    files += sorted(glob.glob(os.path.join(G, d, '**', '*.[ch]'), recursive=True))
# and the headers they share: libc.h, u.h, bio.h...
if not sys.argv[1:]:
    files += [os.path.join(G, 'include', h) for h in ('libc.h', 'ALL/bio.h', 'ALL/fmt.h')] + glob.glob(os.path.join(G, 'include/arch/*/u.h'))
total, pre_total, nlines = collections.Counter(), collections.Counter(), 0
for f in files:
    text = open(f, errors='replace').read()
    nlines += text.count('\n')
    toks, pre = tokens(text)
    total += constructs(toks)
    pre_total += pre
print(f"{len(files)} files, {nlines} lines, in {', '.join(DIRS)}")
print("\nkeywords and constructs:")
for k, v in total.most_common():
    print(f"  {k:22} {v:6}")
print("\npreprocessor:")
for k, v in pre_total.most_common():
    print(f"  #{k:21} {v:6}")
