#!/bin/bash
# Phase 2: tinycc's listings (-S) against 5c -O0's, file by file, over
# goken's libraries and utilities (and the programs given), with each
# file's flags from mk -n.
# usage: listing.sh 5 workdir [prog.c...]
set -u
export PATH=$HOME/goken/bin:$HOME/goken/ROOT/arch/boot-gcc/bin:$PATH
IX=$(cd $(dirname $0)/../.. && pwd)/_build/default
O=$1; W=$2; shift 2
# the programs' paths absolute: the loop below changes directory
[ $# -gt 0 ] && set -- $(realpath "$@")
case $O in 5) OBJ=arm;; 7) OBJ=arm64;; esac
rm -rf $W; mkdir -p $W
same=0; diff=0; fail=0
one() {  # dir flags src
  local b=$(echo $1/${3%.c} | sed "s|$HOME/goken/||" | tr / _)
  # the listing is the lines with a tab; 5c may print it and still fail
  (cd $1 && ${O}c -O0 $2 -S -o /dev/null $3 > $W/$b.out 2>/dev/null) || { echo "${O}c-FAIL $b"; return; }
  grep '^	' $W/$b.out > $W/$b.g
  (cd $1 && $IX/compiler/Main.exe -m $O $2 -S -o $W/$b.$O $3 > $W/$b.t 2>&1) || { echo "FAIL $b: $(tail -1 $W/$b.t)"; fail=$((fail+1)); return; }
  if cmp -s $W/$b.g $W/$b.t; then same=$((same+1)); else echo "DIFF $b $(diff $W/$b.g $W/$b.t | grep -c '^[<>]')"; diff=$((diff+1)); fi
}
for d in lib_core/libc lib_core/libbio lib_strings/libregexp lib_strings/libstring \
         $(cd $HOME/goken && find utilities -name mkfile -printf '%h\n' | sort); do
  cd $HOME/goken/$d
  while read -r line; do
    w=($line)
    [ "${w[0]}" = ${O}c ] && [[ ${w[-1]} = *.c ]] || continue
    flags=$(echo "${w[@]:1:${#w[@]}-2}" | sed -e 's/ *-o [^ ]*//')
    # the mkfile's own CFLAGS_EXTRA (-DUnix...), which mk -n leaves unexpanded
    flags=${flags//\$CFLAGS_EXTRA/$(grep '^CFLAGS_EXTRA=' mkfile | cut -d= -f2-)}
    one $HOME/goken/$d "$flags" ${w[-1]}
  done < <(mk -a -n objtype=$OBJ cputype=$OBJ GOOS=linux 2>/dev/null)
done
for c in "$@"; do
  one $(dirname $c) "-I$HOME/goken/include -I$HOME/goken/include/ALL -I$HOME/goken/include/arch/$OBJ" $(basename $c)
done
echo "same $same, diff $diff, fail $fail"
