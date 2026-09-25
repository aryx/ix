# Claude Code
#
# Copyright (C) 2026 Yoann Padioleau
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Library General Public License
# (LGPL) as published by the Free Software Foundation; either version
# 2 of the License, or (at your option) any later version.
#
# mini-xv6 (plan_kernel.md): kernel.img, the Pi1's, from
# - the OCaml program (Main.ml), compiled by ocaml-light's arm backend
#   into one object with the parts of the stdlib it uses (-output-obj);
# - ocaml-light's native runtime (asmrun/ and byterun/'s C, arm.S),
#   compiled freestanding for the Pi1's ARMv6 and its VFP;
# - libc.c (the C library the runtime asks for), start.s (the entry);
# linked at 0x8000 (kernel.ld), then a raw image.
#
# ocaml-light cross-compiled for arm: ../ocaml-light.sh builds it in $(OCL)
# (from ~/ocaml-light, untouched).
#
#   make            kernel.img
#   make run        under mini-qemu (Ctrl-A x quits)
#   make qemu       under QEMU's raspi1ap

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

$(B)/ocaml.o: Main.ml | $(B)
	cp Main.ml $(B)/Main.ml
	cd $(B) && PATH=$$PWD/bin:$$PATH $(OCAMLOPT) -output-obj -o ocaml.o Main.ml

kernel.elf: $(B)/start.o $(B)/libc.o $(B)/machine.o $(B)/user.o $(B)/ocaml.o $(RTOBJS) kernel.ld
	$(CROSS)ld -T kernel.ld -o $@ $(B)/start.o $(B)/ocaml.o $(RTOBJS) $(B)/machine.o $(B)/libc.o $(B)/user.o

kernel.img: kernel.elf
	$(CROSS)objcopy -O binary $< $@

LOADER = loader,file=kernel.img,addr=0x8000,cpu-num=0,force-raw=on

run: kernel.img
	../../_build/default/raspberry/Main.exe -M raspi1ap -device $(LOADER) -nographic

qemu: kernel.img
	qemu-system-arm -M raspi1ap -device $(LOADER) -nographic

clean:
	rm -rf $(B) kernel.elf kernel.img

.PHONY: all run qemu clean
