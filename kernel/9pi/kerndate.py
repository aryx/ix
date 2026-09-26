#!/usr/bin/env python3
# Claude Code
#
# Copyright (C) 2026 Yoann Padioleau
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Library General Public License
# (LGPL) as published by the Free Software Foundation; either version
# 2 of the License, or (at your option) any later version.
#
# 9pi's kerndate (its conf compiled with -DKERNDATE=`date -n`: the time
# its devices' files say they were made), for mini-9pi's to be the same:
# the little-endian word of 9pi's image in the minute before its conf's
# object was written (pi.5's mtime; `date -n` ran just before the
# compile); that mtime if none, the time now if no 9pi.
#
# Usage: kerndate.py PRINCIPIA

import os, struct, sys, time

bcm = os.path.join(sys.argv[1], "kernel/COMPILE/9/bcm")
try:
    t = int(os.stat(os.path.join(bcm, "pi.5")).st_mtime)
    image = open(os.path.join(bcm, "9pi"), "rb").read()
except OSError:
    print(int(time.time()))
    sys.exit(0)
found = [v for (v,) in struct.iter_unpack("<I", image[: len(image) // 4 * 4]) if t - 60 <= v <= t]
print(max(found) if found else t)
