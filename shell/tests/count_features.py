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
# The counts behind plan_rc.md's feature table: how many of principia's
# rc scripts (deduplicated by content), or of principia's and xix's
# mkfile recipes, use each rc construct, and how often. Regular
# expressions per construct, after removing comments and single-quoted
# strings (which may span lines). Counts of files and occurrences, not
# of meaning.
#
#   shell/tests/count_features.py scripts     # principia's 133 scripts
#   shell/tests/count_features.py recipes     # the 247 distinct mkfiles
#   shell/tests/count_features.py scripts --list
import re, sys, hashlib, collections, os
# documents: rc scripts (deduplicated by content) or mkfile recipes
def strip(line):
    # drop single-quoted strings (rc's only quote) and comments
    line = re.sub(r"'([^']|'')*'", "''", line)
    # a comment starts with a # at the start of a word, not in $#x
    m = re.search(r"(^|[\s;{])#", line)
    return line if not m else line[:m.start()]
F = [
 ("pipe |", r"(?<![|])\|(?![|\[])"),
 ("pipe with fds |[2]", r"\|\["),
 ("> redirect", r"(?<![>\[=<])>(?![>{\[])"),
 (">> append", r">>"),
 ("< input", r"(?<![<\[])<(?![<{\[])"),
 (">[2] >[2=1] fd redirect", r"[<>]\["),
 ("<< here document", r"<<"),
 ("<{ } >{ } process substitution", r"[<>]\{"),
 ("`{ } command substitution", r"`\s*\{"),
 ("if( )", r"\bif\s*\("),
 ("if not", r"\bif\s+not\b"),
 ("for( )", r"\bfor\s*\("),
 ("while( )", r"\bwhile\s*\("),
 ("switch( ) / case", r"\bswitch\s*\("),
 ("fn definition", r"\bfn\s+[\w.-]+\s*\{"),
 ("~ pattern match", r"(^|[\s(!])~\s"),
 ("! negation", r"(^|[\s{;])!\s"),
 ("&& ||", r"&&|\|\|"),
 ("& background", r"(?<![&\[=])&(?![&])"),
 ("$#x count", r"\$#"),
 ("$\"x join", r"\$\""),
 ("^ concatenation", r"\^"),
 ("@{ } subshell", r"@\s*\{"),
 ("$x(n) subscript", r"\$[\w*]+\("),
 ("$* $1..", r"\$(\*|[0-9])"),
 ("$status", r"\$status\b"),
 ("x=y assignment", r"(^|[\s;{])[A-Za-z_][\w]*=(?!=)"),
 ("list ( a b )", r"=\s*\("),
 ("glob * ? [", r"(?<![$\w])[*?](?!\))|\[[^\]=0-9]"),
 ("builtin cd", r"(^|[\s;{])cd\b"),
 ("builtin exit", r"(^|[\s;{])exit\b"),
 ("builtin shift", r"(^|[\s;{])shift\b"),
 ("builtin wait", r"(^|[\s;{])wait\b"),
 ("builtin eval", r"(^|[\s;{])eval\b"),
 ("builtin exec", r"(^|[\s;{])exec\b"),
 ("builtin . (source)", r"(^|[\s;{])\.\s+\S"),
 ("builtin whatis", r"\bwhatis\b"),
 ("builtin flag", r"(^|[\s;{])flag\s"),
 ("builtin rfork", r"\brfork\b"),
 ("ifs=", r"\bifs\s*="),
 ("path=", r"\bpath\s*="),
]
def docs(kind, paths):
    seen = set()
    for p in paths:
        try: raw = open(p, "rb").read()
        except Exception: continue
        if b"\0" in raw: continue          # a binary
        text = raw.decode(errors="replace")
        if kind == "scripts" and not (text.startswith("#!") or p.endswith(".rc")): continue
        if kind == "recipes":
            text = "\n".join(l[1:] for l in text.splitlines() if l.startswith("\t"))
            if not text.strip(): continue
        h = hashlib.md5(text.encode()).hexdigest()
        if h in seen: continue
        seen.add(h)
        yield p, text
def find(cmd):
    import subprocess
    return [l for l in subprocess.run(["sh", "-c", cmd], capture_output=True, text=True).stdout.splitlines() if l]
# the inputs, as plan_rc.md counted them (2026-09-23)
PRINCIPIA = os.path.expanduser("~/principia")
if sys.argv[1] == "scripts":
    os.chdir(PRINCIPIA)
    paths = sorted(set(find("""find . -type f -not -path "./.git/*" -size -200k 2>/dev/null | xargs grep -l -m1 -E '^#!\\s*/(usr/)?bin/rc|^#!.*/rc\\b' 2>/dev/null | grep -v '\\.nw$\\|\\.tex$\\|\\.pdf$'""")
                       + find("""find . -name "*.rc" -type f -not -path "./.git/*" """)))
elif sys.argv[1] == "recipes":
    os.chdir(os.path.expanduser("~"))
    paths = sorted(set(find("""find -L ~/principia -name mkfile -not -path "*/.git/*" 2>/dev/null; find -L ~/principia/mkfiles -type f; find -L ~/xix -name mkfile -not -path "*/_build/*" -not -path "*/principia/*" 2>/dev/null; find -L ~/xix/mkfiles -type f""")))
else:
    sys.exit("usage: count_features.py scripts|recipes [--list]")
kind = sys.argv[1]
if "--list" in sys.argv:
    for p, _ in docs(kind, paths): print(p)
    sys.exit(0)
files = collections.Counter(); occ = collections.Counter(); n = 0; lines = 0
for p, text in docs(kind, paths):
    n += 1
    # quoted strings may span lines (awk programs): remove them first
    text_q = re.sub(r"'([^']|'')*'", "''", text)
    body = "\n".join(strip(l) for l in text_q.splitlines())
    lines += len(text.splitlines())
    for name, rx in F:
        k = len(re.findall(rx, body, re.M))
        if k: files[name] += 1; occ[name] += k
print(f"{n} distinct {kind}, {lines} lines")
for name, _ in sorted(F, key=lambda f: -files[f[0]]):
    print(f"{files[name]:5d} {occ[name]:6d}  {name}")
