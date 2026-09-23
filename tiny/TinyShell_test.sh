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
# The tests of TinyShell.ml: each script, of the subset it keeps, runs
# through tinyshell and through 9base's rc in a fresh directory; what
# they print (stdout, stderr, and the exit status) must be the same.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TS=${TS:-$ROOT/_build/default/tiny/TinyShell.exe}
RC=${RC:-/usr/lib/plan9/bin/rc}
failures=0

run() {
  prog=$1 script=$2
  dir=$(mktemp -d)
  (cd "$dir" && printf "%s\n" "$script" > script &&
   env -i PATH=/usr/bin:/bin HOME="$dir" "$prog" ./script a1 'a 2' 2>&1; echo "[exit $?]") |
    sed 's/^rc ([^)]*): /tinyshell: /'   # the one name that differs
  rm -rf "$dir"
}

# same NAME SCRIPT: tinyshell prints what rc prints
same() {
  expected=$(run "$RC" "$2") actual=$(run "$TS" "$2")
  if [ "$expected" = "$actual" ]; then echo "ok   $1"
  else echo "FAIL $1"; echo "--- rc"; echo "$expected"; echo "--- tinyshell"; echo "$actual"
       failures=$((failures + 1)); fi
}

same "words and quotes" "echo a   b 'c  d' 'it''s' ''
echo 'a
b'"
same "lists" 'x=(a b c); echo $x $#x; y=(); echo $#y; z=one; echo $#z'
same "arguments" 'echo $#* $1; echo $2; echo $*; shift; echo $*; shift 5; echo $#*'
same "concatenation" 'x=(a b c); echo $x.o pre$x a^b pre^$x^.c
y=(1 2 3); echo $x$y; echo $x^-^$y'
same "concatenation errors" 'x=(a b); y=(1 2 3); echo $x$y'
same "an empty list joined" 'echo x$nothing'
same "globs" "touch a.c b.c c.h .hidden; mkdir d; touch d/e.c
echo *.c; echo *.[ch]; echo ?.c; echo [~a].c; echo nomatch* *; echo d/*.c */*.c
echo '*.c'; x='*.c'; echo \$x"
same "redirections" 'echo one > f; echo two >> f; cat < f; cat f >[2] err; wc -l < f
echo out >[1=2] >[2]/dev/null; ls nonexistent >[2] e; cat e | wc -l
{ echo a; echo b >[1=2] } > g >[2=1]; cat g'
same "a pipe" 'echo hello | tr a-z A-Z | sed s/L/l/g; printf "x\ny\n" | sort -r | head -1'
same "statuses" "false; echo \$status; true; echo \$status; true | false; echo \$status
sh -c 'exit 3'; echo \$status; ! true; echo \$status; ! false; echo \$status"
same "and, or" 'true && echo t1; false && echo f1; false || echo f2; true || echo t2
test -f nope && echo yes || echo no'
same "if, while" 'if(true) echo yes; if(false) echo no
x=(a b c); while(! ~ $#x 0) { echo $x; x=() }
i=(); while(! ~ $#i 3) { i=($i 1); echo $#i }'
same "for" 'for(i in 1 2 3) echo $i; for(f) echo arg $f; for(i in) echo never'
same "braces and subshells" '{ echo a; echo b } | wc -l; x=1; @{ x=2; cd /; echo $x }; echo $x; pwd | grep -c /tmp'
same "functions" 'fn f { echo f: $#* $*; }; f a b; f; fn g { f in g $1 }; g x y
fn h { test $1 -eq 1 }; h 2; echo $status; h 1; echo $status'
same "backquote" 'x=`{echo a b; echo c}; echo $#x $x; for(w in `{echo 1 2}) echo $w
y=`{false}; echo $status $#y'
same "match" "~ abc a*; echo \$status; ~ abc x* y*; echo \$status; x=(a b); ~ \$x b && echo some
~ a.c '*.c' || echo quoted; ~ '*' '*' && echo lit; ~ \$#nothing 0 && echo empty"
same "local assignment" "x=old; x=new sh -c 'echo \$x'; echo \$x; y=a z=b env | grep -c '^[yz]='"
same "background" 'sleep 0.1 && echo later & echo now; wait; echo done'
same "cd" 'mkdir sub; cd sub; pwd | sed s,.*/,,; cd; pwd | grep -c /tmp; cd /nonexistent; echo $status'
same "exit" 'echo a; exit 3; echo b'
same "exit status of a pipe" "sh -c 'exit 3' | sh -c 'exit 4'; echo \$status; sh -c 'exit 3' | sh -c 'exit 4'"
same "continued lines and comments" 'echo a \
  b # a comment
# alone
echo c#d'
same "the environment" "x=(a b); sh -c 'printenv x' | od -c | sed 1q"
same "a missing program" 'nonexistent_program; echo $status'

# -e, and -c, as mk runs its shell
e_expected=$($RC -e -c 'echo a; false; echo b' 2>&1; echo "[exit $?]")
e_actual=$($TS -e -c 'echo a; false; echo b' 2>&1; echo "[exit $?]")
if [ "$e_expected" = "$e_actual" ]; then echo "ok   -e"; else echo "FAIL -e"; failures=$((failures + 1)); fi
e_expected=$($RC -e -c 'if(false) echo no; false || echo or; ! true; echo still' 2>&1; echo "[exit $?]")
e_actual=$($TS -e -c 'if(false) echo no; false || echo or; ! true; echo still' 2>&1; echo "[exit $?]")
if [ "$e_expected" = "$e_actual" ]; then echo "ok   -e, not in conditions"
else echo "FAIL -e, not in conditions"; echo "$e_expected"; echo "---"; echo "$e_actual"; failures=$((failures + 1)); fi

[ $failures -eq 0 ] && echo "all passed" || { echo "$failures failed"; exit 1; }
