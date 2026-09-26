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
# The OCaml a corpus is written in (plan_ml.md, "The subset, counted"):
# keywords and constructs, counted on tokens with the comments, strings
# and characters removed. Tokens, not a parse: the counts are close,
# not exact (an "|" counts a match's case as well as a variant's).
#
# Usage: count_ml.py [--files] dir-or-file...
#   e.g. count_ml.py kernel/9pi kernel/lib   (mini-9pi's OCaml)

import os, re, sys
from collections import Counter

def files(paths):
    for p in paths:
        if os.path.isdir(p):
            for root, _, fs in os.walk(p):
                if "/build" in root or "/_build" in root:
                    continue
                for f in sorted(fs):
                    if f.endswith((".ml", ".mli")):
                        yield os.path.join(root, f)
        else:
            yield p

# comments nest in OCaml; strings inside comments are lexed too
def strip(src):
    out, i, depth, n = [], 0, 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("(*", i):
            depth += 1; i += 2; continue
        if depth and src.startswith("*)", i):
            depth -= 1; i += 2; continue
        if c == '"':
            j = i + 1
            while j < n and src[j] != '"':
                j += 2 if src[j] == "\\" else 1
            if not depth:
                out.append('""')
            i = j + 1; continue
        m = re.match(r"'(\\.[0-9]*|[^\\'])'", src[i:i+6])
        if m and not (i > 0 and (src[i-1].isalnum() or src[i-1] == "_")):
            if not depth:
                out.append("'c'")
            i += len(m.group(0)); continue
        if not depth:
            out.append(c)
        i += 1
    return "".join(out)

TOKEN = re.compile(r"""
    (?P<float>\b[0-9][0-9_]*\.[0-9_]*([eE][-+]?[0-9]+)?|\b[0-9][0-9_]*[eE][-+]?[0-9]+)
  | (?P<ident>[A-Za-z_][A-Za-z0-9_']*)
  | (?P<op>:=|<-|->|\.\(|\.\[|\.\{|\{<|::|;;|\|\||&&|[-+*/]\.|\*\*|[~?`#!@^|;,(){}\[\]=<>+*/.:-])
""", re.X)

def count(src, c):
    toks = [(m.lastgroup, m.group(0)) for m in TOKEN.finditer(strip(src))]
    words = [t for _, t in toks]
    c["lines"] += src.count("\n")
    for k, (kind, t) in enumerate(toks):
        nxt = words[k+1] if k+1 < len(words) else ""
        prev = words[k-1] if k > 0 else ""
        if kind == "float":
            c["float literal"] += 1
        elif kind == "ident":
            if t in KEYWORDS:
                c[t] += 1
            if t == "let" and nxt == "rec": c["let rec"] += 1
            if t == "let" and nxt == "open": c["let open"] += 1
            if t in ("land", "lor", "lxor", "lsl", "lsr", "asr", "lnot"): c["land lor lxor lsl lsr asr lnot"] += 1
            if t == "ref": c["ref"] += 1
        else:
            if t in OPS: c[OPS[t]] += 1
            if t == "~" and re.match(r"[a-z]", nxt): c["labeled argument ~l"] += 1
            if t == "?" and re.match(r"[a-z]", nxt): c["optional argument ?l"] += 1
            if t == "`": c["polymorphic variant `A"] += 1
            if t == "#" and re.match(r"[a-z]", nxt): c["method call #m"] += 1
            if t in ("+.", "-.", "*.", "/.", "**"): c["float operator"] += 1
    return c

KEYWORDS = """let rec and in fun function match with when as try raise exception
  type of mutable if then else while for do done to downto begin end open
  module struct sig functor val external include assert lazy object method
  class new inherit private virtual constraint""".split()

OPS = {":=": ":=", "!": "!", "<-": "<- (field or array set)", ".(": ".( (array)",
       ".[": ".[ (string)", "::": "::", "{": "{ (record)", "|": "|"}

def main():
    args = sys.argv[1:]
    per_file = "--files" in args
    args = [a for a in args if a != "--files"]
    total, n = Counter(), 0
    for f in files(args):
        c = count(open(f, encoding="latin-1").read(), Counter())
        if per_file:
            print(f"{f:40} {c['lines']:6}")
        total += c; n += 1
    print(f"{n} files, {total['lines']} lines, in {', '.join(args)}\n")
    for k, v in sorted(total.items(), key=lambda kv: -kv[1]):
        if k != "lines":
            print(f"  {k:32} {v:6}")

main()
