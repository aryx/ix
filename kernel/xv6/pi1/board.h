/* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 */
/* mini-xv6 on the Pi1 (ARMv6, arm32): what runtime.c asks of the board.
 *
 * The trap frame (start.s saves it): r0-r12, sp (13), lr (14), the pc
 * (15), the CPSR (16). A context (start.s's swtch): r4-r11, sp, lr. */

#define TF_WORDS 17
#define TF_PSR 16
#define TF_USER_PSR 0x10        /* USR, IRQs and FIQs on (no FIQ is ever enabled) */

/* the kernel's addresses: the RAM seen from KERNBASE (start.s) */
#define KERNBASE 0x80000000UL

#define CONTEXT_REGS 10
#define CONTEXT_SP 8
#define CONTEXT_LR 9

/* libc.c's: the PL011 (the devices at 0xFE000000: start.s), the OCaml
 * heap's end (KERNBASE + 256MB: the pages above are the processes') */
#define UART_BASE 0xFE201000UL
#define HEAP_LIMIT 0x90000000UL

/* usb.c's: the peripherals (0x20000000) where start.s maps them; the
 * VideoCore's address of the RAM (a DMA's) */
#define IO_BASE 0xFE000000UL
#define BUS_ALIAS 0x40000000UL
