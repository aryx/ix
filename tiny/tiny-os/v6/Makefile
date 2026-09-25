# Claude Code
#
# Copyright (C) 2026 Yoann Padioleau
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Library General Public License
# (LGPL) as published by the Free Software Foundation; either version
# 2 of the License, or (at your option) any later version.
#
# tiny-os v6: xv6's kind of kernel for tiny-machine, in C by tiny-c -tm
# and a page of .tm (docs/plans/plan_tiny_os.md):
#
#   make run          the kernel on tiny-machine, the disk fs.img: sh
#   make check        usertests, and a script through sh, on a fresh disk
#
# The kernel: entry.tm first (the machine starts at 0), the C, end.tm
# last (where the free pages start). The programs: a.out files (tiny-cpu
# -a, linked at 0x800000), start.tm first, with libc and usys.tm; the
# disk: tiny-mkfs's, the programs in its root. The tools from the PATH
# (after `dune install`), or from ix's bin/.

export PATH := $(abspath ../../../bin):$(PATH)

TC = tiny-c
CPU = tiny-cpu
MACHINE = tiny-machine
MKFS = tiny-mkfs

KERNEL = entry.tm ../libc/udivmod.tm main.tm vm.tm proc.tm fs.tm file.tm end.tm
UPROGS = init sh cat echo ls mkdir rm wc usertests
ULIB = ../libc/start.tm ../libc/udivmod.tm ../libc/libc.tm user/usys.tm

all: kernel.img fs.img

%.tm: %.c defs.h
	$(TC) -tm -o $@ $<

kernel.img: $(KERNEL)
	$(MACHINE) -o $@ $(KERNEL)

../libc/libc.tm: ../libc/libc.c ../libc/libc.h
	$(TC) -tm -o $@ $<

user/%.tm: user/%.c user/user.h
	$(TC) -tm -o $@ $<

user/bin/%: $(ULIB) user/%.tm
	@mkdir -p user/bin
	$(CPU) -a $@ $(ULIB) user/$*.tm

fs.img: $(addprefix user/bin/,$(UPROGS))
	$(MKFS) $@ $^

run: kernel.img fs.img
	$(MACHINE) -d fs.img kernel.img

# the output of both, on fresh disks, against check.expected
check: kernel.img fs.img
	cp fs.img check.img
	echo usertests | $(MACHINE) -d check.img kernel.img > check.out
	cp fs.img check.img
	printf 'echo hi | cat > f; cat f; ls f; wc f; rm f; cat f\n' | $(MACHINE) -d check.img kernel.img >> check.out
	rm -f check.img
	diff check.expected check.out && rm check.out && echo "tiny-os v6: check ok"

clean:
	rm -f kernel.img fs.img check.img check.out main.tm vm.tm proc.tm fs.tm file.tm
	rm -rf user/bin $(addprefix user/,$(addsuffix .tm,$(UPROGS)))

.PHONY: all run check clean
.SECONDARY:
