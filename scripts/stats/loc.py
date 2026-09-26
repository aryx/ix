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
# Lines of OCaml across ix (.ml, .mli, .mll and .mly), grouped as ix
# is: the mini programs, the faithful twins (m-ix: assembler/,
# languages/c/, ..., kernel/), the tiny programs (t-ix: tiny/, one line
# per file, since a file is a program), the shared libraries (lib_*/),
# and apart from all of them the tests (every tests/ directory, and
# the top tests/). Each line is counted once, as code (it has some
# code, maybe a comment too), comment (only a comment, or inside one)
# or blank. The C and assembly (kernel/'s start.s, libc.c, tiny/tiny-os/)
# are not counted.
#
# The files are git's (tracked, and new ones not ignored), so _build/
# is never counted.
#
# Usage: scripts/stats/loc.py [-v]
#   -v: every subdirectory (kernel/xv6/, kernel/step1/, ...) and every
#       tests/ directory rather than one line per program
#
# The lines come first, next to the name they count; files, .ml,
# .mli, code, comment and blank lines after the name.

import re
import subprocess
import sys
from collections import defaultdict

# ---------------------------------------------------------------------
# Counting the lines of a file
# ---------------------------------------------------------------------

CHAR = re.compile(r"'(\\[\\'\"ntbr ]|\\[0-9]{3}|\\x[0-9a-fA-F]{2}|[^\\'\n])'")
QUOTED = re.compile(r"\{([a-z_]*)\|")


def count(text, c_comments=False):
    """(code, comment, blank) lines of an OCaml source: a small lexer
    for comments (nested, and with strings inside them), strings,
    quoted strings {id|...|id} and character literals ('"'); with
    c_comments, ocamlyacc's /* ... */ too (not nested)."""
    code = comment = blank = 0
    has_code = has_comment = False
    depth = 0  # comments nesting
    close = None  # inside a string: what ends it
    i, n = 0, len(text)
    while i <= n:
        if i == n or text[i] == "\n":
            if has_code:
                code += 1
            elif has_comment or depth > 0:
                comment += 1
            elif i < n or (n > 0 and text[-1] != "\n"):
                blank += 1
            has_code = False
            has_comment = depth > 0
            i += 1
            continue
        c = text[i]
        if close is not None:
            if depth > 0:
                has_comment = True
            elif not c.isspace():
                has_code = True
            if close == '"' and c == "\\":
                # an escape, but not over the newline of a "...\
                # continued" string: the line must still be counted
                i += 1 if text.startswith("\\\n", i) else 2
                continue
            if text.startswith(close, i):
                i += len(close)
                close = None
                continue
            i += 1
            continue
        if c_comments and text.startswith("/*", i):
            end = text.find("*/", i + 2)
            end = n if end < 0 else end + 2
            # the lines it spans, but its last, are comment lines
            for _ in range(text.count("\n", i, end)):
                if has_code:
                    code += 1
                else:
                    comment += 1
                has_code = False
            has_comment = True
            i = end
            continue
        if text.startswith("(*", i):
            depth += 1
            has_comment = True
            i += 2
            continue
        if depth > 0 and text.startswith("*)", i):
            depth -= 1
            i += 2
            continue
        if depth > 0:
            if not c.isspace():
                has_comment = True
            if c == '"':
                close = '"'
            i += 1
            continue
        if not c.isspace():
            has_code = True
        if c == '"':
            close = '"'
            i += 1
            continue
        if c == "{":
            m = QUOTED.match(text, i)
            if m:
                close = "|" + m.group(1) + "}"
                i = m.end()
                continue
        if c == "'":
            m = CHAR.match(text, i)
            if m:
                i = m.end()
                continue
        i += 1
    return code, comment, blank


# ---------------------------------------------------------------------
# Grouping the files
# ---------------------------------------------------------------------

# (group, its top directories), in the order printed; the rest is
# "other" (tiny-os's, docs/'s, ...)
GROUPS = [
    ("mini", ["assembler", "linker", "languages", "machine", "raspberry",
              "kernel", "builder", "shell", "editor", "database",
              "version_control"]),
    ("tiny", ["tiny"]),
    ("libraries", ["lib_core", "lib_compression", "lib_security"]),
]


