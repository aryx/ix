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
# git9's own tests (principia's version_control/git9/test/*.rc),
# translated from rc to bash, each test a function run in a fresh
# scratch directory, each check the rc one's. git/CMD is tinygit CMD.
# git9's tests name the default branch front (9front's); this git/init
# makes master, which they say here. export and rebase come with patch
# (phase 9).
#
# Usage: git9_tests.sh [test ...]

T=${T:-$(cd "$(dirname "$0")/../.." && pwd)/_build/default/version_control/Main.exe}
git() { "$T" "$@"; }
q() { out=$("$@" 2>&1) || { echo "$out"; return 1; }; }
failures=0
# a check fails into a file: many run in subshells, as rc's @{ } do
die() { echo "FAIL $test: $*"; touch $failed; return 1; }

t_add() {
  mkdir repo && cd repo
  pwd=$(pwd)
  git init
  mkdir dir another more extra
  touch a b c dir/{a,b,c} another/{a,b,c} more/{a,b,c} extra/{a,b,c}
  git add a
  git add $pwd/b
  git add dir/a
  git add $pwd/dir/b
  git add more
  (cd more && git add ../extra/a)
  (cd more && git add $pwd/extra/b)
  git walk > ../added
  cd ..
  printf 'A a\nA b\nA dir/a\nA dir/b\nA extra/a\nA extra/b\nA more/a\nA more/b\nA more/c\n' > add.expected
  diff added add.expected > /dev/null || die wrong files
}

t_diff() {
  mkdir -p subdir/subdir2 subdir3
  q git init
  echo hello > file.txt
  echo hello1 > subdir/file1.txt
  echo hello2 > subdir/subdir2/file2.txt
  echo hello3 > subdir3/file3.txt
  q git add file.txt subdir/file1.txt subdir/subdir2/file2.txt subdir3/file3.txt
  q git commit -m initial .
  echo > file.txt; echo > subdir/file1.txt; echo > subdir/subdir2/file2.txt; echo > subdir3/file3.txt
  out=$(git diff -s . | awk '{ print $2 }' | tr '\n' ' ')
  [ "$out" = "file.txt subdir/file1.txt subdir/subdir2/file2.txt subdir3/file3.txt " ] || { die "base level fail: $out"; return; }
  cd subdir
  out=$(git diff -s .. | awk '{ print $2 }' | tr '\n' ' ')
  [ "$out" = "../file.txt file1.txt subdir2/file2.txt ../subdir3/file3.txt " ] || { die "subdir1 level fail: $out"; return; }
  cd subdir2
  out=$(git diff -s ../.. | awk '{ print $2 }' | tr '\n' ' ')
  [ "$out" = "../../file.txt ../file1.txt file2.txt ../../subdir3/file3.txt " ] || { die "subdir2 level fail: $out"; return; }
  cd ../../subdir3
  out=$(git diff -s .. | awk '{ print $2 }' | tr '\n' ' ')
  [ "$out" = "../file.txt ../subdir/file1.txt ../subdir/subdir2/file2.txt file3.txt " ] || { die "subdir3 level fail: $out"; return; }
  ! git diff -s ../.. 2>/dev/null || die "outside the repo"
}

t_lca() {
  q git init a
  (cd a
   echo first > f
   q git add f
   q git commit -m base f
   r=$(git query HEAD)
   echo 0 > f
   q git commit -m a.0 .
   a=$(git query HEAD)
   for i in $(seq 10); do echo $i > f; q git commit -m a.$i .; done
   q git branch -nb $r merge
   echo x > f
   q git commit -m b.0 .
   b=$(git query HEAD)
   git merge master > /dev/null 2>&1
   q git commit -m merge .
   m=$(git query HEAD)
   [ "$(git query $a $m @)" = $a ] || die lca a-m
   [ "$(git query $a $b @)" = $r ] || die lca a-b
   [ "$(git query $a $r @)" = $r ] || die lca a-r)
  #       a
  #       |
  # b-c-d-e-f      date order (oldest to newest): f d c b e a
  q git init b
  (cd b
   touch f
   commit() { git save -n regress -e regress "$@" f; }
   f=$(commit -m f -d 1)
   e=$(commit -m e -d 5 -p $f)
   d=$(commit -m d -d 2 -p $e)
   c=$(commit -m c -d 3 -p $d)
   b=$(commit -m b -d 4 -p $c)
   a=$(commit -m a -d 6 -p $e)
   [ "$(git query $a $b @)" = $e ] || die lca a-b
   [ "$(git query $b $a @)" = $e ] || die lca b-a)
}

