/* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 */
/* mini-xv6 on the Pi4 (plan_kernel.md), xv6 arm64-pi4's layout: linked
 * at KERNBASE + 0x80000, loaded at 0x80000 (the ELF's physical
 * addresses: QEMU's and mini-qemu's -kernel load it there and start
 * start.s at them, the MMU off); its bss; a 64KB stack; then [end],
 * where libc.c's malloc starts the OCaml heap. */
ENTRY(_start)
SECTIONS
{
  . = 0xffffff8000080000;
  .text : AT(0x80000) { *(.text.start) *(.text*) }
  .rodata : { *(.rodata*) }
  .data : { *(.data*) }
  . = ALIGN(4096);
  __bss_start = .;
  .bss : { *(.bss*) *(COMMON) }
  . = ALIGN(16);
  __bss_end = .;
  . = . + 0x10000;
  stack_top = .;
  end = .;
}
