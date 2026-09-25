# Claude Code
#
# Copyright (C) 2026 Yoann Padioleau
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Library General Public License
# (LGPL) as published by the Free Software Foundation; either version
# 2 of the License, or (at your option) any later version.
#
# mini-xv6 (plan_kernel.md): one kernel, two boards (BOARD=pi1, the
# default, or pi4), each image from
# - the OCaml kernel (ML below; Arch.ml the board's, $(BOARD)/Arch.ml),
#   compiled by ocaml-light's backend for the board (arm, arm64) into
#   one object with the parts of the stdlib it uses (-output-obj);
# - ocaml-light's native runtime (asmrun/ and byterun/'s C, arm.S or
#   arm64.S), compiled freestanding;
# - libc.c (the C library the runtime asks for), runtime.c (the
#   processes' kernel side), and the board's machine.c (the machine's
#   primitives) and start.s (the entry, the traps, and fs.img: that xv6
#   port's own, its user programs, as built in $(XV6));
# linked by $(BOARD)/kernel.ld: the Pi1's a raw image loaded at 0x8000
# (kernel-pi1.img), the Pi4's an ELF (kernel-pi4.elf).
#
# ocaml-light for the board: ../ocaml-light.sh arm, arm64 builds it in
# $(OCL) (from ~/ocaml-light, untouched).
#
#   make [BOARD=pi4]      the image
#   make run              under mini-qemu (Ctrl-A x quits)
#   make qemu             under QEMU
#   make check            a shell session under mini-qemu and QEMU, the
#                         same as the xv6 port's C kernel's
#                         (expected-$(BOARD)); usertests under QEMU
#   make usertests-mini   usertests under mini-qemu (slow)
#   make expected         the session on the C kernel

# no built-in rules: the xv6 port's fs.img is a source here, never a
# target (make's %: %.o rule once tried to rebuild ~/xv6's from its
# fs.img.o, and the failed link deleted it: plan_kernel.md)
MAKEFLAGS += --no-builtin-rules
.SUFFIXES:

BOARD ?= pi1
XV6 ?= $(HOME)/xv6
B = build/$(BOARD)
MINIQEMU = ../../_build/default/raspberry/Main.exe

ifeq ($(BOARD),pi1)
# the Pi1: ARMv6 and its VFP, cross-compiled; xv6 arm-pi1's fs.img
OCL ?= /tmp/ix-ocaml-light-arm
CROSS = arm-linux-gnueabihf-
CPU = -march=armv6kz -mfpu=vfp -mfloat-abi=hard -marm
ASFLAGS = -march=armv6kz -mfpu=vfp -mfloat-abi=hard
TARGET = arm
FS = $(XV6)/forks/arm-pi1/user/fs.img
IMAGE = kernel-pi1.img
BOOT = -M raspi1ap -device loader,file=$(IMAGE),addr=0x8000,cpu-num=0,force-raw=on -nographic
QEMU = qemu-system-arm
QEMU_BOOT = $(BOOT)
C_KERNEL = -M raspi1ap -nographic -kernel $(XV6)/forks/arm-pi1/kernel-qemu.img
else
# the Pi4: ARMv8, this machine's own (aarch64): no cross compiler;
# no vectorizing (mini-qemu's arm64 has the scalar floating point, not
# Advanced SIMD); xv6 arm64-pi4's fs.img
OCL ?= /tmp/ix-ocaml-light-arm64
CROSS =
CPU = -mstrict-align -fno-tree-vectorize
ASFLAGS =
TARGET = arm64
FS = $(XV6)/forks/arm64-pi4/fs.img
IMAGE = kernel-pi4.elf
BOOT = -cpu cortex-a72 -M raspi4b -kernel $(IMAGE) -m 2G -nographic
# QEMU's raspi4b wants its four cores (mini-pi's QEMU64)
QEMU ?= $(or $(wildcard /media/pad/extradrive1/pad/work/TOOLCHAINS/qemu/build/qemu-system-aarch64),qemu-system-aarch64)
QEMU_BOOT = $(BOOT) -smp 4
C_KERNEL = -cpu cortex-a72 -M raspi4b -kernel $(XV6)/forks/arm64-pi4/kernel/kernel -m 2G -smp 4 -nographic
endif

