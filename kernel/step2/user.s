@ Claude Code
@
@ Copyright (C) 2026 Yoann Padioleau
@
@ This library is free software; you can redistribute it and/or
@ modify it under the terms of the GNU Library General Public License
@ (LGPL) as published by the Free Software Foundation; either version
@ 2 of the License, or (at your option) any later version.
@
@ mini-xv6, step 2: a user program, run in user mode. Its system calls
@ as xv6 arm-pi1's user library makes them (ulib/usys.S): the
@ arguments pushed on the stack, the call's number in r0, swi 0x40.
@ Linked in the kernel's image (no memory of its own yet, no
@ protection: steps 3 and 4).
	.text
	.global user_main
user_main:
	mov	r0, #1
	ldr	r1, =hello
	mov	r2, #hello_end - hello
	bl	write
	mov	r0, #7
	bl	exit
spin:
	b	spin

write:
	push	{lr}
	push	{r3}
	push	{r2}
	push	{r1}
	push	{r0}
	mov	r0, #16			@ SYS_write
	swi	#0x40			@ T_SYSCALL
	pop	{r1}			@ (r0 holds the result)
	pop	{r1}
	pop	{r2}
	pop	{r3}
	pop	{lr}
	bx	lr

exit:
	push	{lr}
	push	{r3}
	push	{r2}
	push	{r1}
	push	{r0}
	mov	r0, #2			@ SYS_exit
	swi	#0x40
	b	spin

hello:
	.ascii	"hello, from user mode\n"
hello_end:

	.bss
	.align	3
	.global user_stack_top
	.space	4096
user_stack_top:
