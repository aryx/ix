# Claude Code
#
# Copyright (C) 2026 Yoann Padioleau
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Library General Public License
# (LGPL) as published by the Free Software Foundation; either version
# 2 of the License, or (at your option) any later version.
#
# tiny-os: what runs on ix's own machines, built by the tiny tools as
# any program is built by its toolchain. The tools are taken from the
# PATH (after `dune install`), or from ix's bin/ when there (`make` at
# the top of ix):
#
#   make run          TinyKernel v0 and its four programs on tiny-machine
#   make run-hello    hello.c, compiled by tiny-c -tm, on tiny-cpu
#   make listing      the kernel's image, listed
#
# kernel.img is linked from .tm files by tiny-machine; a C program is
# compiled to .tm by tiny-c -tm, then linked by tiny-cpu with the
# runtime, start.tm first (the machine starts at 0) and libc.

export PATH := $(abspath ../../bin):$(PATH)

TC = tiny-c
CPU = tiny-cpu
MACHINE = tiny-machine

all: kernel.img hello

# the kernel first, at 0, then its programs, found by their labels
kernel.img: kernel.tm a.tm b.tm c.tm d.tm
	$(MACHINE) -o $@ $^

%.tm: %.c libc.h
	$(TC) -tm -o $@ $<

hello: start.tm libc.tm hello.tm
	$(CPU) -o $@ $^

run: kernel.img
	$(MACHINE) kernel.img

run-hello: hello
	$(CPU) ./hello one two

listing: kernel.img
	$(MACHINE) -l kernel.img

clean:
	rm -f kernel.img hello libc.tm hello.tm

.PHONY: all run run-hello listing clean