OCAMLOPT = $(OCL)/bin/ocamlopt
SRC = $(OCL)/src
# freestanding: no PIE (no GOT), no stack protector, no _FORTIFY_SOURCE's
# __sprintf_chk, no 64-bit file offsets' open64 beyond what libc.c stubs
CFLAGS = $(CPU) -O2 -ffreestanding -fno-builtin -fno-pie -fno-stack-protector -U_FORTIFY_SOURCE -w \
  -I$(BOARD) -I$(SRC)/byterun -I$(SRC)/config -I$(SRC)/asmrun -DNATIVE_CODE -DTARGET_$(TARGET) -DSYS_linux_elf
ML = Types Machine Screen Arch Mmu Proc Fs File Usbhost Exec Syscall Main

# asmrun's Makefile's COBJS, less main.o (libc.c's kmain starts OCaml)
RUNTIME = startup fail roots signals misc freelist major_gc minor_gc memory alloc compare ints \
  floats str array io extern intern hash sys parsing gc_ctrl terminfo md5 obj lexing printexc \
  backtrace callback weak compact custom
RTOBJS = $(RUNTIME:%=$(B)/rt_%.o) $(B)/rt_$(TARGET).o
OBJS = $(B)/start.o $(B)/ocaml.o $(RTOBJS) $(B)/runtime.o $(B)/usb.o $(B)/machine.o $(B)/libc.o

all: $(IMAGE)

$(B):
	mkdir -p $(B)/bin
	# ocaml-light's -output-obj calls "ld -r": the board's one here
	ln -sf $$(command -v $(CROSS)ld) $(B)/bin/ld

$(B)/rt_%.o: | $(B)
	src=$(SRC)/asmrun/$*.c; [ -f $$src ] || src=$(SRC)/byterun/$*.c; $(CROSS)gcc $(CFLAGS) -c $$src -o $@

$(B)/rt_$(TARGET).o: | $(B)
	$(CROSS)gcc $(CPU) -DSYS_linux_elf -c $(SRC)/asmrun/$(TARGET).S -o $@

$(B)/%.o: %.c $(BOARD)/board.h | $(B)
	$(CROSS)gcc $(CFLAGS) -c $< -o $@

$(B)/machine.o: $(BOARD)/machine.c $(BOARD)/board.h | $(B)
	$(CROSS)gcc $(CFLAGS) -c $< -o $@

$(B)/start.o: $(BOARD)/start.s $(B)/fs.img $(B)/font.bin | $(B)
	$(CROSS)as $(ASFLAGS) $< -o $@

$(B)/ocaml.o: $(filter-out Arch.ml,$(ML:%=%.ml)) $(ML:%=%.mli) $(BOARD)/Arch.ml | $(B)
	cp $(filter-out Arch.ml,$(ML:%=%.ml)) $(ML:%=%.mli) $(BOARD)/Arch.ml $(B)/
	cd $(B) && for m in $(ML); do $(OCAMLOPT) -c $$m.mli && $(OCAMLOPT) -c $$m.ml || exit 1; done
	cd $(B) && PATH=$$PWD/bin:$$PATH $(OCAMLOPT) -output-obj -o ocaml.o $(ML:%=%.cmx)

# the xv6 port's file system: its user programs, usertests among them
$(B)/fs.img: $(FS) | $(B)
	cp $< $@

$(FS): ;

# the console's font, xv6 arm-pi1's (its framebuffer console's)
FONT = $(XV6)/kernel/data/arm-pi/font1.bin
$(B)/font.bin: $(FONT) | $(B)
	cp $< $@

$(FONT): ;

$(B)/kernel.elf: $(OBJS) $(BOARD)/kernel.ld
	$(CROSS)ld -T $(BOARD)/kernel.ld -o $@ $(OBJS)

kernel-pi1.img: $(B)/kernel.elf
	$(CROSS)objcopy -O binary $< $@

kernel-pi4.elf: $(B)/kernel.elf
	cp $< $@

run: $(IMAGE)
	$(MINIQEMU) $(BOOT)

qemu: $(IMAGE)
	$(QEMU) $(QEMU_BOOT)

# the session: what sh is typed (session.py waits for each prompt), no
# '>' (xv6 arm-pi1's C kernel panics on O_TRUNC: plan_kernel.md), no
# concurrent output (stressfs's interleaves with the timer); compared
# from init's first line on
SESSION = ls "cat README" "echo hello world" "mkdir d" "ls d" "ln README d/r" "ls d" "wc d/r" "rm d/r" \
  "grep xv6 README" forktest "cat nosuch" "sh -c"
