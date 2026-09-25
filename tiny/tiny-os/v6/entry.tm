; Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyMachine.ml)
;
; tiny-os v6: what C cannot say (xv6's entry.S, kernelvec.S,
; trampoline.S, swtch.S and riscv.h's inline functions). Linked first:
; the machine starts at 0. Called from C by tiny-c's convention: the
; arguments at 0(sp), 4(sp)..., the result in r13, any register free.

; the start: each core its stack (a page, below stack0's end), then main
_entry:
	csrr	r1, hartid
	addi	r1, r1, 1
	shli	r1, r1, 12
	la	r2, stack0
	add	sp, r2, r1
	call	main
spin:
	j	spin

; The trap vector. In user mode scratch holds the process's trap frame
; (struct proc's tf), in the kernel 0: swapping it with r1 frees a
; register and says where the trap came from.
trapvec:
	csrrw	r1, scratch, r1
	beq	r1, zero, fromkernel
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
	csrr	r2, scratch		; the user's r1
	stw	r2, 4(r1)
	csrw	scratch, zero		; in the kernel now
	csrr	r2, epc
	stw	r2, 64(r1)
	ldw	sp, 68(r1)		; the process's kernel stack
	call	usertrap		; which ends in userret
	j	spin

; a trap in the kernel: only in the scheduler's idle loop, the one place
; the kernel runs with interrupts on (it is not preemptible); the
; registers on its stack, the interrupt handled, back
fromkernel:
	csrrw	r1, scratch, r1		; r1 back, scratch 0 again
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
	call	kerneltrap
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

; void userret(uint *tf): to user mode, the trap frame's registers
userret:
	ldw	r1, 0(sp)
	csrw	scratch, r1
	ldw	r2, 64(r1)
	csrw	epc, r2
	li	r2, 9			; supervisor now; after eret user, interrupts on
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

; void swtch(struct context *old, struct context *new): the stack and
; the return address are all a context is
swtch:
	ldw	r1, 0(sp)
	ldw	r2, 4(sp)
	stw	sp, 0(r1)
	stw	lr, 4(r1)
	ldw	sp, 0(r2)
	ldw	lr, 4(r2)
	ret

; int amoswap(int *p, int v): *p becomes v, its old value returned, at once
amoswap:
	ldw	r1, 0(sp)
	ldw	r2, 4(sp)
	amoswap	r13, r2, (r1)
	ret

; the registers of control
r_hartid:
	csrr	r13, hartid
	ret
r_time:
	csrr	r13, time
	ret
r_cause:
	csrr	r13, cause
	ret
r_tval:
	csrr	r13, tval
	ret
r_ip:
	csrr	r13, ip
	ret
w_timecmp:
	ldw	r1, 0(sp)
	csrw	timecmp, r1
	ret
w_satp:
	ldw	r1, 0(sp)
	csrw	satp, r1
	ret
w_tvec:
	ldw	r1, 0(sp)
	csrw	tvec, r1
	ret
w_ie:
	ldw	r1, 0(sp)
	csrw	ie, r1
	ret
intr_get:
	csrr	r13, status
	andi	r13, r13, 2
	ret
intr_on:
	csrr	r1, status
	ori	r1, r1, 2
	csrw	status, r1
	ret
intr_off:
	csrr	r1, status
	andi	r1, r1, 0xfffd
	csrw	status, r1
	ret

; the cores' boot stacks, a page each (NCPU of defs.h): core h's top
; is stack0 + (h + 1) * 4096
	.align	4096
stack0:
	.space	4096