def classify(path, verbose):
    """(group, subgroup) of a file: tests wherever they are, else by
    its top directory. The subgroup is the top directory (a program, a
    library), but in tiny/ the file itself (a program), and with
    verbose the directory under the top one (kernel/xv6/), or the tests
    directory itself."""
    parts = path.split("/")
    # languages/ holds a program per language (languages/c/, languages/ml/)
    top = 2 if parts[0] == "languages" and len(parts) > 2 else 1
    prog = "/".join(parts[:top]) + "/"
    if "tests" in parts[:-1]:
        if verbose:
            return "tests", "/".join(parts[:parts.index("tests") + 1]) + "/"
        return "tests", prog
    for group, tops in GROUPS:
        if parts[0] in tops:
            if group == "tiny" and len(parts) == 2:
                return group, path
            if verbose and len(parts) > top + 1:
                return group, "/".join(parts[:top + 1]) + "/"
            return group, prog
    return "other", parts[0] + "/" if len(parts) > 1 else "./"


def files():
    out = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard",
         "--", "*.ml", "*.mli", "*.mll", "*.mly"],
        check=True, capture_output=True, text=True).stdout
    return [f for f in out.splitlines() if f]


# ---------------------------------------------------------------------
# Printing
# ---------------------------------------------------------------------

FIELDS = ["files", "ml", "mli", "mll_mly", "code", "comment", "blank", "lines"]
# the lines first, right beside the name they count, the rest after it
REST = [f for f in FIELDS if f != "lines"]
# 80 columns: the lines (7), 2 spaces, the name, then each cell a
# space wider than its title or its numbers ("37,704"), whichever is
# the longer
WIDTH = 25  # of the name column: "  tiny/TinyBuildSystem.ml" with -v
CELL = {"files": 6, "ml": 5, "mli": 5, "mll_mly": 8, "code": 7,
        "comment": 8, "blank": 7}


def row(name, s, indent=0):
    cells = "".join(f"{s[f]:>{CELL[f]},}" for f in REST)
    print(f"{s['lines']:>7,}  {' ' * indent}{name:<{WIDTH - indent}}{cells}")


def main():
    verbose = "-v" in sys.argv[1:]
    stats = defaultdict(lambda: defaultdict(lambda: defaultdict(int)))
    for path in files():
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                text = f.read()
        except FileNotFoundError:  # deleted, not yet staged
            continue
        code, comment, blank = count(text, path.endswith(".mly"))
        group, sub = classify(path, verbose)
        s = stats[group][sub]
        s["files"] += 1
        s[{"ml": "ml", "mli": "mli"}.get(path.rsplit(".", 1)[1],
                                          "mll_mly")] += 1
        s["code"] += code
        s["comment"] += comment
        s["blank"] += blank
        s["lines"] += code + comment + blank

    def total(subs):
        t = defaultdict(int)
        for s in subs:
            for f in FIELDS:
                t[f] += s[f]
        return t

    print(f"{'lines':>7}  {'':<{WIDTH}}"
          + "".join(f"{f:>{CELL[f]}}" for f in REST))
    order = [g for g, _ in GROUPS] + ["tests", "other"]
    for group in order:
        subs = stats.get(group, {})
        if not subs:
            continue
        # in the order of GROUPS (the toolchain, the machines, the
        # kernel, the programs), not alphabetical
        tops = dict(GROUPS).get(group, [])
        rank = {t: i for i, t in enumerate(tops)}
        for sub in sorted(subs, key=lambda k: (rank.get(k.split("/")[0],
                                                        len(tops)), k)):
            row(sub, subs[sub], 2)
        row(group, total(subs.values()))
        print()
    row("total", total(s for g in stats.values() for s in g.values()))
    row("total without tests",
        total(s for g, subs in stats.items() if g != "tests"
              for s in subs.values()))


if __name__ == "__main__":
    main()