# (xv6 arm64-pi4's other cores say "hart N starting" whenever they
# start: not the session's)
from_init = sed -n '/init: starting sh/,$$p' $(1) | grep -v '^hart [0-9] starting$$'

# the Pi1's screen too: xv6 arm-pi1's C kernel draws its console there
# (arm64-pi4's does not)
expected: | $(B)
	./session.py --timeout 300 --out $(B)/c.txt $(if $(filter pi1,$(BOARD)),--screendump $(B)/c.ppm) $(SESSION) -- $(QEMU) $(C_KERNEL)
	$(call from_init,$(B)/c.txt) > expected-$(BOARD)
	$(if $(filter pi1,$(BOARD)),gzip -n -9 < $(B)/c.ppm > expected-$(BOARD).ppm.gz)

# the USB keyboard and mouse (Usbhost.ml): a session typed on the
# keyboard, the mouse moved; its text what the same lines typed on the
# serial line print (expected-$(BOARD)'s ls, then its echo)
USB = -device usb-kbd -device usb-mouse
USB_SESSION = ls "echo hello world"
$(B)/usb-expected.txt: expected-$(BOARD) | $(B)
	sed -n '1,/^\$$ cat README$$/p' $< | sed '$$d' > $@
	sed -n '/^\$$ echo hello world$$/,/^hello world$$/p' $< >> $@
	echo '$$ ' >> $@

# the session, and the screen after it: the console on the framebuffer
# (Screen.ml), the same under mini-qemu and QEMU, and on the Pi1 the
# same as xv6 arm-pi1's C kernel's (expected-pi1.ppm.gz)
check: $(IMAGE) $(B)/usb-expected.txt
	./session.py --timeout 300 --out $(B)/mini.txt --screendump $(B)/mini.ppm $(SESSION) -- $(MINIQEMU) $(BOOT)
	$(call from_init,$(B)/mini.txt) | diff - expected-$(BOARD) && echo "ok xv6 $(BOARD): a session under mini-qemu, as xv6's"
	./session.py --timeout 60 --out $(B)/qemu.txt --screendump $(B)/qemu.ppm $(SESSION) -- $(QEMU) $(QEMU_BOOT)
	$(call from_init,$(B)/qemu.txt) | diff - expected-$(BOARD) && echo "ok xv6 $(BOARD): a session under QEMU, as xv6's"
	cmp $(B)/mini.ppm $(B)/qemu.ppm && echo "ok xv6 $(BOARD): the screen under mini-qemu, as under QEMU"
	$(if $(wildcard expected-$(BOARD).ppm.gz),gzip -dc expected-$(BOARD).ppm.gz | cmp - $(B)/qemu.ppm && echo "ok xv6 $(BOARD): the screen as xv6's C kernel draws it")
	./session.py --timeout 300 --usb --move "200,-100;-60,40" --out $(B)/mini-usb.txt --screendump $(B)/mini-usb.ppm \
	  $(USB_SESSION) -- $(MINIQEMU) $(BOOT) $(USB)
	./session.py --timeout 120 --usb --move "200,-100;-60,40" --out $(B)/qemu-usb.txt --screendump $(B)/qemu-usb.ppm \
	  $(USB_SESSION) -- $(QEMU) $(QEMU_BOOT) $(USB)
	$(call from_init,$(B)/mini-usb.txt) | diff - $(B)/usb-expected.txt && $(call from_init,$(B)/qemu-usb.txt) | diff - $(B)/usb-expected.txt \
	  && echo "ok xv6 $(BOARD): a session typed on the USB keyboard, under mini-qemu and QEMU"
	cmp $(B)/mini-usb.ppm $(B)/qemu-usb.ppm && echo "ok xv6 $(BOARD): the screen after the USB mouse moved, under mini-qemu as under QEMU"
	./session.py --until "ALL TESTS PASSED" --timeout 300 --out $(B)/usertests.txt usertests -- \
	  $(QEMU) $(QEMU_BOOT) && echo "ok xv6 $(BOARD): usertests under QEMU"

usertests-mini: $(IMAGE)
	./session.py --until "ALL TESTS PASSED" --timeout 7200 --out $(B)/usertests-mini.txt usertests -- \
	  $(MINIQEMU) $(BOOT) && echo "ok xv6 $(BOARD): usertests under mini-qemu"

clean:
	rm -rf build kernel-pi1.img kernel-pi4.elf

.PHONY: all run qemu check usertests-mini expected clean
