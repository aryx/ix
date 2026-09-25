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
# words_arm64_system.txt, the privileged decoder's corpus (plan_pi.md,
# phase G1): the instruction words of xv6 arm64-pi4 (its kernel and
# programs, as built in ~/xv6) and of system_arm64.s (assembled by GNU
# as), without the data objdump does not decode (literal pools).
# decode_check.py -64 words_arm64_system.txt checks them.
#
# Usage: census_system.sh > words_arm64_system.txt

HERE=$(cd "$(dirname "$0")" && pwd)
XV6=${XV6:-$HOME/xv6}/forks/arm64-pi4
W=$(mktemp -d)
trap 'rm -rf $W' EXIT
aarch64-linux-gnu-as -march=armv8.4-a $HERE/system_arm64.s -o $W/s.o
for f in $XV6/kernel/kernel $XV6/user/_* $W/s.o; do objdump -d $f; done |
  awk -F'\t' '/^ *[0-9a-f]+:\t[0-9a-f]{8} / && $3 != "" && $3 !~ /^\.(inst|word)/ {split($2, a, " "); print a[1]}' | sort -u
