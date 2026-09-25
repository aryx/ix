; Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyMachine.ml)
;
; t6: what C cannot say. One kernel stack, the only one: a trap saves
; the process's registers in its struct proc, never on a stack of its
; own, and the kernel leaves by resume, loading a process's registers,
; not by returning. Linked first: the machine starts at 0.

_entry:
	la	sp, stacktop
	call	main
spin:
	j	spin

; From user mode scratch holds the process (its registers first), in
; the kernel 0: swapping it with r1 frees a register, and says where
; the trap came from.
trapvec:
	csrrw	r1, scratch, r1
	beq	r1, zero, idle
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
	csrr	r2, scratch
	stw	r2, 4(r1)
	csrw	scratch, zero
	csrr	r2, epc
	stw	r2, 64(r1)
	la	sp, stacktop		; the kernel's one stack, from its top
	call	trap			; which ends in resume
	j	spin

; an interrupt in the scheduler's idle loop, the only time the kernel
; has them on: on the stack, handled, back
idle:
	csrrw	r1, scratch, r1
	addi	sp, sp, -64
	stw	r1, 4(sp)
	stw	r2, 8(sp)
	stw	r3, 12(sp)
	stw	r4, 16(sp)
	stw	r5, 20(sp)
	stw	r6, 24(sp)
	stw	r7, 28(sp)
	stw	r8, 32(sp)
	stw	r9, 36(sp)
	stw	r10, 40(sp)
	stw	r11, 44(sp)
	stw	r12, 48(sp)
	stw	r13, 52(sp)
	stw	r15, 60(sp)
	call	interrupt
	ldw	r1, 4(sp)
	ldw	r2, 8(sp)
	ldw	r3, 12(sp)
	ldw	r4, 16(sp)
	ldw	r5, 20(sp)
	ldw	r6, 24(sp)
	ldw	r7, 28(sp)
	ldw	r8, 32(sp)
	ldw	r9, 36(sp)
	ldw	r10, 40(sp)
	ldw	r11, 44(sp)
	ldw	r12, 48(sp)
	ldw	r13, 52(sp)
	ldw	r15, 60(sp)
	addi	sp, sp, 64
	eret

; void resume(struct proc *p): to p in user mode, relocated in its
; partition (the base and the bound set by the caller)
resume:
	ldw	r1, 0(sp)
	csrw	scratch, r1
	ldw	r2, 64(r1)
	csrw	epc, r2
	li	r2, 25			; supervisor; after eret user, interrupts on, relocating
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

; void memzero(uint *p, uint n): n bytes, a multiple of 4, zeroed; in
; assembly as it is the kernel's hottest loop (a partition is a MB)
memzero:
	ldw	r1, 0(sp)
	ldw	r2, 4(sp)
	add	r2, r1, r2
memzero1:
	bgeu	r1, r2, memzero2
	stw	zero, 0(r1)
	addi	r1, r1, 4
	j	memzero1
memzero2:
	ret

r_cause:
	csrr	r13, cause
	ret
r_tval:
	csrr	r13, tval
	ret
r_time:
	csrr	r13, time
	ret
w_timecmp:
	ldw	r1, 0(sp)
	csrw	timecmp, r1
	ret
w_tvec:
	ldw	r1, 0(sp)
	csrw	tvec, r1
	ret
w_ie:
	ldw	r1, 0(sp)
	csrw	ie, r1
	ret
w_base:
	ldw	r1, 0(sp)
	csrw	base, r1
	ret
w_bound:
	ldw	r1, 0(sp)
	csrw	bound, r1
	ret
intr_on:
	li	r1, 3
	csrw	status, r1
	ret
intr_off:
	li	r1, 1
	csrw	status, r1
	ret

	.align	4
	.space	8192
stacktop:
