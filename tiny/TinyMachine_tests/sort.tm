; Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyMachine.ml)
; an insertion sort of 16 words, signed, then printed (their absolute
; values: print is unsigned)
	la	r9, array
	li	r10, 1			; i
	li	r11, 16
outer:
	bge	r10, r11, sorted
	shli	r2, r10, 2
	add	r2, r9, r2
	ldw	r12, 0(r2)		; the key
	mov	r13, r10		; j
inner:
	beq	r13, zero, place
	shli	r3, r13, 2
	add	r3, r9, r3
	ldw	r4, -4(r3)
	bge	r12, r4, place		; a[j-1] <= key
	stw	r4, 0(r3)
	addi	r13, r13, -1
	j	inner
place:
	shli	r3, r13, 2
	add	r3, r9, r3
	stw	r12, 0(r3)
	addi	r10, r10, 1
	j	outer
sorted:
	li	r10, 0
show:
	shli	r2, r10, 2
	add	r2, r9, r2
	ldw	r1, 0(r2)
	sari	r3, r1, 31		; the sign, all ones or zero
	xor	r1, r1, r3
	sub	r1, r1, r3		; the absolute value
	call	print
	addi	r10, r10, 1
	blt	r10, r11, show
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
array:
	.word	42, -7, 1000000, 0, 13, -2147483647, 99, 5, -500, 7, 123456789, -1, 64, 3, -99999, 12
