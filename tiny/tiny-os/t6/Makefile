# Claude Code
#
# Copyright (C) 2026 Yoann Padioleau
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Library General Public License
# (LGPL) as published by the Free Software Foundation; either version
# 2 of the License, or (at your option) any later version.
#
# t6, tiny-os's free kernel (docs/plans/plan_tiny_os.md):
#
#   make run          the kernel on tiny-machine, the disk fs.img: sh
#   make check        t6tests, and a script through sh, on a fresh disk
#
# The kernel: entry.tm first (the machine starts at 0), then the C. The
# programs are tiny-cpu's own images (tiny-cpu -o, linked at 0: t6 runs
# each at the start of its partition), start.tm first, with libc and
# sys.tm; the disk is a FAT (tiny-mkfs -fat). The tools from the PATH
# (after `dune install`), or from ix's bin/.

export PATH := $(abspath ../../../bin):$(PATH)

TC = tiny-c
CPU = tiny-cpu
MACHINE = tiny-machine
MKFS = tiny-mkfs

KERNEL = entry.tm ../libc/udivmod.tm main.tm proc.tm file.tm
UPROGS = init sh cat echo ls mkdir rm wc t6tests
ULIB = ../libc/start.tm ../libc/udivmod.tm ../libc/libc.tm user/sys.tm

all: kernel.img fs.img

%.tm: %.c t6.h
	$(TC) -tm -o $@ $<

kernel.img: $(KERNEL)
	$(MACHINE) -o $@ $(KERNEL)

../libc/libc.tm: ../libc/libc.c ../libc/libc.h
	$(TC) -tm -o $@ $<

user/%.tm: user/%.c user/user.h
	$(TC) -tm -o $@ $<

user/bin/%: $(ULIB) user/%.tm
	@mkdir -p user/bin
	$(CPU) -o $@ $(ULIB) user/$*.tm

fs.img: $(addprefix user/bin/,$(UPROGS))
	$(MKFS) -fat $@ $^

run: kernel.img fs.img
	$(MACHINE) -d fs.img kernel.img

# the output of both, on fresh disks, against check.expected
check: kernel.img fs.img
	cp fs.img check.img
	echo t6tests | timeout 120 $(MACHINE) -d check.img kernel.img > check.out
	cp fs.img check.img
	printf 'echo hi | cat > f; cat f; ls; wc < f; rm f; cat f\n' | timeout 120 $(MACHINE) -d check.img kernel.img >> check.out
	rm -f check.img
	diff check.expected check.out && rm check.out && echo "tiny-os t6: check ok"

clean:
	rm -f kernel.img fs.img check.img check.out main.tm proc.tm file.tm
	rm -rf user/bin $(addprefix user/,$(addsuffix .tm,$(UPROGS)))

.PHONY: all run check clean
.SECONDARY:
