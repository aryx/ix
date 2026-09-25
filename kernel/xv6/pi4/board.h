/* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 */
/* mini-xv6 on the Pi4 (ARMv8, arm64): what runtime.c and libc.c ask of
 * the board.
 *
 * The trap frame (start.s saves it): x0-x30, sp_el0 (31), elr_el1, the
 * pc (32), spsr_el1 (33); a new process's PSTATE 0: EL0t, the
 * interrupts unmasked. A context (start.s's swtch): x19-x29, sp, lr. */

#define TF_WORDS 34
#define TF_PSR 33
#define TF_USER_PSR 0

#define CONTEXT_REGS 13
#define CONTEXT_SP 11
#define CONTEXT_LR 12

/* the kernel's addresses: the RAM and the devices seen from KERNBASE
 * (start.s's TTBR1, as xv6 arm64-pi4's) */
#define KERNBASE 0xffffff8000000000UL

/* libc.c's: the PL011, the OCaml heap's end (KERNBASE + 256MB: the
 * pages above are the processes') */
#define UART_BASE (KERNBASE + 0xFE201000UL)
#define HEAP_LIMIT (KERNBASE + 0x10000000UL)

/* usb.c's: the peripherals (0xFE000000) seen from KERNBASE; the
 * VideoCore's address of the RAM (a DMA's) */
#define IO_BASE (KERNBASE + 0xFE000000UL)
#define BUS_ALIAS 0xC0000000UL
