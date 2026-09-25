; Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyCPU.ml)
; the first 40 Fibonacci numbers, in decimal (div and rem by 10)
	li	r9, 0			; a
	li	r10, 1			; b
	li	r11, 40			; how many
loop:
	mov	r1, r9
	call	print
	add	r12, r9, r10
	mov	r9, r10
	mov	r10, r12
	addi	r11, r11, -1
	bne	r11, zero, loop
	li	r1, 0
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
