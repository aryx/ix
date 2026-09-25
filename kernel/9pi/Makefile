# Claude Code
#
# Copyright (C) 2026 Yoann Padioleau
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Library General Public License
# (LGPL) as published by the Free Software Foundation; either version
# 2 of the License, or (at your option) any later version.
#
# mini-9pi (plan_9pi.md): principia's Plan 9 kernel for the Pi1, in
# OCaml. Its modules (ML below) over kernel/lib's machine (lib/kernel.mk
# builds the image), and 9pi's bootdir embedded (mkbootdir.py: the
# programs from ~/principia that 9pi links into its own image).
#
#   make            kernel-pi1.img
#   make run        under mini-qemu (Ctrl-A x quits)
#   make qemu       under QEMU
#   make check      the boot under mini-qemu and QEMU, its console as
#                   expected (stage A: /boot/echo's hello)

MAKEFLAGS += --no-builtin-rules

PRINCIPIA ?= $(HOME)/principia
ML = Types Dev Proc Devroot Devcons Chan Exec Syscall Main

# the bootdir, as kernel/conf/arm/pi's: boot.rc as /boot/boot
BIN = $(PRINCIPIA)/ROOT/arch/arm/bin
BOOTDIR = boot=$(PRINCIPIA)/kernel/init/user/boot/arm/boot.rc rcmain=$(PRINCIPIA)/ROOT/rc/lib/rcmain \
  $(foreach p,rc echo bind fdisk dossrv mount ls,$(p)=$(BIN)/$(p))
FS = build/$(BOARD)/bootdir

include ../lib/kernel.mk

$(FS): mkbootdir.py | $(B)
	./mkbootdir.py $@ $(BOOTDIR)

run: $(IMAGE)
	$(MINIQEMU) $(BOOT)

qemu: $(IMAGE)
	$(QEMU) $(QEMU_BOOT)

# the console until the boot process ends (session.py drops the CRs)
check: $(IMAGE)
	$(SESSION_PY) --until "boot process died: unknown" --timeout 60 --out $(B)/mini.txt -- $(MINIQEMU) $(BOOT)
	diff $(B)/mini.txt expected && echo "ok 9pi: the boot under mini-qemu"
	$(SESSION_PY) --until "boot process died: unknown" --timeout 60 --out $(B)/qemu.txt -- $(QEMU) $(QEMU_BOOT)
	diff $(B)/qemu.txt expected && echo "ok 9pi: the boot under QEMU"

clean:
	rm -rf build kernel-pi1.img kernel-pi4.elf

.PHONY: all run qemu check clean
