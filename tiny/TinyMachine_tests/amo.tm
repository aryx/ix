; Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyMachine.ml)
;
; amoswap, hartid and ip, one line each (TinyMachine_test.sh compares
; with amo.expected): the swap's old value and the word after it; the
; word cleared; a spinlock taken, then found taken (1); hartid; ip's
; timer bit, before and after timecmp is reached; amoswap in user mode,
; the word it left read by the supervisor after the user's sys.

	la	r1, trap
	csrw	tvec, r1
	la	r1, lock
	li	r2, 7
	amoswap	r3, r2, (r1)		; r3 = 0, lock = 7
	addi	r5, r3, 48
	stb	r5, -16(r0)
	ldw	r5, 0(r1)
	addi	r5, r5, 48
	stb	r5, -16(r0)
	li	r5, 10
	stb	r5, -16(r0)
	amoswap	r0, r0, (r1)		; lock = 0, the old value thrown away
	ldw	r5, 0(r1)
	addi	r5, r5, 48
	stb	r5, -16(r0)
	li	r5, 10
	stb	r5, -16(r0)
	li	r2, 1			; acquire: swap 1 in until 0 comes out
acquire:
	amoswap	r3, r2, (r1)
	bne	r3, zero, acquire
	amoswap	r3, r2, (r1)		; taken: 1 comes out
	addi	r5, r3, 48
	stb	r5, -16(r0)
	li	r5, 10
	stb	r5, -16(r0)
	csrr	r5, hartid
	addi	r5, r5, 48
	stb	r5, -16(r0)
	li	r5, 10
	stb	r5, -16(r0)
	csrr	r5, ip			; timecmp at its reset, 0xffffffff: 0
	addi	r5, r5, 48
	stb	r5, -16(r0)
	csrw	timecmp, r0		; reached: 1 (interrupts off: no trap)
	csrr	r5, ip
	addi	r5, r5, 48
	stb	r5, -16(r0)
	li	r5, 10
	stb	r5, -16(r0)
	; user mode, its window the first MB
	csrw	base, r0
	li	r2, 0x100000
	csrw	bound, r2
	la	r2, user
	csrw	epc, r2
	li	r2, 1			; supervisor now, user after eret
	csrw	status, r2
	eret

user:
	la	r1, lock
	li	r2, 9
	amoswap	r0, r2, (r1)
	sys	0

trap:
	la	r1, lock
	ldw	r5, 0(r1)
	addi	r5, r5, 48
	stb	r5, -16(r0)
	li	r5, 10
	stb	r5, -16(r0)
	stw	r0, -12(r0)

	.align	4
lock:	.word	0
