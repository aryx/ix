# Claude Code
#
# Copyright (C) 2026 Yoann Padioleau
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Library General Public License
# (LGPL) as published by the Free Software Foundation; either version
# 2 of the License, or (at your option) any later version.
#
# mini-xv6 (plan_kernel.md): kernel.img, the Pi1's, linked at
# KERNBASE + 0x8000 and loaded at 0x8000 (kernel.ld), from
# - the OCaml kernel (ML below), compiled by ocaml-light's arm backend
#   into one object with the parts of the stdlib it uses (-output-obj);
# - ocaml-light's native runtime (asmrun/ and byterun/'s C, arm.S),
#   compiled freestanding for the Pi1's ARMv6 and its VFP;
# - libc.c (the C library the runtime asks for), machine.c (the
#   machine's primitives), start.s (the entry, the traps, and fs.img:
#   xv6 arm-pi1's own, its user programs, as built in $(XV6));
# linked at 0x8000 (kernel.ld), then a raw image.
#
# ocaml-light cross-compiled for arm: ../ocaml-light.sh builds it in $(OCL)
# (from ~/ocaml-light, untouched).
#
#   make            kernel.img
#   make run        under mini-qemu (Ctrl-A x quits)
#   make qemu       under QEMU's raspi1ap
#   make check      a shell session under mini-qemu and QEMU, the same as
#                   xv6 arm-pi1's C kernel's (expected); usertests under
#                   QEMU
#   make usertests-mini   usertests under mini-qemu (slow)
#   make expected   the session on the C kernel ($(XV6)'s kernel-qemu.img)

OCL ?= /tmp/ix-ocaml-light-arm
OCAMLOPT = $(OCL)/bin/ocamlopt
SRC = $(OCL)/src
CROSS = arm-linux-gnueabihf-
CPU = -march=armv6kz -mfpu=vfp -mfloat-abi=hard -marm
# freestanding: no PIE (no GOT), no _FORTIFY_SOURCE's __sprintf_chk, no
# 64-bit file offsets' open64 beyond what libc.c stubs
CFLAGS = $(CPU) -O2 -ffreestanding -fno-builtin -fno-pie -U_FORTIFY_SOURCE -w -I$(SRC)/byterun -I$(SRC)/config -I$(SRC)/asmrun -DNATIVE_CODE -DTARGET_arm -DSYS_linux_elf
RTFLAGS = $(CFLAGS) -I$(SRC)/byterun -I$(SRC)/config -DNATIVE_CODE -DTARGET_arm -DSYS_linux_elf
B = build
XV6 ?= $(HOME)/xv6
ML = Types Machine Mmu Proc Fs File Exec Syscall Main

# asmrun's Makefile's COBJS, less main.o (libc.c's kmain starts OCaml)
RUNTIME = startup fail roots signals misc freelist major_gc minor_gc memory alloc compare ints \
  floats str array io extern intern hash sys parsing gc_ctrl terminfo md5 obj lexing printexc \
  backtrace callback weak compact custom
RTOBJS = $(RUNTIME:%=$(B)/rt_%.o) $(B)/rt_arm.o

all: kernel.img

$(B):
	mkdir -p $(B)/bin
	# ocaml-light's -output-obj calls "ld -r": the ARM one here
	ln -sf $$(command -v $(CROSS)ld) $(B)/bin/ld

$(B)/rt_%.o: | $(B)
	src=$(SRC)/asmrun/$*.c; [ -f $$src ] || src=$(SRC)/byterun/$*.c; $(CROSS)gcc $(RTFLAGS) -c $$src -o $@

$(B)/rt_arm.o: | $(B)
	$(CROSS)gcc $(CPU) -DSYS_linux_elf -c $(SRC)/asmrun/arm.S -o $@

$(B)/%.o: %.c | $(B)
	$(CROSS)gcc $(CFLAGS) -c $< -o $@

$(B)/%.o: %.s | $(B)
	$(CROSS)as -march=armv6kz -mfpu=vfp -mfloat-abi=hard $< -o $@

$(B)/ocaml.o: $(ML:%=%.ml) $(ML:%=%.mli) | $(B)
	cp $(ML:%=%.ml) $(ML:%=%.mli) $(B)/
	cd $(B) && for m in $(ML); do $(OCAMLOPT) -c $$m.mli && $(OCAMLOPT) -c $$m.ml || exit 1; done
	cd $(B) && PATH=$$PWD/bin:$$PATH $(OCAMLOPT) -output-obj -o ocaml.o $(ML:%=%.cmx)

# xv6 arm-pi1's file system: its user programs, usertests among them
$(B)/fs.img: $(XV6)/forks/arm-pi1/user/fs.img | $(B)
	cp $< $@

$(B)/start.o: $(B)/fs.img

kernel.elf: $(B)/start.o $(B)/libc.o $(B)/machine.o $(B)/ocaml.o $(RTOBJS) kernel.ld
	$(CROSS)ld -T kernel.ld -o $@ $(B)/start.o $(B)/ocaml.o $(RTOBJS) $(B)/machine.o $(B)/libc.o

kernel.img: kernel.elf
	$(CROSS)objcopy -O binary $< $@

LOADER = loader,file=kernel.img,addr=0x8000,cpu-num=0,force-raw=on

MINIQEMU = ../../_build/default/raspberry/Main.exe
QEMU = qemu-system-arm

run: kernel.img
	$(MINIQEMU) -M raspi1ap -device $(LOADER) -nographic

qemu: kernel.img
	$(QEMU) -M raspi1ap -device $(LOADER) -nographic

# the session: what sh is typed (session.py waits for each prompt), no
# '>' (xv6 arm-pi1's C kernel panics on O_TRUNC: plan_kernel.md), no
# concurrent output (stressfs's interleaves with the timer); compared
# from init's first line on
SESSION = ls "cat README" "echo hello world" "mkdir d" "ls d" "ln README d/r" "ls d" "wc d/r" "rm d/r" \
  "grep xv6 README" forktest "cat nosuch" "sh -c"
FROM_INIT = sed -n '/init: starting sh/,$$p'

expected:
	./session.py --timeout 300 --out $(B)/c.txt $(SESSION) -- $(QEMU) -M raspi1ap -nographic -kernel $(XV6)/forks/arm-pi1/kernel-qemu.img
	$(FROM_INIT) $(B)/c.txt > expected

check: kernel.img
	./session.py --timeout 300 --out $(B)/mini.txt $(SESSION) -- $(MINIQEMU) -M raspi1ap -device $(LOADER) -nographic
	$(FROM_INIT) $(B)/mini.txt | diff - expected && echo "ok xv6: a session under mini-qemu, as xv6's"
	./session.py --timeout 60 --out $(B)/qemu.txt $(SESSION) -- $(QEMU) -M raspi1ap -device $(LOADER) -nographic
	$(FROM_INIT) $(B)/qemu.txt | diff - expected && echo "ok xv6: a session under QEMU, as xv6's"
	./session.py --until "ALL TESTS PASSED" --timeout 300 --out $(B)/usertests.txt usertests -- \
	  $(QEMU) -M raspi1ap -device $(LOADER) -nographic && echo "ok xv6: usertests under QEMU"

usertests-mini: kernel.img
	./session.py --until "ALL TESTS PASSED" --timeout 7200 --out $(B)/usertests-mini.txt usertests -- \
	  $(MINIQEMU) -M raspi1ap -device $(LOADER) -nographic && echo "ok xv6: usertests under mini-qemu"

clean:
	rm -rf $(B) kernel.elf kernel.img

.PHONY: all run qemu check usertests-mini expected clean
