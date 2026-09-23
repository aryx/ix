#!/bin/bash
# Milestone 2 on arm: goken's libc and C programs, linked by goken and by
# ix, compared byte for byte, then run.
#   goken: 5c -o x.5 x.c, 5a, iar, 5l -H7 -s
#   ix:    5c -S x.c > x.s (the same run), tinyasm, tinyld -a, tinyld -H7
# usage: libc5.sh workdir prog.c...   (needs goken, and dune build in ix)
# The libc is built once per workdir: remove it to rebuild.
set -u
export PATH=$HOME/goken/bin:$HOME/goken/ROOT/arch/boot-gcc/bin:$PATH
IX=$(cd $(dirname $0)/../.. && pwd)/_build/default
LIBC=$HOME/goken/lib_core/libc
W=$1; shift
progs=("$@")
TESTS=$(cd $(dirname $0) && pwd)
if [ ! -f $W/t/libc.a ]; then
rm -rf $W; mkdir -p $W/g $W/t
cd $LIBC
g=(); t=()
while read -r line; do
  set -- $line
  case $1 in
  5c)
    src=${@: -1}; b=$(echo ${src%.c} | tr / _)
    # 5c's flags, but the -o and the file; the listing is the lines
    # with a tab, its warnings go to stdout too
    flags=$(echo "$line" | sed -e 's/^5c //' -e 's/ -o [^ ]* [^ ]*$//' -e 's/\$CFLAGS_EXTRA//')
    5c $flags -S -o $W/g/$b.5 $src 2>$W/t/$b.err | grep '^	' > $W/t/$b.s || echo "5c-FAIL $b"
    $IX/assembler/Main.exe -m 5 -o $W/t/$b.5 $W/t/$b.s || echo "TINYASM-FAIL $b"
    ;;
  5a)
    src=${@: -1}; b=$(echo ${src%.s} | tr / _)
    5a -o $W/g/$b.5 $src >/dev/null || echo "5a-FAIL $b"
    $IX/assembler/Main.exe -m 5 -o $W/t/$b.5 $src || echo "TINYASM-FAIL $b"
    ;;
  iar)
    shift 3
    for o in "$@"; do b=$(echo $o | tr / _); g+=($W/g/$b); t+=($W/t/$b); done
    ;;
  esac
done < <(mk -a -n objtype=arm cputype=arm 2>/dev/null)
iar rc $W/g/libc.a "${g[@]}"
$IX/linker/Main.exe -m 5 -a $W/t/libc.a "${t[@]}"
fi
for c in "${progs[@]}"; do
  b=$(basename $c .c)
  (cd $(dirname $c) && 5c -I$HOME/goken/include -I$HOME/goken/include/ALL -I$HOME/goken/include/arch/arm -S -o $W/g/$b.5 $b.c 2>/dev/null | grep '^	' > $W/t/$b.s) || { echo "5c-FAIL $b"; continue; }
  $IX/assembler/Main.exe -m 5 -o $W/t/$b.5 $W/t/$b.s || { echo "TINYASM-FAIL $b"; continue; }
  # 5l from libc's directory: 5c's objects name libc.a (#pragma lib)
  (cd $LIBC && 5l -H7 -s -o $W/g/$b.exe $W/g/$b.5 $W/g/libc.a) > $W/g/$b.log 2>&1 || { echo "5l-FAIL $b: $(head -1 $W/g/$b.log)"; continue; }
  $IX/linker/Main.exe -m 5 -H7 -o $W/t/$b.exe $W/t/$b.5 $W/t/libc.a 2> $W/t/$b.log || { echo "TINYLD-FAIL $b: $(head -1 $W/t/$b.log)"; continue; }
  # the same bytes, and the same output
  same=$(python3 $TESTS/elfcmp.py $W/g/$b.exe $W/t/$b.exe)
  (mkdir -p $W/run && cd $W/run && timeout 10 $W/g/$b.exe one two > $W/g/$b.out 2>&1; echo "exit $?" >> $W/g/$b.out)
  (mkdir -p $W/run && cd $W/run && timeout 10 $W/t/$b.exe one two > $W/t/$b.out 2>&1; echo "exit $?" >> $W/t/$b.out)
  if cmp -s $W/g/$b.out $W/t/$b.out; then run="runs the same ($(tail -1 $W/t/$b.out))"; else run="RUNS DIFFERENTLY"; fi
  echo "$b: $same; $run"
done