t_range() {
  commit() { git save -n regress -e regress "$@" f; }
  # h-g-f
  # |   |
  # e-d-c-b-a
  q git init a
  (cd a
   touch f
   a=$(commit -m a); b=$(commit -m b -p $a); c=$(commit -m c -p $b); d=$(commit -m d -p $c)
   e=$(commit -m e -p $d); f=$(commit -m f -p $c); g=$(commit -m g -p $f); h=$(commit -m h -p $e -p $g)
   map="s/^$a\$/a/;s/^$b\$/b/;s/^$c\$/c/;s/^$d\$/d/;s/^$e\$/e/;s/^$f\$/f/;s/^$g\$/g/;s/^$h\$/h/"
   diff -u <(printf 'd\ne\ng\nh\n') <(git query $f..$h | sed -e "$map") || die range)
  #       b
  #      / \
  # f-e-d   a
  #      \ /
  #       c
  q git init b
  (cd b
   touch f
   a=$(commit -m a); b=$(commit -m b -p $a); c=$(commit -m c -p $a)
   d=$(commit -m d -p $b -p $c); e=$(commit -m e -p $d); f=$(commit -m f -p $e)
   map="s/^$a\$/a/;s/^$b\$/b/;s/^$c\$/c/;s/^$d\$/d/;s/^$e\$/e/;s/^$f\$/f/"
   diff -u <(printf 'c\nd\ne\nf\n') <(git query $b..$f | sed -e "$map") || die range
   diff -u <(printf 'b\nd\ne\nf\n') <(git query $c..$f | sed -e "$map") || die range 2)
}

t_noam() {
  mkdir noam && cd noam
  q git init
  touch a
  q git add a
  q git commit -m 'add a' a
  rm a
  mkdir a
  touch a/b
  q git add a/b
  q git commit -m 'switch to folder' a a/b || die commit
  [ "$(git fs HEAD/tree/a)" = b ] || die "HEAD/tree/a: $(git fs HEAD/tree/a)"
}

# the last part of merge.rc: git/save dropping files of a merge
t_james() {
  mkdir james && cd james
  q git init
  mkdir -p lib/ndb
  touch lib/words
  q git add lib/words
  q git commit -m 'add words' lib/words
  q git branch -n myhead
  echo stuff > lib/ndb/local
  q git add lib/ndb/local
  q git commit -m 'Add lib/ndb/local' lib/ndb/local
  q git branch master
  echo cromulent >> lib/words
  q git commit -m 'Some change on front' lib/words
  q git branch myhead
  q git merge master
  q git commit -m 'Merge front'
  d=$(git diff lib/words lib/ndb/local)
  [ -z "$d" ] || die "$d"
}

