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
# default, or pi4). Its OCaml modules (ML below) over kernel/lib's
# (the machine: lib/kernel.mk builds the image, from the board's
# lib/pi1/ or lib/pi4/, the processes' kernel side, the C library, the
# DWC2's primitives, the OCaml Machine, Screen, Page, Arch, Mmu), and
# fs.img, the xv6 port's own (its user programs, as built in $(XV6)),
# embedded. The Pi1's a raw image loaded at 0x8000 (kernel-pi1.img),
# the Pi4's an ELF (kernel-pi4.elf).
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

# no built-in rules (kernel.mk's comment: ~/xv6's fs.img once deleted)
MAKEFLAGS += --no-builtin-rules

XV6 ?= $(HOME)/xv6
ML = Types Proc Fs File Usbhost Exec Syscall Main

# the xv6 port's file system: its user programs, usertests among them;
# its C kernel, the reference
ifeq ($(BOARD),pi4)
FS = $(XV6)/forks/arm64-pi4/fs.img
C_KERNEL = -cpu cortex-a72 -M raspi4b -kernel $(XV6)/forks/arm64-pi4/kernel/kernel -m 2G -smp 4 -nographic
else
FS = $(XV6)/forks/arm-pi1/user/fs.img
C_KERNEL = -M raspi1ap -nographic -kernel $(XV6)/forks/arm-pi1/kernel-qemu.img
endif

include ../lib/kernel.mk

# the xv6 port's image: a source, never a target
$(FS): ;

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
	$(SESSION_PY) --timeout 300 --out $(B)/c.txt $(if $(filter pi1,$(BOARD)),--screendump $(B)/c.ppm) $(SESSION) -- $(QEMU) $(C_KERNEL)
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
	$(SESSION_PY) --timeout 300 --out $(B)/mini.txt --screendump $(B)/mini.ppm $(SESSION) -- $(MINIQEMU) $(BOOT)
	$(call from_init,$(B)/mini.txt) | diff - expected-$(BOARD) && echo "ok xv6 $(BOARD): a session under mini-qemu, as xv6's"
	$(SESSION_PY) --timeout 60 --out $(B)/qemu.txt --screendump $(B)/qemu.ppm $(SESSION) -- $(QEMU) $(QEMU_BOOT)
	$(call from_init,$(B)/qemu.txt) | diff - expected-$(BOARD) && echo "ok xv6 $(BOARD): a session under QEMU, as xv6's"
	cmp $(B)/mini.ppm $(B)/qemu.ppm && echo "ok xv6 $(BOARD): the screen under mini-qemu, as under QEMU"
	$(if $(wildcard expected-$(BOARD).ppm.gz),gzip -dc expected-$(BOARD).ppm.gz | cmp - $(B)/qemu.ppm && echo "ok xv6 $(BOARD): the screen as xv6's C kernel draws it")
	$(SESSION_PY) --timeout 300 --usb --move "200,-100;-60,40" --out $(B)/mini-usb.txt --screendump $(B)/mini-usb.ppm \
	  $(USB_SESSION) -- $(MINIQEMU) $(BOOT) $(USB)
	$(SESSION_PY) --timeout 120 --usb --move "200,-100;-60,40" --out $(B)/qemu-usb.txt --screendump $(B)/qemu-usb.ppm \
	  $(USB_SESSION) -- $(QEMU) $(QEMU_BOOT) $(USB)
	$(call from_init,$(B)/mini-usb.txt) | diff - $(B)/usb-expected.txt && $(call from_init,$(B)/qemu-usb.txt) | diff - $(B)/usb-expected.txt \
	  && echo "ok xv6 $(BOARD): a session typed on the USB keyboard, under mini-qemu and QEMU"
	cmp $(B)/mini-usb.ppm $(B)/qemu-usb.ppm && echo "ok xv6 $(BOARD): the screen after the USB mouse moved, under mini-qemu as under QEMU"
	$(SESSION_PY) --until "ALL TESTS PASSED" --timeout 300 --out $(B)/usertests.txt usertests -- \
	  $(QEMU) $(QEMU_BOOT) && echo "ok xv6 $(BOARD): usertests under QEMU"

usertests-mini: $(IMAGE)
	$(SESSION_PY) --until "ALL TESTS PASSED" --timeout 7200 --out $(B)/usertests-mini.txt usertests -- \
	  $(MINIQEMU) $(BOOT) && echo "ok xv6 $(BOARD): usertests under mini-qemu"

clean:
	rm -rf build kernel-pi1.img kernel-pi4.elf

.PHONY: all run qemu check usertests-mini expected clean
