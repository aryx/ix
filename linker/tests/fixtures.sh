#!/bin/bash
# Milestone 1: each .s assembled and linked by goken (5a -r, 5l -H7 -s,
# or 7a and 7l) and by ix (mini-asm, mini-ld), the executables compared.
# usage: fixtures.sh 5|7 workdir file.s...   (H=-H2 for Plan 9's a.out;
# E=entry, default _start)
export PATH=$HOME/goken/bin:$HOME/goken/ROOT/arch/boot-gcc/bin:$PATH
IX=$(cd $(dirname $0)/../.. && pwd)/_build/default
O=$1; W=$2; shift 2
for f in "$@"; do
  b=$(basename $f .s); d=$W/$b
  rm -rf $d; mkdir -p $d; cp $f $d/
  (cd $d && ${O}a -r $b.s >/dev/null 2>&1) || { echo "${O}a-FAIL $b"; continue; }
  (cd $d && ${O}l ${H:--H7} -s -E ${E:-_start} -o g.exe $b.$O >g.log 2>&1) || { echo "${O}l-FAIL $b: $(head -1 $d/g.log)"; continue; }
  { $IX/assembler/Main.exe -m $O -o $d/t.$O $f && timeout 10 $IX/linker/Main.exe -m $O ${H:--H7} -E ${E:-_start} -o $d/t.exe $d/t.$O; } 2>$d/t.log || { echo "MINI-FAIL $b: $(head -1 $d/t.log)"; continue; }
  if cmp -s $d/g.exe $d/t.exe; then echo "SAME $b"; else echo "DIFF $b: $(cmp $d/g.exe $d/t.exe | head -1)"; fi
done
