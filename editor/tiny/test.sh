#!/bin/sh
# Claude Code
#
# Copyright (C) 2026 Yoann Padioleau
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Library General Public License
# (LGPL) as published by the Free Software Foundation; either version
# 2 of the License, or (at your option) any later version.
#
# The tests of TinyEditor.ml: each script of sam's command language
# runs on the same file through tinyeditor and through 9base's sam -d,
# in a fresh directory; what they print (stdout and stderr, the exit
# status, and the file after) must be the same. 9base's sam prints its
# numbers with a stray "d" (#4d for #4: plan9port's %lud), taken out.

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TE=${TE:-$ROOT/_build/default/editor/tiny/TinyEditor.exe}
SAM=${SAM:-/usr/lib/plan9/bin/sam}
failures=0

TEXT='one
two
three
four
'

run() {
  prog=$1 script=$2
  dir=$(mktemp -d)
  (cd "$dir" && printf '%s' "$TEXT" > f && printf '%s\n' "$script" > script &&
   if [ "$prog" = "$SAM" ]; then timeout -s KILL 5 "$prog" -d f < script 2>&1; else timeout -s KILL 5 "$prog" f < script 2>&1; fi
   echo "[exit $?]"; echo "--- f"; cat f) |
    sed -e 's/\([0-9]\)d\([,;]\)/\1\2/g' -e 's/\(#[0-9][0-9]*\)d/\1/g'
  rm -rf "$dir"
}

# same NAME SCRIPT: tinyeditor prints what sam -d prints
same() {
  expected=$(run "$SAM" "$2") actual=$(run "$TE" "$2")
  if [ "$expected" = "$actual" ]; then echo "ok   $1"
  else echo "FAIL $1"; echo "--- sam"; echo "$expected"; echo "--- tinyeditor"; echo "$actual"
       failures=$((failures + 1)); fi
}

same "print lines" '2p
,p
$p
0p
3,4p'
same "print characters" '#0,#3p
#4,#8p
#8p
$-1p'
same "positions" '2
=
=#
,=
#3,#5=
/t/=
$=
0='
same "searches wrap" '/o/p
/o/p
/o/p
?t?p
?t?p
/zz/p'
same "relative addresses" '2+p
2-p
3-2p
+
-
1+/o/p
$-/t/p'
same "compound addresses" '2,3p
2;+1p
,2p
3,p
/two/,/four/p
/t/;/e/p
3,2p'
same "change and print" '2c/TWO/
,p
1d
,p
$a/five\n/
,p
0i/zero\n/
,p
w
q'
same "text on lines" '2a
new line
another
.
,p
w
q'
same "s" '1s/o/0/
2s/t/T/g
3s2/e/E/
,p
,s/(o)(u)/\2\1/
4p
,s/x/y/
w
q'
same "s with & and newlines" '1s/one/<&>/
2s/w/\n/
,p
w
q'
same "x" ',x/o/c/0/
,p
,x/e+/c/-/
,p
w
q'
same "x and y" ',x/t.*/p
,y/\n/p
,x/o/{
i/[/
a/]/
}
,p
w
q'
same "x without a pattern: lines" ',x p
,x g/t/p
w
q'
same "g and v" ',x/.*\n/g/t/p
,x/.*\n/v/t/d
,p
w
q'
same "nested loops" ',x/.*\n/g/o/x/o/c/O/
,p
w
q'
same "changes not in sequence" ',x/o/{
d
c/X/
}
,p'
same "m and t" '1m$
,p
1t0
,p
w
q'
same "files" 'w out
r out
,p
f
e f
,p
w
q'
same "errors" 'zz
/nomatch/
9
#100
,x/(/p
1,2,3p
s/x/y/
p'
same "q twice" '1d
q
q'
same "newline steps" '1
+
.p'
same "matching" '1s/o|on/X/
,p
,x/o\nt/c/-/
,p
,x/^t/c/T/
,x/e$/c/E/
,p
w
q'
same "empty matches" ',x/x*/c/-/
,p
,s/y*/+/g
,p
w
q'
# no character classes: 9base's sam matches only the ends of a range
# ([a-c] is a or c) and lets [^ab] match a newline, against sam(1)
same "groups" ',s/(t)(w|h)/\2\1/g
,p
,x/(o|e)+/c/<&>/
,p
w
q'

[ $failures -eq 0 ] && echo "all passed" || { echo "$failures failed"; exit 1; }
