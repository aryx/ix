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
# The SD card is principia's (qemu-sd.img: its FAT, served by dossrv,
# the root), its writes kept in memory (snapshot=on).
#
#   make run        under mini-qemu (Ctrl-A x quits)
#   make qemu       under QEMU
#   make check      stage C's session (raspberry/tests/9pi.py's, typed
#                   at the boot's rc: tests/session-c.cmds) under
#                   mini-qemu and QEMU, the console as tests/session-c:
#                   the C 9pi's under QEMU but hoc's pid (40, 9pi's 48:
#                   its usbd's processes, stage D); step D1's (the
#                   processes: sleep, a kill by note, plumber's threads
#                   and mount: tests/session-d); then stage B's
#                   (tests/boot-b.rc as /boot/boot, no card: the
#                   namespace, the environment, pipes, processes;
#                   tests/session-b)

MAKEFLAGS += --no-builtin-rules

PRINCIPIA ?= $(HOME)/principia
ML = Types Dev Proc Chan Devroot Devcons Devenv Devsys Devarch Devdup Devsrv Devpipe Devproc Emmc Devsd P9 Devmnt Fault Exec Syscall Main

# the bootdir, as kernel/conf/arm/pi's: boot.rc as /boot/boot (or a
# test's script: BOOTRC)
BIN = $(PRINCIPIA)/ROOT/arch/arm/bin
BOOTRC ?= $(PRINCIPIA)/kernel/init/user/boot/arm/boot.rc
BOOTDIR = boot=$(BOOTRC) rcmain=$(PRINCIPIA)/ROOT/rc/lib/rcmain \
  $(foreach p,rc echo bind fdisk dossrv mount ls,$(p)=$(BIN)/$(p))
FS = $(B)/bootdir

# the devices' files' date: 9pi's (its conf compiled with
# -DKERNDATE=`date -n`: kerndate.py finds it in 9pi's image), so that
# their entries are 9pi's
KERNDATE ?= $(shell ./kerndate.py $(PRINCIPIA))

include ../lib/kernel.mk

SD = -drive file=$(PRINCIPIA)/qemu-sd.img,if=sd,format=raw,snapshot=on

$(FS): mkbootdir.py $(BOOTRC) | $(B)
	./mkbootdir.py $@ $(KERNDATE) $(BOOTDIR)

run: $(IMAGE)
	$(MINIQEMU) $(BOOT) $(SD)

qemu: $(IMAGE)
	$(QEMU) $(QEMU_BOOT) $(SD)

check: $(IMAGE) kernel-pi1-b.img
	$(SESSION_PY) --prompt "% " --timeout 300 --out $(B)/mini-c.txt --lines tests/session-c.cmds -- $(MINIQEMU) $(BOOT) $(SD)
	diff $(B)/mini-c.txt tests/session-c && echo "ok 9pi: stage C's session under mini-qemu"
	$(SESSION_PY) --prompt "% " --timeout 120 --out $(B)/qemu-c.txt --lines tests/session-c.cmds -- $(QEMU) $(QEMU_BOOT) $(SD)
	diff $(B)/qemu-c.txt tests/session-c && echo "ok 9pi: stage C's session under QEMU"
	$(SESSION_PY) --prompt "% " --timeout 300 --out $(B)/mini-d.txt --lines tests/session-d.cmds -- $(MINIQEMU) $(BOOT) $(SD)
	diff $(B)/mini-d.txt tests/session-d && echo "ok 9pi: step D1's session under mini-qemu"
	$(SESSION_PY) --prompt "% " --timeout 120 --out $(B)/qemu-d.txt --lines tests/session-d.cmds -- $(QEMU) $(QEMU_BOOT) $(SD)
	diff $(B)/qemu-d.txt tests/session-d && echo "ok 9pi: step D1's session under QEMU"
	$(SESSION_PY) --prompt "% " --timeout 120 --out $(B)/mini-b.txt --lines tests/session-b.cmds -- $(MINIQEMU) $(BOOT_B)
	diff $(B)/mini-b.txt tests/session-b && echo "ok 9pi: stage B's session under mini-qemu"
	$(SESSION_PY) --prompt "% " --timeout 60 --out $(B)/qemu-b.txt --lines tests/session-b.cmds -- $(QEMU) $(BOOT_B)
	diff $(B)/qemu-b.txt tests/session-b && echo "ok 9pi: stage B's session under QEMU"

# stage B's image: its own build directory, tests/boot-b.rc as /boot/boot
# (the rule in the outer make only: the inner one builds it as IMAGE)
ifneq ($(IMAGE),kernel-pi1-b.img)
kernel-pi1-b.img: FORCE
	$(MAKE) B=build/pi1-b IMAGE=$@ BOOTRC=tests/boot-b.rc $@
endif

BOOT_B = $(subst $(IMAGE),kernel-pi1-b.img,$(BOOT))

FORCE:

clean:
	rm -rf build kernel-pi1.img kernel-pi1-b.img kernel-pi4.elf

.PHONY: all run qemu check clean FORCE
