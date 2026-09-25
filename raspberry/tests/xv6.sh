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
#    QEMU and under mini-qemu, byte for byte the same (arm64-pi4: less
#    the lines of QEMU's other three cores, "hart 1 starting";
#    mini-qemu runs one, plan_pi.md decision 3);
# 2. with -u, the port's own acceptance test, unchanged: its
#    test-xv6.py (boot, usertests to ALL TESTS PASSED) run with
#    QEMU=mini-qemu (the release build: dune build --profile release),
#    and for arm64-pi4 CPUS=1.
#
# Needs ~/xv6 (xv6-multiarch, its ports built), qemu-system-arm, and
# for arm64-pi4 a qemu-system-aarch64 with raspi4b (9.1 on: $QEMU64,
# default the one built under TOOLCHAINS/qemu, else the PATH's).
#
# Usage: xv6.sh [-u] [port...]

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TP=$ROOT/_build/default/raspberry/Main.exe
XV6=${XV6:-$HOME/xv6}
full=0
[ "$1" = -u ] && { full=1; shift; }
# arm64-pi4 by name only: its boot takes 21s (xv6_pi4.py boots and
# tests a copy with less RAM, fast)
ports=${@:-arm-pi1-bis arm-pi1}
QEMU64=${QEMU64:-/media/pad/extradrive1/pad/work/TOOLCHAINS/qemu/build/qemu-system-aarch64}
[ -x $QEMU64 ] || QEMU64=qemu-system-aarch64
# the image each port's "make qemu" boots
image() { case $1 in arm-pi1) echo kernel-qemu.img;; arm64-pi4) echo kernel/kernel;; *) echo kernel.img;; esac; }
failures=0
W=$(mktemp -d)
trap 'rm -rf $W' EXIT

# the output until the prompt ("$ "), or 90 seconds
boot() { # name command...
  local name=$1; shift
  ( sleep 90 ) | timeout 90 "$@" > $W/$name 2>/dev/null &
  local pid=$!
  for _ in $(seq 900); do grep -q '^\$ ' $W/$name 2>/dev/null && break; sleep 0.1; done
  pkill -P $pid 2>/dev/null; kill $pid 2>/dev/null; wait $pid 2>/dev/null
  sed -i -n '1,/^\$ /p' $W/$name
}

for port in $ports; do
  d=$XV6/forks/$port
  img=$d/$(image $port)
  [ -f $img ] || { echo "skip $port: not built"; continue; }
  if [ $port = arm64-pi4 ]; then
    boot qemu $QEMU64 -cpu cortex-a72 -M raspi4b -m 2G -smp 4 -nographic -kernel $img
    sed -i '/^hart [123] starting\r\?$/d' $W/qemu
    boot mini-qemu $TP -cpu cortex-a72 -M raspi4b -m 2G -smp 1 -nographic -kernel $img
  else
    boot qemu qemu-system-arm -M raspi1ap -nographic -kernel $img
    boot mini-qemu $TP -M raspi1ap -nographic -kernel $img
  fi
  if cmp -s $W/qemu $W/mini-qemu && [ -s $W/qemu ]; then echo "ok $port: boots as under QEMU ($(wc -l < $W/qemu) lines)"
  else echo "FAIL $port: the boot differs from QEMU's"; diff $W/qemu $W/mini-qemu | head -5; failures=$((failures + 1)); fi
  if [ $full = 1 ]; then
    if (cd $d && CPUS=1 QEMU=$TP timeout 1800 python3 test-xv6.py) > $W/log 2>&1 && grep -q "ALL TESTS PASSED" $W/log; then
      echo "ok $port: usertests, ALL TESTS PASSED"
    else echo "FAIL $port: usertests"; tail -5 $W/log; failures=$((failures + 1)); fi
  fi
done
echo "xv6: $failures failures"
exit $((failures > 0))
