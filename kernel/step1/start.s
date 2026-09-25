@ Claude Code
@
@ Copyright (C) 2026 Yoann Padioleau
@
@ This library is free software; you can redistribute it and/or
@ modify it under the terms of the GNU Library General Public License
@ (LGPL) as published by the Free Software Foundation; either version
@ 2 of the License, or (at your option) any later version.
@
@ mini-xv6's first instructions (plan_kernel.md, step 1): loaded at
@ 0x8000 and entered in SVC mode with IRQ and FIQ masked, as the Pi1's
@ firmware starts kernel.img (and QEMU's loader a raw image). A stack,
@ the VFP on (ocaml-light's runtime is compiled hard-float: its float
@ code and its calling convention use the VFP registers), the bss
@ cleared, then C's kmain, which starts OCaml.
	.section .text.start
	.global _start
_start:
	ldr	sp, =stack_top
	@ the coprocessor access register: cp10 and cp11 (the VFP), full
	mrc	p15, 0, r0, c1, c0, 2
	orr	r0, r0, #0xf00000
	mcr	p15, 0, r0, c1, c0, 2
	@ FPEXC.EN
	mov	r0, #0x40000000
	vmsr	fpexc, r0
	ldr	r0, =__bss_start
	ldr	r1, =__bss_end
	mov	r2, #0
clear:
	cmp	r0, r1
	strlo	r2, [r0], #4
	blo	clear
	bl	kmain
halt:
	wfi
	b	halt
