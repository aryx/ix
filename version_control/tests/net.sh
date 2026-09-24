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
# Phase 8: TinyGit's protocol against C git's, both ways.
#
#   tinygit clone from git daemon (git://), over ssh ($GIT_SSH: a
#   stand-in running git-upload-pack here), and from a local C git
#   repository: the work tree git clone checks out, the x bits, fsck;
#   tinygit push to git daemon (receive-pack), C git reading the result;
#   tinygit pull of commits C git pushed;
#   C git clone and push through tinygit serve (git's ext:: transport,
#   "tinygit serve %G/path"): fsck, and tinygit reading the push.
#
# Usage: net.sh [repository to serve]   (default: ix itself)

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
T=$ROOT/_build/default/version_control/Main.exe
SRC=${1:-$ROOT}
W=$(mktemp -d)
PORT=$((20000 + RANDOM % 10000))
failures=0
fail() { echo "FAIL $*"; failures=$((failures + 1)); }
ok() { echo "ok $*"; }
export GIT_AUTHOR_NAME=Glenda GIT_AUTHOR_EMAIL=glenda@9front.org GIT_COMMITTER_NAME=Glenda GIT_COMMITTER_EMAIL=glenda@9front.org

git clone -q --bare "$SRC" $W/src.git
git clone -q $W/src.git $W/reference
BR=$(git --git-dir=$W/src.git symbolic-ref --short HEAD)
git daemon --reuseaddr --base-path=$W --export-all --enable=receive-pack --port=$PORT --listen=127.0.0.1 --pid-file=$W/daemon.pid $W 2> /dev/null &
trap 'kill $(cat $W/daemon.pid) 2>/dev/null; rm -rf $W' EXIT
for i in 1 2 3 4 5 6 7 8 9 10; do [ -f $W/daemon.pid ] && break; sleep 0.2; done
sleep 0.3

# the same files and x bits as C git's checkout
same_tree() {
  diff -r -q -x .git $W/reference $1 > /dev/null || { fail "$2: tree differs"; return 1; }
  a=$(cd $W/reference && find . -path ./.git -prune -o -type f -perm -u+x -print | sort)
  b=$(cd $1 && find . -path ./.git -prune -o -type f -perm -u+x -print | sort)
  [ "$a" = "$b" ] || { fail "$2: x bits differ"; return 1; }
  git --git-dir=$1/.git fsck --strict > /dev/null 2>&1 || { fail "$2: fsck"; return 1; }
  (cd $1 && $T walk -q) || { fail "$2: walk not clean"; return 1; }
  ok "$2"
}

# clone
(cd $W && $T clone git://127.0.0.1:$PORT/src.git c_git > /dev/null 2>&1) || fail "clone git://"
same_tree $W/c_git "clone git://"
printf '#!/bin/sh\nshift\nexec sh -c "$*"\n' > $W/fakessh; chmod +x $W/fakessh
(cd $W && GIT_SSH=$W/fakessh $T clone localhost:$W/src.git c_ssh > /dev/null 2>&1) || fail "clone ssh"
same_tree $W/c_ssh "clone ssh"
(cd $W && $T clone $W/reference c_local > /dev/null 2>&1) || fail "clone local"
same_tree $W/c_local "clone local (git's repository, tinygit serve)"

# push from tinygit to git daemon, C git reads it
cd $W/c_git
echo "a tinygit change" >> README.md
mkdir -p newdir && echo new > newdir/file && $T add newdir/file
GIT_AUTHOR_DATE="1700000000 +0000" $T commit -m "tinygit commit" . > /dev/null || fail "commit"
out=$($T push 2>&1) || fail "push git://: $out"
[ "$(git --git-dir=$W/src.git rev-parse $BR)" = "$($T query HEAD)" ] && ok "push git://" || fail "push git://: ref"
git --git-dir=$W/src.git fsck --strict > /dev/null 2>&1 || fail "push git://: fsck of the server"

# C git pushes; tinygit pulls
(cd $W/reference && git pull -q && echo "from C git" > cfile && git add cfile && git commit -q -m "C git commit" && git push -q) || fail "C git push"
(cd $W/c_git && $T pull > /dev/null 2>&1) || fail "pull git://"
same_tree $W/c_git "pull git://"

# C git through tinygit serve
X="-c protocol.ext.allow=always"
git $X clone -q "ext::$T serve %G$W/c_git" $W/g_from_tiny 2> $W/err || fail "git clone from tinygit serve: $(cat $W/err)"
git --git-dir=$W/g_from_tiny/.git fsck --strict > /dev/null 2>&1 && [ "$(git -C $W/g_from_tiny rev-parse HEAD)" = "$(cd $W/c_git && $T query HEAD)" ] \
  && ok "git clone from tinygit serve" || fail "git clone from tinygit serve"
(cd $W/g_from_tiny && echo more >> cfile && git commit -q -am "pushed into tinygit" && git $X push -q "ext::$T serve -w %G$W/c_git" $BR 2> $W/err) || fail "git push to tinygit serve: $(cat $W/err)"
[ "$(cd $W/c_git && $T query $BR)" = "$(git -C $W/g_from_tiny rev-parse HEAD)" ] && git --git-dir=$W/c_git/.git fsck --strict > /dev/null 2>&1 \
  && ok "git push to tinygit serve" || fail "git push to tinygit serve"
echo "net: $failures failures"
exit $((failures > 0))
