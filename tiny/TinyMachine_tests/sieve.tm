; Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyMachine.ml)
; the primes below 1000, a sieve of bytes; exit status: how many (168)
	la	r9, sieve
	li	r10, 2			; the candidate
	li	r11, 0			; the count
	li	r12, 1000
next:
	add	r2, r9, r10
	ldb	r2, 0(r2)
	bne	r2, zero, skip		; crossed out
	addi	r11, r11, 1
	mov	r1, r10
	call	print
	add	r13, r10, r10		; the multiples, from 2p
cross:
	bge	r13, r12, skip
	add	r2, r9, r13
	li	r3, 1
	stb	r3, 0(r2)
	add	r13, r13, r10
	j	cross
skip:
	addi	r10, r10, 1
	blt	r10, r12, next
	mov	r1, r11
	sys	0

; print: r1 in decimal and a newline (clobbers r1-r8)
print:
	addi	sp, sp, -16
	stw	lr, 0(sp)
	la	r5, digits_end
	li	r6, 10
	addi	r5, r5, -1
	stb	r6, 0(r5)		; the newline, last
	li	r7, 1			; the length
digit:
	rem	r8, r1, r6
	div	r1, r1, r6
	addi	r8, r8, 48		; the digit
	addi	r5, r5, -1
	stb	r8, 0(r5)
	addi	r7, r7, 1
	bne	r1, zero, digit
	li	r1, 1
	mov	r2, r5
	mov	r3, r7
	sys	1
	ldw	lr, 0(sp)
	addi	sp, sp, 16
	ret
digits:
	.space	16
digits_end:
sieve:
	.space	1000
