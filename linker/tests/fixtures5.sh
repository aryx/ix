#!/bin/bash
# Milestone 1 on arm: each .s assembled and linked by goken (5a -r, 5l
# -H7 -s) and by ix (tinyasm, tinyld), the executables compared.
# usage: fixtures5.sh workdir file.s...   (H=-H2 for Plan 9's a.out;
# E=entry, default _start)
export PATH=$HOME/goken/bin:$HOME/goken/ROOT/arch/boot-gcc/bin:$PATH
IX=$(cd $(dirname $0)/../.. && pwd)/_build/default
W=$1; shift
for f in "$@"; do
  b=$(basename $f .s); d=$W/$b
  rm -rf $d; mkdir -p $d; cp $f $d/
  (cd $d && 5a -r $b.s >/dev/null 2>&1) || { echo "5a-FAIL $b"; continue; }
  (cd $d && 5l ${H:--H7} -s -E ${E:-_start} -o g.exe $b.5 >g.log 2>&1) || { echo "5l-FAIL $b: $(head -1 $d/g.log)"; continue; }
  { $IX/assembler/Main.exe -m 5 -o $d/t.5 $f && timeout 10 $IX/linker/Main.exe -m 5 ${H:--H7} -E ${E:-_start} -o $d/t.exe $d/t.5; } 2>$d/t.log || { echo "TINY-FAIL $b: $(head -1 $d/t.log)"; continue; }
  if cmp -s $d/g.exe $d/t.exe; then echo "SAME $b"; else echo "DIFF $b: $(cmp $d/g.exe $d/t.exe | head -1)"; fi
done
