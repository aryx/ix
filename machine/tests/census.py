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
# The instruction census behind plan_arm.md: which instructions the
# corpus executes. Each program runs under qemu-arm or qemu-aarch64
# with -d in_asm (every block of code run, logged once, as raw words:
# this qemu has no disassembler); the distinct words are disassembled
# by binutils' objdump and counted by mnemonic, and by form (the
# operands' shapes: register, immediate, shifted, pre/post-indexed).
#
# Usage: census.py [--words FILE] 5|7 program...
#        census.py --logs 5|7 qemu-log...   (logs of a whole system's
#        boot, qemu-system-* -d in_asm: kernel and user code alike)

import collections, os, re, subprocess, sys, tempfile

logs_only = sys.argv[1] == "--logs"
if logs_only: sys.argv.pop(1)
# --words FILE: the distinct words run, one a line, as 8 hex digits of
# the 32-bit value (the decoder test's corpus, words_arm*.txt)
words_file = None
if sys.argv[1] == "--words":
    words_file = sys.argv[2]; del sys.argv[1:3]
arch, progs = sys.argv[1], sys.argv[2:]
qemu = {"5": "qemu-arm", "7": "qemu-aarch64"}[arch]
objdump = {"5": ["objdump", "-m", "arm"], "7": ["objdump", "-m", "aarch64"]}[arch]
words = collections.Counter()   # word -> in how many programs
syscalls = collections.Counter()
tmp = tempfile.mkdtemp()
for p in progs:
    log = p if logs_only else os.path.join(tmp, "log")
    if not logs_only:
        subprocess.run([qemu, "-d", "in_asm", "-D", log, p, "one", "two"], cwd=tmp, stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
    seen = set()
    for line in open(log):
        if line.startswith("OBJD-T: "):
            hx = line[8:].strip()
            for i in range(0, len(hx), 8): seen.add(hx[i:i + 8])
    for w in seen: words[w] += 1
    if logs_only: continue
    st = subprocess.run(["strace", "-f", "-qq", "-e", "trace=all", "-o", os.path.join(tmp, "st"), p, "one", "two"],
                        cwd=tmp, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
    for line in open(os.path.join(tmp, "st")):
        m = re.match(r"(?:\d+\s+)?(\w+)\(", line)
        if m: syscalls[m.group(1)] += 1
if words_file:
    with open(words_file, "w") as f:
        for w in sorted(words, key=lambda w: bytes.fromhex(w)[::-1]):
            f.write(bytes.fromhex(w)[::-1].hex() + "\n")
binf = os.path.join(tmp, "w.bin")
with open(binf, "wb") as f:
    for w in words: f.write(bytes.fromhex(w))
dis = subprocess.run(objdump + ["-D", "-b", "binary", binf], capture_output=True, text=True).stdout
mnem = collections.Counter(); forms = collections.Counter()
for line in dis.splitlines():
    m = re.match(r"\s+[0-9a-f]+:\s+[0-9a-f]{8}\s+(\S+)\s*(.*)", line)
    if not m: continue
    op, args = m.group(1), m.group(2).split(";")[0].split("@")[0].strip()
    mnem[op] += 1
    shape = re.sub(r"#-?(0x)?[0-9a-f]+", "#i", args)
    shape = re.sub(r"\b[rwx]\d+\b|\b(sp|lr|pc|fp|ip|sl|xzr|wzr)\b", "r", shape)
    shape = re.sub(r"\{[^}]*\}", "{..}", shape)
    forms[op + " " + shape] += 1
print("%s: %d programs, %d distinct instruction words, %d mnemonics" % (qemu, len(progs), len(words), len(mnem)))
print("mnemonics:", " ".join("%s(%d)" % kv for kv in mnem.most_common()))
print("forms (%d):" % len(forms))
for f, n in forms.most_common(): print("  %4d  %s" % (n, f))
print("system calls (native, strace):", " ".join("%s(%d)" % kv for kv in syscalls.most_common()))
