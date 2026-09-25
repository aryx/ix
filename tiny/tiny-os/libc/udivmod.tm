; Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
;
; The unsigned division TinyCPU lacks, which tiny-c -tm calls for / and %
; on unsigned values: linked with any program of tiny-c -tm's, the
; kernel's (v6) and the users' (after start.tm).

; the unsigned division, called in the middle of an expression: the
; dividend at -4(sp), the divisor at -8(sp); the quotient in r13, the
; remainder at -4(sp); r1-r12 kept (saved below). One bit at a time:
; the remainder shifted left with the dividend's next bit, the divisor
; subtracted when it goes. The shift never loses a bit: after k steps
; the remainder is at most the dividend's first k bits, below 2^31
; before the last.
__udivmod:
	stw	r1, -12(sp)
	stw	r2, -16(sp)
	stw	r3, -20(sp)
	stw	r4, -24(sp)
	stw	r5, -28(sp)
	ldw	r1, -4(sp)		; the dividend, shifted out from the top
	ldw	r2, -8(sp)		; the divisor
	li	r13, 0			; the quotient
	li	r3, 0			; the remainder
	li	r4, 32
udm_loop:
	shri	r5, r1, 31		; the dividend's next bit
	shli	r1, r1, 1
	shli	r3, r3, 1
	or	r3, r3, r5
	shli	r13, r13, 1
	bltu	r3, r2, udm_next
	sub	r3, r3, r2
	ori	r13, r13, 1
udm_next:
	addi	r4, r4, -1
	bne	r4, zero, udm_loop
	stw	r3, -4(sp)
	ldw	r1, -12(sp)
	ldw	r2, -16(sp)
	ldw	r3, -20(sp)
	ldw	r4, -24(sp)
	ldw	r5, -28(sp)
	ret
