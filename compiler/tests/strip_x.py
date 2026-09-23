#!/usr/bin/env python3
# A -x dump without what differs between cck and tinycc and is not the
# tree: the locations (cck prints file:line from its line history, and
# after a #line both: bc.y:6[bc.c:1]; tinycc the line), cck's warnings,
# and its %S of a rune string.
# usage: strip_x.py dump > normalized
import re, sys

for l in open(sys.argv[1], errors="replace"):
    if l.startswith("warning:") or re.match(r"\S+\.[ch]:[0-9]+ ", l):
        continue
    l = re.sub(r"( \S+:[0-9]+(\[\S+\])?)+$| [0-9]+$", "", l.rstrip("\n"))
    print(re.sub(r'^( *LSTRING) ".*"', r'\1 "..."', l))
