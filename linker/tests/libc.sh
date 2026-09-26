#!/bin/bash
# Milestone 2: goken's libc and C programs, linked by goken and by ix,
# compared byte for byte, then run. For arm (5) and arm64 (7):
#   goken: 5c -o x.5 x.c, 5a, iar, 5l -H7 -s
#   ix:    5c -S x.c > x.s (the same run), mini-asm, mini-ld -a, mini-ld -H7
# usage: libc.sh 5|7 workdir prog.c...   (needs goken, and dune build in ix)
# The libc is built once per workdir: remove it to rebuild.
# GOOS=darwin H=-H6: macOS's libc and Mach-O (compared, not run).
# GOOS=plan9 H=-H2: Plan 9's libc and a.out (compared, not run here:
# machine/tests/plan9.py runs them under 5i and mini-5i).
# MINICC=1: ix's C is compiled by mini-cc into objects, not 5c -S and
# mini-asm (5c -O0 for goken's then, the same code).
set -u
export PATH=$HOME/goken/bin:$HOME/goken/ROOT/arch/boot-gcc/bin:$PATH
IX=$(cd $(dirname $0)/../.. && pwd)/_build/default
LIBC=$HOME/goken/lib_core/libc
O=$1; W=$2; shift 2
case $O in 5) OBJ=arm;; 7) OBJ=arm64;; esac
progs=("$@")
TESTS=$(cd $(dirname $0) && pwd)
if [ ! -f $W/t/libc.a ]; then
rm -rf $W; mkdir -p $W/g $W/t
cd $LIBC
g=(); t=()
while read -r line; do
  set -- $line
  case $1 in
  ${O}c)
    src=${@: -1}; b=$(echo ${src%.c} | tr / _)
    # 5c's flags, but the -o and the file; the listing is the lines
    # with a tab, its warnings go to stdout too
    flags=$(echo "$line" | sed -e "s/^${O}c //" -e 's/ -o [^ ]* [^ ]*$//')
    # the mkfile's own CFLAGS_EXTRA (-DUnix...), which mk -n leaves unexpanded
    flags=${flags//\$CFLAGS_EXTRA/$(grep '^CFLAGS_EXTRA=' mkfile | cut -d= -f2-)}
    if [ -n "${MINICC:-}" ]; then
      ${O}c -O0 $flags -o $W/g/$b.$O $src > /dev/null 2>&1 || echo "${O}c-FAIL $b"
      $IX/languages/c/Main.exe -m $O $flags -o $W/t/$b.$O $src 2> $W/t/$b.err || echo "MINICC-FAIL $b"
    else
    ${O}c $flags -S -o $W/g/$b.$O $src 2>$W/t/$b.err | grep '^	' > $W/t/$b.s || echo "${O}c-FAIL $b"
    $IX/assembler/Main.exe -m $O -o $W/t/$b.$O $W/t/$b.s || echo "MINIASM-FAIL $b"
    fi
    ;;
  ${O}a)
    src=${@: -1}; b=$(echo ${src%.s} | tr / _)
    ${O}a -o $W/g/$b.$O $src >/dev/null || echo "${O}a-FAIL $b"
    $IX/assembler/Main.exe -m $O -o $W/t/$b.$O $src || echo "MINIASM-FAIL $b"
    ;;
  iar)
    shift 3
    for o in "$@"; do b=$(echo $o | tr / _); g+=($W/g/$b); t+=($W/t/$b); done
    ;;
  esac
done < <(mk -a -n objtype=$OBJ cputype=$OBJ GOOS=${GOOS:-linux} 2>/dev/null)
iar rc $W/g/libc.a "${g[@]}"
$IX/linker/Main.exe -m $O -a $W/t/libc.a "${t[@]}"
fi
for c in "${progs[@]}"; do
  b=$(basename $c .c)
  incs="-I$HOME/goken/include -I$HOME/goken/include/ALL -I$HOME/goken/include/arch/$OBJ"
  if [ -n "${MINICC:-}" ]; then
    (cd $(dirname $c) && ${O}c -O0 $incs -o $W/g/$b.$O $b.c > /dev/null 2>&1) || { echo "${O}c-FAIL $b"; continue; }
    (cd $(dirname $c) && $IX/languages/c/Main.exe -m $O $incs -o $W/t/$b.$O $b.c) || { echo "MINICC-FAIL $b"; continue; }
  else
  (cd $(dirname $c) && ${O}c $incs -S -o $W/g/$b.$O $b.c 2>/dev/null | grep '^	' > $W/t/$b.s) || { echo "${O}c-FAIL $b"; continue; }
  $IX/assembler/Main.exe -m $O -o $W/t/$b.$O $W/t/$b.s || { echo "MINIASM-FAIL $b"; continue; }
  fi
  # 5l from libc's directory: 5c's objects name libc.a (#pragma lib)
  (cd $LIBC && ${O}l ${H:--H7} -s -o $W/g/$b.exe $W/g/$b.$O $W/g/libc.a) > $W/g/$b.log 2>&1 || { echo "${O}l-FAIL $b: $(head -1 $W/g/$b.log)"; continue; }
  $IX/linker/Main.exe -m $O ${H:--H7} -o $W/t/$b.exe $W/t/$b.$O $W/t/libc.a 2> $W/t/$b.log || { echo "MINILD-FAIL $b: $(head -1 $W/t/$b.log)"; continue; }
  # the same bytes, and the same output
  if [ "${H:--H7}" = -H6 ] || [ "${H:--H7}" = -H2 ]; then
    if cmp -s $W/g/$b.exe $W/t/$b.exe; then echo "$b: SAME"; else echo "$b: DIFF $(cmp $W/g/$b.exe $W/t/$b.exe | head -1)"; fi
    continue
  fi
  same=$(python3 $TESTS/elfcmp.py $W/g/$b.exe $W/t/$b.exe)
  (mkdir -p $W/run && cd $W/run && timeout 10 $W/g/$b.exe one two > $W/g/$b.out 2>&1; echo "exit $?" >> $W/g/$b.out)
  (mkdir -p $W/run && cd $W/run && timeout 10 $W/t/$b.exe one two > $W/t/$b.out 2>&1; echo "exit $?" >> $W/t/$b.out)
  if cmp -s $W/g/$b.out $W/t/$b.out; then run="runs the same ($(tail -1 $W/t/$b.out))"; else run="RUNS DIFFERENTLY"; fi
  echo "$b: $same; $run"
done
