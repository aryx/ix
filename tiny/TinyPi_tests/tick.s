@ TinyPi's kernel, a page: the modes, the three exceptions, a timer's
@ interrupts, on a Pi1 (TinyPi_test.sh runs it under TinyPi, mini-qemu
@ and QEMU's raspi1ap, the output the same). Loaded at 0x8000, entered
@ in SVC mode with IRQ and FIQ masked, as the Pi1's firmware starts
@ kernel.img. Its console: the PL011.
	.text
	.global _start
_start:
	@ a stack for each mode: IRQ's, UND's, then SVC's (the mode we are in)
	msr cpsr_c, #0xd2
	ldr sp, =0x7000
	msr cpsr_c, #0xdb
	ldr sp, =0x6000
	msr cpsr_c, #0xd3
	ldr sp, =0x8000
	@ the vectors at 0: eight "ldr pc, [pc, #24]" and their eight addresses
	ldr r0, =vectors
	mov r1, #0
	ldmia r0!, {r2, r3, r4, r5, r6, r7, r8, r9}
	stmia r1!, {r2, r3, r4, r5, r6, r7, r8, r9}
	ldmia r0!, {r2, r3, r4, r5, r6, r7, r8, r9}
	stmia r1!, {r2, r3, r4, r5, r6, r7, r8, r9}
	ldr r0, =hello
	bl puts
	@ to user mode: its stack set from SYS mode (the user's registers),
	@ then an exception return into it, IRQs still masked
	msr cpsr_c, #0xdf
	ldr sp, =0x5000
	msr cpsr_c, #0xd3
	msr spsr_cxsf, #0xd0
	ldr lr, =user
	movs pc, lr

@ the program: system calls, and an undefined instruction between them
user:
	ldr r0, =from_user
	svc #0			@ 0: print the string at r0
	.word 0xe7f000f0	@ undefined: the kernel skips it
	ldr r0, =back
	svc #0
	svc #1			@ 1: done; the kernel takes over
never:
	b never

@ svc: the number in the instruction's low 24 bits
svc_handler:
	push {r0, r1, r2, r3, lr}
	ldr r1, [lr, #-4]
	bic r1, r1, #0xff000000
	cmp r1, #1
	beq ticks
	bl puts
	pop {r0, r1, r2, r3, lr}
	movs pc, lr		@ back to the program, its CPSR from SPSR

@ an undefined instruction: said, and skipped (lr: the word after it)
und_handler:
	push {r0, r1, r2, r3, lr}
	ldr r0, =undefined
	bl puts
	pop {r0, r1, r2, r3, lr}
	movs pc, lr

@ svc 1: the system timer's compare 1 every 10ms, five times, then halt
ticks:
	ldr r0, =started
	bl puts
	ldr r0, =0x20003000
	ldr r1, [r0, #4]	@ CLO, the microseconds
	ldr r2, =10000
	add r1, r1, r2
	str r1, [r0, #0x10]	@ C1
	ldr r0, =0x2000b210
	mov r1, #2
	str r1, [r0]		@ enable IRQ 1: compare 1's match
	cpsie i
wait:
	wfi
	ldr r0, =count
	ldr r0, [r0]
	cmp r0, #5
	blt wait
	cpsid i
	ldr r0, =done
	bl puts
halt:
	wfi			@ IRQs masked: never wakes
	b halt

@ the timer's interrupt: the match cleared, the next compare 10ms on,
@ the count up and said; back to the interrupted instruction
irq_handler:
	push {r0, r1, r2, r3, lr}
	ldr r0, =0x20003000
	mov r1, #2
	str r1, [r0]		@ CS: compare 1's match cleared
	ldr r1, [r0, #0x10]
	ldr r2, =10000
	add r1, r1, r2
	str r1, [r0, #0x10]
	ldr r0, =count
	ldr r1, [r0]
	add r1, r1, #1
	str r1, [r0]
	ldr r0, =digit
	add r1, r1, #48
	strb r1, [r0]
	ldr r0, =tick
	bl puts
	pop {r0, r1, r2, r3, lr}
	subs pc, lr, #4

@ puts: the string at r0 to the PL011 (r0-r3 used)
puts:
	ldr r2, =0x20201000
puts_next:
	ldrb r1, [r0], #1
	cmp r1, #0
	bxeq lr
puts_wait:
	ldr r3, [r2, #0x18]
	tst r3, #0x20
	bne puts_wait
	str r1, [r2]
	b puts_next

vectors:
	ldr pc, [pc, #24]	@ 0x00 reset
	ldr pc, [pc, #24]	@ 0x04 undefined
	ldr pc, [pc, #24]	@ 0x08 svc
	ldr pc, [pc, #24]	@ 0x0c prefetch abort
	ldr pc, [pc, #24]	@ 0x10 data abort
	ldr pc, [pc, #24]	@ 0x14 (unused)
	ldr pc, [pc, #24]	@ 0x18 IRQ
	ldr pc, [pc, #24]	@ 0x1c FIQ
	.word _start, und_handler, svc_handler, _start, _start, _start, irq_handler, _start

count:
	.word 0
hello:
	.asciz "TinyPi: a kernel, in SVC mode\n"
from_user:
	.asciz "user: hello, from user mode\n"
back:
	.asciz "user: back from the kernel\n"
undefined:
	.asciz "kernel: an undefined instruction, skipped\n"
started:
	.asciz "kernel: the timer, every 10ms\n"
tick:
	.ascii "kernel: tick "
digit:
	.asciz "0\n"
done:
	.asciz "kernel: done, halting\n"
