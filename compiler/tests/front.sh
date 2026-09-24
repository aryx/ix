#!/bin/bash
# Phase 1: the front end's trees (-x) against goken's cck, file by file,
# over goken's libraries and utilities (and the programs given), with each file's flags
# from mk -n, through strip_x.py.
# usage: front.sh 5|7 workdir [prog.c...]
set -u
export PATH=$HOME/goken/bin:$HOME/goken/ROOT/arch/boot-gcc/bin:$PATH
IX=$(cd $(dirname $0)/../.. && pwd)/_build/default
TESTS=$(cd $(dirname $0) && pwd)
O=$1; W=$2; shift 2
case $O in 5) OBJ=arm; CC=5ck;; 7) OBJ=arm64; CC=7c;; esac
rm -rf $W; mkdir -p $W
strip() { python3 $TESTS/strip_x.py "$1" > "$1.n"; }
same=0; diff=0; fail=0
one() {  # dir flags src
  local b=$(echo $1/${3%.c} | sed "s|$HOME/goken/||" | tr / _)
  (cd $1 && $CC $2 -x -o /dev/null $3 > $W/$b.g 2>&1) || { echo "$CC-FAIL $b"; return; }
  (cd $1 && $IX/compiler/Main.exe -m $O $2 -x -o /dev/null $3 > $W/$b.t 2>&1) || { echo "FAIL $b: $(tail -1 $W/$b.t)"; fail=$((fail+1)); return; }
  strip $W/$b.g; strip $W/$b.t
  if cmp -s $W/$b.g.n $W/$b.t.n; then same=$((same+1)); else echo "DIFF $b"; diff=$((diff+1)); fi
}
# each directory of the corpus with a mkfile, with its flags from mk -n
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
