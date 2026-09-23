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
# A fuzzer for TinyEd: random files and random scripts (every command,
# the whole regexp notation), through 9base's ed and tinyed, which must
# print and leave the same. It found what the corpus missed (plan_ed.md,
# Status). From the root, after dune build:
#
#   editor/tests/fuzz.py [seed] [count]
import random, subprocess, sys, os, tempfile
ED="/usr/lib/plan9/bin/ed"; T=os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../_build/default/editor/Main.exe")
R=random.Random(int(sys.argv[1]) if len(sys.argv)>1 else 0)
alpha="abc x"
def word(): return "".join(R.choice("abcx") for _ in range(R.randint(0,4)))
def regex(d=0):
    k=R.randint(0,12)
    if d>2 or k<4: return R.choice(["a","b","c","x",".","ab","^","$","[ab]","[^a]","\\.",""])
    if k<6: return regex(d+1)+regex(d+1)
    if k<8: return "("+regex(d+1)+")"+R.choice(["","*","+","?"])
    if k<10: return regex(d+1)+"|"+regex(d+1)
    return regex(d+1)+R.choice(["*","+","?"])
def addr():
    k=R.randint(0,14)
    if k<3: return ""
    if k<5: return str(R.randint(0,7))
    if k==5: return "$"
    if k==6: return "."
    if k==7: return "/"+regex()+"/"
    if k==8: return "?"+regex()+"?"
    if k==9: return R.choice(["+","-","++","-2","+1","^"])
    if k==10: return "'"+R.choice("ab")
    if k==11: return addr()+R.choice(["+","-"])+str(R.randint(0,2))
    return str(R.randint(1,5))
def rng():
    k=R.randint(0,5)
    if k<2: return addr()
    if k<4: return addr()+","+addr()
    if k==4: return addr()+";"+addr()
    return ","
def rhs():
    return "".join(R.choice(["a","&","\\1","\\2","-","\\&","\\\n",""]) for _ in range(R.randint(0,3)))
def suffix(): return R.choice(["","","","p","l","n"])
def cmd(ing=False):
    k=R.randint(0,20)
    if k<3: return rng()+R.choice("pnl=")+"\n"
    if k==3: return rng()+"d"+suffix()+"\n"
    if k==4: return rng()+R.choice("ai")+"\n"+"".join(word()+"\n" for _ in range(R.randint(0,2)))+".\n"
    if k==5: return rng()+"c\n"+"".join(word()+"\n" for _ in range(R.randint(0,2)))+".\n"
    if k<=8: return rng()+"s"+R.choice(["","2"])+"/"+regex()+"/"+rhs()+R.choice(["/","/g","/p","/gp",""])+"\n"
    if k==9 and not ing: return rng()+R.choice("gv")+"/"+regex()+"/"+cmd(True).rstrip("\n").replace("\n","\\\n")+"\n"
    if k==10: return rng()+R.choice("mt")+addr()+"\n"
    if k==11: return rng()+"j"+suffix()+"\n"
    if k==12: return rng()+"k"+R.choice("ab")+"\n"
    if k==13: return rng()+"u\n"
    if k==14: return "\n"
    if k==15: return rng()+"b"+R.choice(["","2","-1","+3"])+"\n"
    return rng()+"p\n"
def run(prog, script, text, d):
    open(os.path.join(d,"f"),"w").write(text)
    p=subprocess.run(["timeout","-s","KILL","5",prog,"-","f"],input=script.encode(),capture_output=True,cwd=d)
    return p.stdout+b"[exit %d]"%p.returncode+open(os.path.join(d,"f"),"rb").read()
bad=0
for i in range(int(sys.argv[2]) if len(sys.argv)>2 else 200):
    text="".join(word()+"\n" for _ in range(R.randint(0,6)))
    script="".join(cmd() for _ in range(R.randint(1,8)))+",p\nw\nQ\n"
    with tempfile.TemporaryDirectory() as d1, tempfile.TemporaryDirectory() as d2:
        a=run(ED,script,text,d1); b=run(T,script,text,d2)
    if a!=b:
        bad+=1
        if bad<=5:
            print("=== case",i); print("--- text"); print(text,end=""); print("--- script"); print(script,end="")
            print("--- ed"); print(a.decode(errors="replace")); print("--- tinyed"); print(b.decode(errors="replace"))
print("mismatches:",bad)
