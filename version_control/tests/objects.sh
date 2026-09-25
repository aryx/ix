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
# Phases 2, 3 and 7: every object of a repository read by mini-git's
# Store, its kind and size as git cat-file --batch-check says, and
# printing its parse hashing back to its name; the repository loose,
# packed by git gc (OFS deltas), repacked with REF deltas, and repacked
# by mini-git repack (git9's deltas and index), which git verify-pack
# and git fsck --strict must accept, the same objects in it.
#
# Usage: objects.sh [REPO]   (default: ix itself)

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CHECK=$ROOT/_build/default/version_control/tests/Objects_check.exe
SRC=${1:-$ROOT}
W=$(mktemp -d)
trap 'rm -rf $W' EXIT
failures=0

check() {
  what=$1 git=$2
  git --git-dir=$git cat-file --batch-all-objects --batch-check > $W/want
  cut -d' ' -f1 $W/want | $CHECK $git > $W/got
  if cmp -s $W/want $W/got; then
    echo "ok $what: $(wc -l < $W/want) objects"
  else
    echo "FAIL $what"; diff $W/want $W/got | head -5; failures=$((failures + 1))
  fi
}

git clone -q --no-local --bare "$SRC" $W/r.git
# loose: every object out of the clone's pack
mkdir $W/loose.git && git init -q --bare $W/loose.git
for p in $W/r.git/objects/pack/*.pack; do git --git-dir=$W/loose.git unpack-objects -q < $p; done
check loose $W/loose.git
git --git-dir=$W/r.git gc -q --aggressive
check "gc (OFS deltas)" $W/r.git
git --git-dir=$W/r.git -c repack.useDeltaBaseOffset=false repack -q -a -d -f
check "repack (REF deltas)" $W/r.git
git --git-dir=$W/r.git cat-file --batch-all-objects --batch-check > $W/before
git clone -q $W/r.git $W/tiny
(cd $W/tiny && $ROOT/_build/default/version_control/Main.exe repack)
if git --git-dir=$W/tiny/.git verify-pack $W/tiny/.git/objects/pack/*.idx && git --git-dir=$W/tiny/.git fsck --strict; then
  check "mini-git repack" $W/tiny/.git
  git --git-dir=$W/tiny/.git cat-file --batch-all-objects --batch-check | cmp -s - $W/before || { echo "FAIL mini-git repack: objects differ"; failures=$((failures + 1)); }
else
  echo "FAIL mini-git repack: verify-pack or fsck"; failures=$((failures + 1))
fi
exit $failures
