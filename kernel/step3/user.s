@ Claude Code
@
@ Copyright (C) 2026 Yoann Padioleau
@
@ This library is free software; you can redistribute it and/or
@ modify it under the terms of the GNU Library General Public License
@ (LGPL) as published by the Free Software Foundation; either version
@ 2 of the License, or (at your option) any later version.
@
@ mini-xv6, step 3: the user program each process runs (its own user
@ stack, its own kernel stack): three rounds of "process P, round R",
@ sleeping between them, then exit(10 * P). Its system calls as xv6
@ arm-pi1's usys.S makes them.
	.text
	.global user_main
user_main:
	bl	getpid
	mov	r4, r0			@ P
	mov	r5, #1			@ R
round:
	@ the line copied to the stack, its two digits set
	sub	sp, sp, #24
	ldr	r0, =line
	mov	r2, #0
copy:
	ldrb	r3, [r0, r2]
	strb	r3, [sp, r2]
	add	r2, r2, #1
	cmp	r3, #0
	bne	copy
	add	r3, r4, #48
	strb	r3, [sp, #8]
	add	r3, r5, #48
	strb	r3, [sp, #17]
	mov	r0, #1
	mov	r1, sp
	mov	r2, #19
	bl	write
	add	sp, sp, #24
	mov	r0, #1
	bl	sleep
	add	r5, r5, #1
	cmp	r5, #3
	ble	round
	mov	r0, r4, lsl #1
	add	r0, r0, r4, lsl #3	@ 10 * P
	bl	exit
spin:
	b	spin

line:
	.asciz	"process P, round R\n"
	.align	2

@ the calls: the arguments pushed, the number in r0, swi 0x40
	.macro	syscall name, number
\name:
	push	{lr}
	push	{r3}
	push	{r2}
	push	{r1}
	push	{r0}
	mov	r0, #\number
	swi	#0x40
	pop	{r1}
	pop	{r1}
	pop	{r2}
	pop	{r3}
	pop	{lr}
	bx	lr
	.endm

	syscall	exit, 2
	syscall	getpid, 11
	syscall	sleep, 13
	syscall	write, 16
