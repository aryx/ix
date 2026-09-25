@ Claude Code
@
@ Copyright (C) 2026 Yoann Padioleau
@
@ This library is free software; you can redistribute it and/or
@ modify it under the terms of the GNU Library General Public License
@ (LGPL) as published by the Free Software Foundation; either version
@ 2 of the License, or (at your option) any later version.
@
@ mini-xv6, step 4: the user program, linked at 0 (user.ld) as xv6 arm-pi1's
@ are, each process running its own copy in its own pages. What each
@ does shows the MMU at work:
@   process 1 reads the kernel's memory (0x80008000): a permission
@     fault, and the kernel kills it;
@   process 2 gives write() a pointer to nothing (0x300000), which the
@     kernel refuses (-1), then reads there itself: a translation
@     fault, killed;
@   process 3 runs three rounds, sleeping between, and exits.
	.text
	.global _ustart
_ustart:
	bl	getpid
	mov	r4, r0
	ldr	r0, =hello
	bl	say
	cmp	r4, #1
	beq	kernel_touch
	cmp	r4, #2
	beq	bad_pointer
	mov	r5, #1
round:
	ldr	r0, =roundmsg
	bl	say
	mov	r0, #1
	bl	sleep
	add	r5, r5, #1
	cmp	r5, #3
	ble	round
	mov	r0, #30
	bl	exit
spin:
	b	spin

kernel_touch:
	ldr	r0, =touch
	bl	say
	ldr	r0, =0x80008000
	ldr	r0, [r0]
	b	spin

bad_pointer:
	mov	r0, #1
	ldr	r1, =0x300000
	mov	r2, #5
	bl	write
	cmn	r0, #1
	bne	spin
	ldr	r0, =refused
	bl	say
	ldr	r0, =0x300000
	ldr	r0, [r0]
	b	spin

@ say(s): the string at r0, its first '#' replaced by the pid (r4) and
@ its first '@' by the round (r5), copied to the stack and written
say:
	push	{r4, r5, r6, lr}
	sub	sp, sp, #64
	mov	r2, #0
1:	ldrb	r3, [r0, r2]
	cmp	r3, #'#'
	addeq	r3, r4, #'0'
	cmp	r3, #'@'
	addeq	r3, r5, #'0'
	strb	r3, [sp, r2]
	add	r2, r2, #1
	cmp	r3, #0
	bne	1b
	sub	r2, r2, #1
	mov	r1, sp
	mov	r0, #1
	bl	write
	add	sp, sp, #64
	pop	{r4, r5, r6, pc}

hello:
	.asciz	"process #: hello, from my own pages at 0\n"
roundmsg:
	.asciz	"process #, round @\n"
touch:
	.asciz	"process #: now reading the kernel's memory\n"
refused:
	.asciz	"process #: write() refused a bad pointer; now reading it myself\n"
	.align	2

@ the calls: the arguments pushed, the number in r0, swi 0x40 (xv6 arm-pi1's)
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
