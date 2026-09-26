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
# mini-9pi's bootdir (plan_9pi.md): the files 9pi links into its image
# (kernel/conf/arm/pi's bootdir: /boot/boot the rc script, rcmain, rc,
# echo, bind, fdisk, dossrv, mount, ls), packed for devroot (Devroot.ml)
# as the kernel's embedded image: a line "9pi bootdir KERNDATE" (the
# time the devices' files say they were made: 9pi's kerndate, its
# build's `date -n`), then for each file a line "name size" and its
# bytes, then a line "end".
#
# Usage: mkbootdir.py OUT KERNDATE NAME=PATH...

import sys

out, kerndate, pairs = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
with open(out, "wb") as f:
    f.write(b"9pi bootdir %d\n" % kerndate)
    for p in pairs:
        name, path = p.split("=", 1)
        data = open(path, "rb").read()
        f.write(("%s %d\n" % (name, len(data))).encode())
        f.write(data)
    f.write(b"end\n")
