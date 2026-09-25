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
# mini-qemu against QEMU on xv6's Pi ports (plan_pi.md, phase A
# on): for each port (default: those mini-qemu boots so far),
#
# 1. the boot: the console's output until the shell's prompt, under
#    QEMU and under mini-qemu, byte for byte the same;
# 2. with -u, the port's own acceptance test, unchanged: its
#    test-xv6.py (boot, usertests to ALL TESTS PASSED) run with
#    QEMU=mini-qemu (the release build: dune build --profile release).
#
# Needs ~/xv6 (xv6-multiarch, its ports built) and qemu-system-arm.
#
# Usage: xv6.sh [-u] [port...]

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TP=$ROOT/_build/default/raspberry/Main.exe
XV6=${XV6:-$HOME/xv6}
full=0
[ "$1" = -u ] && { full=1; shift; }
ports=${@:-arm-pi1-bis arm-pi1}
# the image each port's "make qemu" boots
image() { case $1 in arm-pi1) echo kernel-qemu.img;; *) echo kernel.img;; esac; }
failures=0
W=$(mktemp -d)
trap 'rm -rf $W' EXIT

# the output until the prompt ("$ "), or 60 seconds
boot() { # name command...
  local name=$1; shift
  ( sleep 60 ) | timeout 60 "$@" > $W/$name 2>/dev/null &
  local pid=$!
  for _ in $(seq 600); do grep -q '^\$ ' $W/$name 2>/dev/null && break; sleep 0.1; done
  pkill -P $pid 2>/dev/null; kill $pid 2>/dev/null; wait $pid 2>/dev/null
  sed -i -n '1,/^\$ /p' $W/$name
}

for port in $ports; do
  d=$XV6/forks/$port
  img=$d/$(image $port)
  [ -f $img ] || { echo "skip $port: not built"; continue; }
  boot qemu qemu-system-arm -M raspi1ap -nographic -kernel $img
  boot mini-qemu $TP -M raspi1ap -nographic -kernel $img
  if cmp -s $W/qemu $W/mini-qemu && [ -s $W/qemu ]; then echo "ok $port: boots as under QEMU ($(wc -l < $W/qemu) lines)"
  else echo "FAIL $port: the boot differs from QEMU's"; diff $W/qemu $W/mini-qemu | head -5; failures=$((failures + 1)); fi
  if [ $full = 1 ]; then
    if (cd $d && QEMU=$TP timeout 900 python3 test-xv6.py) > $W/log 2>&1 && grep -q "ALL TESTS PASSED" $W/log; then
      echo "ok $port: usertests, ALL TESTS PASSED"
    else echo "FAIL $port: usertests"; tail -5 $W/log; failures=$((failures + 1)); fi
  fi
done
echo "xv6: $failures failures"
exit $((failures > 0))
