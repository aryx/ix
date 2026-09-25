@ Claude Code
@
@ Copyright (C) 2026 Yoann Padioleau
@
@ This library is free software; you can redistribute it and/or
@ modify it under the terms of the GNU Library General Public License
@ (LGPL) as published by the Free Software Foundation; either version
@ 2 of the License, or (at your option) any later version.
@
@ mini-xv6, step 5: the user program, linked at 0, each process its own
@ copy. What each does shows the timer at work:
@   process 1 spins, never making a system call: only the timer's
@     interrupt takes the CPU back from it;
@   process 2 sleeps 5 ticks, then kills process 1 and exits;
@   process 3 runs three rounds, sleeping 2 ticks after each, and exits.
@ The order of their lines depends on the ticks only: the same under
@ QEMU (whose timer follows the host's clock) and mini-qemu (whose
@ follows the instructions run).
	.text
	.global _ustart
_ustart:
	bl	getpid
	mov	r4, r0
	cmp	r4, #1
	beq	spinner
	cmp	r4, #2
	beq	killer
	ldr	r0, =hello
	bl	say
	mov	r5, #1
round:
	ldr	r0, =roundmsg
	bl	say
	mov	r0, #2
	bl	sleep
	add	r5, r5, #1
	cmp	r5, #3
	ble	round
	mov	r0, #30
	bl	exit
spin:
	b	spin

spinner:
	ldr	r0, =spinning
	bl	say
1:	add	r6, r6, #1
	b	1b

killer:
	ldr	r0, =sleeping
	bl	say
	mov	r0, #5
	bl	sleep
	ldr	r0, =killing
	bl	say
	mov	r0, #1
	bl	kill
	mov	r0, #20
	bl	exit

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
	.asciz	"process #: hello\n"
roundmsg:
	.asciz	"process #, round @\n"
spinning:
	.asciz	"process #: spinning, without a system call\n"
sleeping:
	.asciz	"process #: sleeping 5 ticks\n"
killing:
	.asciz	"process #: awake; killing process 1\n"
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
	syscall	kill, 6
	syscall	getpid, 11
	syscall	sleep, 13
	syscall	write, 16
