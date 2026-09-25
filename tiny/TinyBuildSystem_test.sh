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
# The tests of TinyBuildSystem.ml: each scenario runs tiny-build in a
# fresh directory and compares what it printed with what it should.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TB=${TB:-$ROOT/_build/default/tiny/TinyBuildSystem.exe}
failures=0

# check NAME EXPECTED CMD...: run CMD, compare its output (stdout and
# stderr, and "[exit N]" when not 0) with EXPECTED
check() {
  name=$1 expected=$2; shift 2
  actual=$("$@" 2>&1; st=$?; [ $st -ne 0 ] && echo "[exit $st]")
  if [ "$actual" = "$expected" ]; then echo "ok   $name"
  else echo "FAIL $name"; echo "--- expected"; echo "$expected"; echo "--- got"; echo "$actual"
       failures=$((failures + 1)); fi
}
fresh() { dir=$(mktemp -d); cd "$dir" || exit 1; }

# the recipes fake a compiler: an object is its source, a program the
# concatenation of its objects
hello() {
  cat > Buildfile <<'EOF'
OBJS = hello.o world.o
hello: $OBJS
	echo link; cat $prereq > $target
%.o: %.c
	echo cc $stem; cp $stem.c $target
clean:
	rm -f *.o hello
EOF
  echo 'hello' > hello.c; echo 'world' > world.c
}

fresh; hello
check "from scratch" "echo cc hello; cp hello.c hello.o
cc hello
echo cc world; cp world.c world.o
cc world
echo link; cat hello.o world.o > hello
link" "$TB"
check "idempotent" "tiny-build: hello is up to date" "$TB"
touch hello.c world.c
check "new times, same contents" "tiny-build: hello is up to date" "$TB"
echo 'world!' > world.c
check "minimal: one source edited" "echo cc world; cp world.c world.o
cc world
echo link; cat hello.o world.o > hello
link" "$TB"
check "the result" "hello
world!" cat hello
check "a virtual target always runs" "rm -f *.o hello" "$TB" clean
check "and again" "rm -f *.o hello" "$TB" clean
check "-n runs nothing" "echo cc hello; cp hello.c hello.o
echo cc world; cp world.c world.o
echo link; cat hello.o world.o > hello" "$TB" -n
check "nothing was made" "no hello.o" sh -c '[ -f hello.o ] || echo no hello.o'
check "-g" 'digraph G {
  "hello.o" -> "hello.c";
  "world.o" -> "world.c";
  "hello" -> "hello.o";
  "hello" -> "world.o";
}' "$TB" -g

# early cutoff: config.h is regenerated identically, foo.o is not rebuilt
fresh
cat > Buildfile <<'EOF'
foo.o: config.h
	echo cc; cp config.h foo.o
config.h: config.in
	echo gen; cut -d' ' -f1 config.in > config.h
EOF
echo 'v1 a comment' > config.in
"$TB" > /dev/null
echo 'v1 another comment' > config.in
check "early cutoff" "echo gen; cut -d' ' -f1 config.in > config.h
gen" "$TB"

# -j 2: two one-second recipes in about a second
fresh
cat > Buildfile <<'EOF'
all: a b
a:
	sleep 1; touch a
b:
	sleep 1; touch b
EOF
start=$(date +%s)
"$TB" -j 2 > /dev/null
check "-j 2 runs both at once" "yes" sh -c "[ \$((\$(date +%s) - $start)) -lt 2 ] && echo yes || echo no"

# the checks
fresh
printf 'a: b\n\ttouch a\nb: c\n\ttouch b\nc: a\n\ttouch c\n' > Buildfile
check "cycle" "tiny-build: cycle: a -> b -> c -> a
[exit 1]" "$TB"
fresh
printf '%%.o: %%.c\n\techo cc\n%%.o: %%.s\n\techo as\n' > Buildfile; touch x.c x.s y.c
check "ambiguous" "tiny-build: ambiguous: several patterns make x.o
[exit 1]" "$TB" x.o
check "a pattern whose prerequisite can't be made is not a candidate" "echo cc
cc" "$TB" y.o
fresh
printf 'a: nothere\n\ttouch a\n' > Buildfile
check "don't know how" "tiny-build: don't know how to make nothere
[exit 1]" "$TB"
fresh
printf '%%: %%.gz\n\tgunzip -k $stem.gz\n' > Buildfile; touch foo.gz.gz
check "a pattern once per path: no foo.gz.gz.gz..." "tiny-build: don't know how to make foo
[exit 1]" "$TB" foo

# a failing recipe: what depends on it does not run
fresh
printf 'all: bad good\n\techo all\nbad:\n\tfalse\ngood:\n\techo good\n' > Buildfile
check "failure" "false
tiny-build: bad failed
[exit 1]" "$TB"

echo "$failures failure(s)"
[ $failures -eq 0 ]
