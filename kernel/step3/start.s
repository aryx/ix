@ Claude Code
@
@ Copyright (C) 2026 Yoann Padioleau
@
@ This library is free software; you can redistribute it and/or
@ modify it under the terms of the GNU Library General Public License
@ (LGPL) as published by the Free Software Foundation; either version
@ 2 of the License, or (at your option) any later version.
@
@ mini-xv6, step 3 (plan_kernel.md): what OCaml cannot say. Step 2's
@ entry and trap, with a trap frame per process (cur_tf, the running
@ one's, which the scheduler sets), and swtch: from one kernel stack to
@ another, the callee-saved registers kept in a context.
@
@ A trap frame, 17 words: r0-r12, the user's sp and lr, the pc to go
@ back to, the user's CPSR.
	.section .text.start
	.global _start
_start:
	@ a stack for each mode (IRQ, undefined, abort), then SVC's, the kernel's
	cps	#0x12
	ldr	sp, =irq_stack_top
	cps	#0x1b
	ldr	sp, =und_stack_top
	cps	#0x17
	ldr	sp, =abt_stack_top
	cps	#0x13
	ldr	sp, =stack_top
	@ the VFP on (step 1)
	mrc	p15, 0, r0, c1, c0, 2
	orr	r0, r0, #0xf00000
	mcr	p15, 0, r0, c1, c0, 2
	mov	r0, #0x40000000
	vmsr	fpexc, r0
	ldr	r0, =__bss_start
	ldr	r1, =__bss_end
	mov	r2, #0
clear:
	cmp	r0, r1
	strlo	r2, [r0], #4
	blo	clear
	@ the vectors at 0: eight "ldr pc, [pc, #24]" and their addresses
	ldr	r0, =vectors
	mov	r1, #0
	ldmia	r0!, {r2-r9}
	stmia	r1!, {r2-r9}
	ldmia	r0!, {r2-r9}
	stmia	r1!, {r2-r9}
	bl	kmain
halt:
	wfi
	b	halt

vectors:
	ldr	pc, [pc, #24]		@ 0x00 reset
	ldr	pc, [pc, #24]		@ 0x04 undefined
	ldr	pc, [pc, #24]		@ 0x08 svc
	ldr	pc, [pc, #24]		@ 0x0c prefetch abort
	ldr	pc, [pc, #24]		@ 0x10 data abort
	ldr	pc, [pc, #24]		@ 0x14 (unused)
	ldr	pc, [pc, #24]		@ 0x18 IRQ
	ldr	pc, [pc, #24]		@ 0x1c FIQ
	.word	_start, undefined_entry, svc_entry, prefetch_entry, data_entry, _start, _start, _start

@ a system call: in SVC mode, lr the user's next instruction, SPSR its
@ CPSR, sp the kernel's stack where the kernel left it when it entered
@ user mode (below the frames of the OCaml code that did: the GC's view
@ of the stack stays whole)
svc_entry:
	str	r0, [sp, #-4]!		@ r0 aside
	ldr	r0, =cur_tf
	ldr	r0, [r0]
	stmib	r0, {r1-r12}		@ words 1-12
	add	r0, r0, #52
	stmia	r0, {sp, lr}^		@ 13, 14: the user's sp and lr
	nop				@ (no banked register the next instruction)
	sub	r0, r0, #52
	str	lr, [r0, #60]		@ 15: where to go back
	mrs	r1, spsr
	str	r1, [r0, #64]		@ 16: the user's CPSR
	ldr	r1, [sp], #4
	str	r1, [r0]		@ 0: the user's r0
	bl	trap

@ to user mode, from the trap frame (also the first time: user_enter)
	.global user_return
user_return:
	ldr	r0, =cur_tf
	ldr	r0, [r0]
	ldr	r1, [r0, #64]
	msr	spsr_cxsf, r1
	ldr	lr, [r0, #60]
	add	r1, r0, #52
	ldmia	r1, {sp, lr}^
	nop
	ldmia	r0, {r0-r12}
	movs	pc, lr

@ swtch(from, to): the callee-saved registers (r4-r11, d8-d15), sp and
@ lr into the context at r0, those of the context at r1 back; returns
@ where [to] called swtch (or, the first time, to its lr: the new
@ process's trampoline). machine.c's k_swtch wraps it with the
@ runtime's view of the stack.
	.global swtch
swtch:
	stmia	r0!, {r4-r11, sp, lr}
	vstmia	r0, {d8-d15}
	ldmia	r1!, {r4-r11, sp, lr}
	vldmia	r1, {d8-d15}
	bx	lr

@ the faults: named, the machine halted (the steps after this one kill
@ the process instead)
undefined_entry:
	mov	r0, #1
	b	fault
prefetch_entry:
	mov	r0, #2
	b	fault
data_entry:
	mov	r0, #3
fault:
	mov	r1, lr
	bl	kfault
	b	halt
