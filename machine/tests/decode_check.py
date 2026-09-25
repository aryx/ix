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
# Phase 1's test: every word of the corpus (words_arm.txt, from
# census.py) decoded and printed by mini-5i's Arm32 and by binutils'
# objdump, the texts equal (objdump's "@ ..." comments dropped).
#
# With --random N [seed]: N random words instead, cond not 1111, from
# the classes the decoder claims (data processing, multiplies,
# transfers, blocks, branches, svc, the VFP); a word decoded must print as
# objdump prints it; one decoded as .word (Undefined) is counted, not
# failed: unimplemented, not wrong.
#
# And, when node is installed, the same printing compiled by
# js_of_ocaml (Disasm.bc.js), identical to the native one: the web
# target's 32-bit ints (plan_arm.md, decision 3).
#
# With -64 first: arm64's decoder (Arm64), against objdump -m aarch64,
# on words_arm64.txt or random words of the A64 classes decoded (data
# processing, branches, loads and stores; SIMD and floating point
# excluded).
#
# Usage: decode_check.py [-64] [words file]
#        decode_check.py [-64] --random N [seed]

import atexit, os, random, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "../..")
tmp = tempfile.mkdtemp()
atexit.register(shutil.rmtree, tmp)
a64 = len(sys.argv) > 1 and sys.argv[1] == "-64"
argv = [sys.argv[0]] + sys.argv[2:] if a64 else sys.argv
randomized = len(argv) > 1 and argv[1] == "--random"
if randomized:
    n = int(argv[2]); r = random.Random(int(argv[3]) if len(argv) > 3 else 1)
    def word64():
        # bits 28-25: 100x immediates, 101x branches, x100 loads and
        # stores (bit 26 clear: not SIMD, some of whose random words
        # crash objdump 2.42), x101 registers
        top = r.choice([0b1000, 0b1001, 0b1010, 0b1011, 0b0100, 0b1100, 0b0101, 0b1101])
        w = r.getrandbits(32) & ~(0xf << 25) | top << 25
        return "%08x" % w
    def word32():
        cond = r.randrange(15) << 28
        k = r.random()
        if k < 0.35: body = r.randrange(1 << 25)                          # class 000
        elif k < 0.5: body = (1 << 25) | r.randrange(1 << 25)            # 001
        elif k < 0.7: body = (2 << 25) | r.randrange(1 << 25)            # 010
        elif k < 0.77: body = (3 << 25) | (r.randrange(1 << 25) & ~0x10) # 011, bit 4 clear
        elif k < 0.79: body = (0xd << 23) | (r.randrange(1 << 23) & ~0x3f0) | 0x70   # the extends. space
        elif k < 0.795: body = (0x6b << 20) | (r.randrange(2) << 22) | 0xf0f00 | (r.randrange(16) << 4) | (r.randrange(1 << 16) & 0xf00f)   # rev
        elif k < 0.8: body = (2 << 23) | (r.randrange(4) << 21) | (r.randrange(1 << 16) << 4 & 0xfff00) | 0x80 | (r.randrange(4) << 5) | r.randrange(16)   # smla..
        elif k < 0.88: body = (4 << 25) | r.randrange(1 << 25)           # 100
        elif k < 0.96: body = (5 << 25) | r.randrange(1 << 25)           # 101
        elif k < 0.98: body = (0xf << 24) | r.randrange(1 << 24)         # svc
        elif k < 0.985: body = (0xe << 24) | r.randrange(1 << 24) | 0x10 # mcr, mrc
        # the VFP (coprocessors 10, 11): data processing and core moves;
        # loads, stores, transfers
        elif k < 0.995: body = (0xe << 24) | (r.randrange(1 << 24) & ~0xe00) | 0xa00
        else: body = (6 << 25) | (r.randrange(1 << 25) & ~0xe00) | 0xa00
        return "%08x" % (cond | body)
    words = [(word64 if a64 else word32)() for _ in range(n)]
    words_file = os.path.join(tmp, "words.txt")
    open(words_file, "w").write("\n".join(words) + "\n")
else:
    words_file = argv[1] if len(argv) > 1 else os.path.join(HERE, "words_arm64.txt" if a64 else "words_arm.txt")
    words = [l.strip() for l in open(words_file) if l.strip()]
binf = os.path.join(tmp, "w.bin")
open(binf, "wb").write(b"".join(int(w, 16).to_bytes(4, "little") for w in words))
dis = subprocess.run(["objdump", "-D", "-b", "binary", "-m", "aarch64" if a64 else "arm", binf], capture_output=True, text=True).stdout
want = {}
for line in dis.splitlines():
    parts = line.split("\t")
    if len(parts) >= 3 and parts[0].strip().endswith(":"):
        addr = int(parts[0].strip()[:-1], 16)
        text = "\t".join(p for p in parts[2:])
        text = (text.split("//")[0] if a64 else text.split("@")[0]).split(";")[0].rstrip()
        # objdump's undefined arm64 words, as ".inst": its text empty
        if text.startswith(".inst"): text = ""
        # a comment objdump separates with spaces, not a tab
        text = text.rstrip()
        want[addr] = text
# every word disassembled by both, or the comparison proves nothing
if len(want) != len(words): print("FAIL: objdump printed %d of %d words" % (len(want), len(words))); sys.exit(1)
got = {}
flag = ["-64"] if a64 else []
out = subprocess.run([os.path.join(ROOT, "_build/default/machine/tests/Disasm.exe")] + flag + [words_file], capture_output=True, text=True).stdout
for line in out.splitlines():
    a, _, text = line.partition("\t")
    got[int(a, 16)] = text.rstrip()
undefined = [a for a in sorted(want) if randomized and got.get(a, "").startswith((".word", ".inst"))]
# objdump's own undefined or unpredictable encodings (its text empty
# once the "; <UNDEFINED>" comment is dropped): not ours to match
theirs = [a for a in sorted(want) if randomized and want[a] == "" and a not in undefined]
bad = [(a, words[a // 4]) for a in sorted(want) if got.get(a) != want[a] and a not in undefined and a not in theirs]
js = os.path.join(ROOT, "_build/default/machine/tests/Disasm.bc.js")
if shutil.which("node") and os.path.exists(js):
    js_out = subprocess.run(["node", js] + flag + [words_file], capture_output=True, text=True).stdout
    if js_out != out:
        print("FAIL: js_of_ocaml's printing differs from the native one")
        bad.append((0, "js"))
for a, w in bad[:40]:
    print("%s  objdump: %-36s ours: %s" % (w, want[a], got.get(a)))
print("decode_check: %d words, %d differ%s" % (len(words), len(bad),
      ", %d left undefined (objdump: %d of them instructions), %d objdump's undefined" % (len(undefined), sum(1 for a in undefined if want[a] != ""), len(theirs)) if randomized else ""))
if randomized:
    import collections
    names = collections.Counter(want[a].split("\t")[0] for a in undefined if want[a] != "")
    print("  undefined here, by objdump's name:", " ".join("%s(%d)" % kv for kv in names.most_common(30)))
sys.exit(1 if bad else 0)
