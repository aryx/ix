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
# The counts behind plan_asm.md's subset: compiles goken's C libraries
# (libc port/fmt/utf/math, libbio, libregexp, libstring) with 5c -S or
# 7c -S, and tallies each opcode and each (opcode, operand shapes) pair,
# registers and constants normalized, with cumulative percentages.
#
#   . ~/goken/env.sh; assembler/tests/count_opcodes.py arm 5 > arm.txt
#   . ~/goken/env.sh; assembler/tests/count_opcodes.py arm64 7 > arm64.txt
import sys, re, subprocess, os, glob, collections
G=os.path.expanduser("~/goken")
arch, n = sys.argv[1], sys.argv[2]
srcs=[]
for d in ["lib_core/libc/port","lib_core/libc/fmt","lib_core/libc/utf","lib_core/libc/math","lib_core/libbio","lib_strings/libregexp","lib_strings/libstring"]:
    srcs += sorted(glob.glob(os.path.join(G,d,"*.c")))
ops=collections.Counter(); forms=collections.Counter(); files=0; insts=0
def norm(a):
    a=a.strip()
    a=re.sub(r'\$-?\d+','$c',a)
    a=re.sub(r'\$"[^"]*"','$str',a)
    a=re.sub(r'\$[0-9.e+-]+','$f',a)
    a=re.sub(r'\b[A-Za-z_.][\w.<>]*(\+|-)?\d*\(SB\)','sym(SB)',a)
    a=re.sub(r'\$sym\(SB\)','$sym(SB)',a)
    a=re.sub(r'\b\w*[+-]?\d+\((FP|SP)\)',r'o(\1)',a)
    a=re.sub(r'-?\d+\(R\d+\)','o(R)',a)
    a=re.sub(r'\(R\d+\)\(R\d+\)','(R)(R)',a)
    a=re.sub(r'\bR\d+\b','R',a); a=re.sub(r'\bF\d+\b','F',a)
    a=re.sub(r'-?\d+\(PC\)','o(PC)',a)
    a=re.sub(r'\(R\)','o(R)',a) if a=='(R)' else a
    return a
for f in srcs:
    p=subprocess.run([n+"c","-S","-I"+G+"/include","-I"+G+"/include/ALL","-I"+G+"/include/arch/"+arch,"-I"+os.path.dirname(f),"-D"+arch,"-Dlinux",f],capture_output=True,text=True,cwd="/tmp")
    if p.returncode!=0: continue
    files+=1
    for line in p.stdout.splitlines():
        m=re.match(r'\s+([A-Z][A-Z0-9.]*)\s*(.*)',line)
        if not m: continue
        op=m.group(1); args=m.group(2)
        if op in ("TEXT","GLOBL","DATA","END","NOP"): ops[op]+=1; continue
        insts+=1; ops[op]+=1
        base=op.split('.')[0]
        forms[(base, ",".join(norm(x) for x in re.split(r',(?![^()]*\))',args) if x))]+=1
print(f"# {arch}: {files}/{len(srcs)} files compiled, {insts} instructions")
tot=sum(v for k,v in ops.items() if k not in ("TEXT","GLOBL","DATA","END","NOP"))
cum=0
for op,c in ops.most_common():
    if op in ("TEXT","GLOBL","DATA","END","NOP"): continue
    cum+=c
    print(f"{op:10} {c:6} {100*cum/tot:6.2f}%")
print("## forms")
tf=sum(forms.values()); cum=0
for i,((op,fm),c) in enumerate(forms.most_common()):
    cum+=c
    print(f"{i+1:4} {op:8} {fm:40} {c} {100*cum/tf:.1f}%")
