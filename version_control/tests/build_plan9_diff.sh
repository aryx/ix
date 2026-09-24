#!/bin/bash
# Claude Code
#
# Copyright (C) 2026 Yoann Padioleau
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Library General Public License
# (LGPL) as published by the Free Software Foundation; either version
# 2 of the License, or (at your option) any later version.
#
# principia's own diff and merge3 (version_control/diff, 9front's), the
# reference for TinyDiff, built for Linux by goken: its libc and libbio
# compiled by 7c, the programs by 7c, linked by 7l -H7 (as
# linker/tests/libc.sh builds goken's C programs). Two changes to a copy
# of the sources, for Linux: REGULAR_FILE without Plan 9's device type
# 'M' (goken's dirstat leaves it 0), and an empty ctype.h (goken's
# libc.h has the macros). goken's runtime fails silently on files of
# more than about 2,500 lines: the tests stay under. (/usr/bin/sed:
# goken's PATH has a Plan 9 sed first.)
#
# Usage: build_plan9_diff.sh WORKDIR   -> WORKDIR/pdiff, WORKDIR/pmerge3
set -eu
W=$1
PRINCIPIA=${PRINCIPIA:-$HOME/github/principia-softwarica}
export PATH=$HOME/goken/bin:$HOME/goken/ROOT/arch/boot-gcc/bin:$HOME/goken/ROOT/arch/arm64/bin:$PATH
if [ -x $W/pdiff ] && [ -x $W/pmerge3 ]; then exit 0; fi
rm -rf $W; mkdir -p $W/libc $W/o $W/inc $W/src
I="-I$HOME/goken/include -I$HOME/goken/include/ALL -I$HOME/goken/include/arch/arm64 -I$W/inc"
cd $HOME/goken/lib_core/libc
while read -r line; do
  set -- $line
  case $1 in
  7c)
    src=${@: -1}; b=$(echo ${src%.c} | tr / _)
    flags=$(echo "$line" | sed -e "s/^7c //" -e 's/ -o [^ ]* [^ ]*$//')
    flags=${flags//\$CFLAGS_EXTRA/$(grep '^CFLAGS_EXTRA=' mkfile | cut -d= -f2-)}
    7c $flags -o $W/libc/$b.7 $src > /dev/null
    ;;
  7a)
    src=${@: -1}; b=$(echo ${src%.s} | tr / _)
    7a -o $W/libc/$b.7 $src > /dev/null
    ;;
  esac
done < <(mk -a -n objtype=arm64 cputype=arm64 GOOS=linux 2>/dev/null)
iar rc $W/libc/libc.a $W/libc/*.7
cd $HOME/goken/lib_core/libbio
for f in *.c; do 7c $I -o $W/o/bio_${f%.c}.7 $f > /dev/null; done
iar rc $W/libc/libbio.a $W/o/bio_*.7
cp $PRINCIPIA/version_control/diff/*.[ch] $W/src/
/usr/bin/sed -i "s/#define REGULAR_FILE(s) .*/#define REGULAR_FILE(s) (!DIRECTORY(s))/" $W/src/diff.h
echo "/* goken's libc.h has the ctype macros */" > $W/inc/ctype.h
cd $W/src
for f in diff diffdir diffio diffreg util merge3; do 7c $I -o $W/o/$f.7 $f.c; done
# 7l from the libraries' directory: the objects name them (#pragma lib)
cd $W/libc
common="$W/o/diffdir.7 $W/o/diffio.7 $W/o/diffreg.7 $W/o/util.7 libbio.a libc.a"
7l -H7 -o $W/pdiff $W/o/diff.7 $common
7l -H7 -o $W/pmerge3 $W/o/merge3.7 $common
