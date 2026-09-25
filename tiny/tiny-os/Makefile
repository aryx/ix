# Claude Code
#
# Copyright (C) 2026 Yoann Padioleau
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Library General Public License
# (LGPL) as published by the Free Software Foundation; either version
# 2 of the License, or (at your option) any later version.
#
# tiny-os: an operating system for tiny-machine, built by the tiny
# tools as any program is built by its toolchain. A kernel per version,
# each in its directory with its Makefile (v0/: a page of assembly;
# v6/, xv6's kind of kernel, in C; t6/, its free variant: spawn, a
# FAT, one kernel stack), and what they share: the C
# runtime (libc/: start.tm, udivmod.tm, libc.c, libc.h), whose system calls are
# tiny-cpu's and the kernels'. Not TinyKernel.ml,
# mini-xv6 or mini-9pi, other projects of ix (docs/projects.md).
#
#   make run          v6 on tiny-machine: its shell, on the console
#   make run-v0       v0
#   make run-hello    hello.c, compiled by tiny-c -tm, on tiny-cpu
#
# The tools from the PATH (after `dune install`), or from ix's bin/. A
# C program is compiled to .tm by tiny-c -tm, then linked by tiny-cpu
# after the runtime: start.tm first (the machine starts at 0), udivmod.tm,
# libc.

export PATH := $(abspath ../../bin):$(PATH)

TC = tiny-c
CPU = tiny-cpu
VERSIONS = v0 v6 t6

all: libc/libc.tm hello
	for v in $(VERSIONS); do $(MAKE) -C $$v all || exit 1; done

%.tm: %.c libc/libc.h
	$(TC) -tm -o $@ $<

hello.tm: hello.c libc/libc.h
	$(TC) -tm -o $@ hello.c

hello: libc/start.tm libc/udivmod.tm libc/libc.tm hello.tm
	$(CPU) -o $@ $^

run:
	$(MAKE) -C v6 run

run-v0:
	$(MAKE) -C v0 run

run-hello: hello
	$(CPU) ./hello one two

clean:
	rm -f hello hello.tm libc/libc.tm
	for v in $(VERSIONS); do $(MAKE) -C $$v clean; done

.PHONY: all run run-v0 run-hello clean