t_basic() {
  wrkdir=$(pwd)
  mkdir -p upstream
  (cd upstream && q git init && echo version1 > file.txt && q git add file.txt && q git commit -m version1 file.txt)
  git clone $wrkdir/upstream downstream > /dev/null 2>&1
  diff upstream/file.txt downstream/file.txt > /dev/null || die mismatch 1
  (cd upstream && echo version2 > file.txt && q git commit -m version2 file.txt)
  (cd downstream && q git pull)
  diff upstream/file.txt downstream/file.txt > /dev/null || die mismatch 2
  (cd upstream && echo version3 > file2.txt && git add file2.txt && q git commit -m version3 file2.txt)
  (cd downstream && q git pull)
  diff upstream/file.txt downstream/file.txt > /dev/null || die mismatch 3
  diff upstream/file2.txt downstream/file2.txt > /dev/null || die mismatch 3b
  (cd upstream && echo version4 > file.txt && git rm file2.txt && rm file2.txt && q git commit -m version4 file.txt file2.txt)
  (cd downstream && q git pull)
  diff upstream/file.txt downstream/file.txt > /dev/null || die mismatch 4
  ! test -e upstream/file2.txt || die mismatch 4b
  ! test -e downstream/file2.txt || die mismatch 4c
}

t_ftype() {
  mkdir repo1 && cd repo1
  repo1=$(pwd)
  q git init
  # A a file, B a directory
  echo A > A
  mkdir B
  echo C > B/C
  q git add A B/C
  q git commit -m 1 A B/C
  cd ..
  q git clone $repo1 repo2
  cd repo2
  repo2=$(pwd)
  diff -r $repo1/A $repo2/A > /dev/null || { die 'clone fail A'; return; }
  diff -r $repo1/B $repo2/B > /dev/null || { die 'clone fail B'; return; }
  cd $repo1
  # A made a directory, B a file
  rm -r A B
  mkdir A
  echo B > A/B
  echo B > B
  q git add A/B B
  q git commit -m 2 A/B B
  cd $repo2
  q git pull
  diff -r $repo1/A $repo2/A > /dev/null || die 'pull fail A'
  diff -r $repo1/B $repo2/B > /dev/null || die 'pull fail B'
}

# merge.rc's first two parts: different files, then concurrent edits
t_merge() {
  c='foo
bar
baz
'
  q git init a
  (cd a && echo hello > a && echo goodbye > b && printf '%s' "$c" > c && chmod +x a && q git add a b c && q git commit -m v1 .)
  q git clone $(pwd)/a b
  # merge different files
  (cd a && echo x > a && q git commit -m diverge1a a)
  (cd b && echo y > b && q git commit -m diverge1b b
   git pull > /dev/null 2>&1
   q git merge origin/master
   q git commit -m merged)
  [ "$(cat b/a)" = x ] || die merge 1.a
  [ "$(cat b/b)" = y ] || die merge 1.b
  [ "$(cat b/c)" = "$(printf '%s' "$c")" ] || die merge 1.c
  test -x b/a || die merge preserve exec
  ! test -x b/b || die merge preserve nonexec b
  ! test -x b/c || die merge preserve nonexec c
  (cd b && git walk -q) || die merge commit dropped files
  # concurrent edits
  (cd a && chmod -x a && chmod +x b && echo quux >> c && q git commit -m diverge2a a b c)
  (cd b && sed s/foo/FOO/ < c > c.new && mv c.new c && q git commit -m diverge2b c
   git pull > /dev/null 2>&1
   git merge origin/master > /dev/null 2>&1
   q git commit -m merge c)
  c='FOO
bar
baz
quux
'
  [ "$(cat b/a)" = x ] || die merge 2.a
  [ "$(cat b/b)" = y ] || die merge 2.b
  [ "$(cat b/c)" = "$(printf '%s' "$c")" ] || { diff -u b/c <(printf '%s' "$c"); die merge 2.c; }
  ! test -x b/a || die merge remove exec
  test -x b/b || die merge add exec
  ! test -x b/c || die merge preserve nonexec c
}

tests=${*:-add diff lca range noam james basic ftype merge}
for test in $tests; do
  dir=$(mktemp -d); failed=$dir.failed
  (cd $dir && t_$test)
  if [ -e $failed ]; then failures=$((failures + 1)); else echo "ok $test"; fi
  rm -rf $dir $failed
done
echo "git9 tests: $failures failures"
exit $((failures > 0))
