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
# ocaml-light cross-compiled for the Pis (plan_kernel.md): a clone of
# ~/ocaml-light (untouched) configured with -target-arch arm (the Pi1's)
# or arm64 (the Pi4's), built (make world, make opt) and installed in
# $OCL (default /tmp/ix-ocaml-light-ARCH): its ocamlopt emits that
# architecture's code, its stdlib is compiled for it, and the runtime's
# sources are in $OCL/src for the kernel's Makefile to compile
# freestanding. About 5 minutes; kept until /tmp is cleared.
#
# Usage: ocaml-light.sh [arm|arm64]

ARCH=${1:-arm}
OCL=${OCL:-/tmp/ix-ocaml-light-$ARCH}
[ -x $OCL/bin/ocamlopt ] && { echo "ocaml-light for $ARCH: $OCL (already built)"; exit 0; }
set -e
rm -rf $OCL
git clone -q ${OCAML_LIGHT:-$HOME/ocaml-light} $OCL/src
cd $OCL/src
./configure -target-arch $ARCH -bindir $OCL/bin -libdir $OCL/lib > $OCL/configure.log
make world > $OCL/world.log 2>&1
make opt > $OCL/opt.log 2>&1
make install installopt > $OCL/install.log 2>&1
echo "ocaml-light for $ARCH: $OCL"
