; Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyMachine.ml)
;
; A page of kernel for tiny-machine, and four user programs. The kernel
; runs them in turn, a slice of `period` instructions each (the timer),
; each in its window of memory (base, bound): two print a letter at a
; time (sys 1, write), one executes csrw (illegal in user mode), one
; stores into the kernel (a fault). The kernel kills the last two,
; saying why, and halts when all four are gone.
;
; A process is 80 bytes: r1-r15 at 4-60 (rN at 4N), the pc at 64, the
; window at 68 and 72, 1 at 76 while it lives. The kernel's own data
; is below 0x8000, so that n(r0) reaches it with no register.
;
; The period must be longer than the kernel's way from the timer's trap
; to eret (about 25 instructions); shorter, the next interrupt comes
; first, and no user instruction ever runs.

boot:
	la	r1, trap
	csrw	tvec, r1
	la	r1, procs
	stw	r1, cur(r0)
	j	switch

; ---------------------------------------------------------------- the trap
; every register saved into the current process, then the cause

trap:
	stw	r1, tmp(r0)
	ldw	r1, cur(r0)
	stw	r2, 8(r1)
	stw	r3, 12(r1)
	stw	r4, 16(r1)
	stw	r5, 20(r1)
	stw	r6, 24(r1)
	stw	r7, 28(r1)
	stw	r8, 32(r1)
	stw	r9, 36(r1)
	stw	r10, 40(r1)
	stw	r11, 44(r1)
	stw	r12, 48(r1)
	stw	r13, 52(r1)
	stw	r14, 56(r1)
	stw	r15, 60(r1)
	ldw	r2, tmp(r0)
	stw	r2, 4(r1)
	csrr	r2, epc
	stw	r2, 64(r1)
	csrr	r2, cause
	li	r3, 1
	beq	r2, r3, syscall
	li	r3, 4
	beq	r2, r3, schedule
	la	r4, illegal_msg
	li	r5, 9
	li	r3, 2
	beq	r2, r3, killmsg
	la	r4, fault_msg
	li	r5, 7
killmsg:
	call	puts
kill:
	stw	r0, 76(r1)
	ldw	r2, alive(r0)
	addi	r2, r2, -1
	stw	r2, alive(r0)
	bne	r2, r0, schedule
	stw	r0, -12(r0)		; halt, status 0

; sys 0 exits, sys 1 writes r3 bytes at r2 if they are the process's
syscall:
	csrr	r2, tval
	beq	r2, r0, kill
	li	r3, 1
	bne	r2, r3, resume
	ldw	r4, 8(r1)
	ldw	r5, 12(r1)
	ldw	r6, 68(r1)
	bltu	r4, r6, refuse
	add	r7, r4, r5
	ldw	r6, 72(r1)
	bltu	r6, r7, refuse
	call	puts
	ldw	r5, 12(r1)
	stw	r5, 4(r1)
	j	resume
refuse:
	li	r5, -1
	stw	r5, 4(r1)
	j	resume

; r5 bytes at r4 to the console
puts:
	beq	r5, r0, puts_done
	ldb	r6, 0(r4)
	stb	r6, -16(r0)
	addi	r4, r4, 1
	addi	r5, r5, -1
	j	puts
puts_done:
	ret

; ---------------------------------------------------------------- the scheduler
; the next living process after the current one, round robin

schedule:
	ldw	r1, cur(r0)
next:
	addi	r1, r1, 80
	la	r2, procs_end
	bltu	r1, r2, alive_p
	la	r1, procs
alive_p:
	ldw	r2, 76(r1)
	beq	r2, r0, next
	stw	r1, cur(r0)
switch:
	csrr	r2, time
	ldw	r3, period(r0)
	add	r2, r2, r3
	csrw	timecmp, r2
; back to the current process: its window, its pc, user mode with
; interrupts on after eret, its registers
resume:
	ldw	r1, cur(r0)
	ldw	r2, 64(r1)
	csrw	epc, r2
	ldw	r2, 68(r1)
	csrw	base, r2
	ldw	r2, 72(r1)
	csrw	bound, r2
	li	r2, 9			; supervisor now, then user with interrupts on
	csrw	status, r2
	ldw	r2, 8(r1)
	ldw	r3, 12(r1)
	ldw	r4, 16(r1)
	ldw	r5, 20(r1)
	ldw	r6, 24(r1)
	ldw	r7, 28(r1)
	ldw	r8, 32(r1)
	ldw	r9, 36(r1)
	ldw	r10, 40(r1)
	ldw	r11, 44(r1)
	ldw	r12, 48(r1)
	ldw	r13, 52(r1)
	ldw	r14, 56(r1)
	ldw	r15, 60(r1)
	ldw	r1, 4(r1)
	eret

; ---------------------------------------------------------------- the data

illegal_msg:
	.ascii	"<illegal>"
fault_msg:
	.ascii	"<fault>"
	.align	4
tmp:	.word	0
cur:	.word	0
alive:	.word	4
period:	.word	200

; four processes: registers zero but sp at the window's top
procs:
	.word	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x20000, 0
	.word	a, 0x10000, 0x20000, 1
	.word	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x30000, 0
	.word	b, 0x20000, 0x30000, 1
	.word	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x40000, 0
	.word	c, 0x30000, 0x40000, 1
	.word	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x50000, 0
	.word	d, 0x40000, 0x50000, 1
procs_end:

; ---------------------------------------------------------------- the programs
; a and b: 20 letters each, with a delay between two

	.align	0x10000
a:
	li	r5, 20
a_loop:
	li	r1, 1
	la	r2, a_letter
	li	r3, 1
	sys	1
	li	r6, 30
a_delay:
	addi	r6, r6, -1
	bne	r6, r0, a_delay
	addi	r5, r5, -1
	bne	r5, r0, a_loop
	sys	0
a_letter:
	.ascii	"a"

	.align	0x10000
b:
	li	r5, 20
b_loop:
	li	r1, 1
	la	r2, b_letter
	li	r3, 1
	sys	1
	li	r6, 30
b_delay:
	addi	r6, r6, -1
	bne	r6, r0, b_delay
	addi	r5, r5, -1
	bne	r5, r0, b_loop
	sys	0
b_letter:
	.ascii	"b"

; c: a letter, then an instruction only the kernel may execute
	.align	0x10000
c:
	li	r1, 1
	la	r2, c_letter
	li	r3, 1
	sys	1
	csrw	tvec, r0
	sys	0
c_letter:
	.ascii	"c"

; d: a letter, then a store into the kernel's memory
	.align	0x10000
d:
	li	r1, 1
	la	r2, d_letter
	li	r3, 1
	sys	1
	stw	r0, tmp(r0)
	sys	0
d_letter:
	.ascii	"d"
