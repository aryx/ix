; Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyMachine.ml)
; calls through a table of addresses (jalr): each of three functions
; applied to 1..5, printed
	li	r9, 0			; the function's index
func:
	li	r10, 1			; the argument
arg:
	la	r2, table
	shli	r3, r9, 2
	add	r2, r2, r3
	ldw	r4, 0(r2)		; the function's address
	mov	r1, r10
	jalr	lr, 0(r4)
	call	print
	addi	r10, r10, 1
	slti	r2, r10, 6
	bne	r2, zero, arg
	addi	r9, r9, 1
	slti	r2, r9, 3
	bne	r2, zero, func
	li	r1, 0
	sys	0

square:
	mul	r1, r1, r1
	ret
cube:
	mul	r2, r1, r1
	mul	r1, r2, r1
	ret
shifted:
	shli	r1, r1, 20
	ori	r1, r1, 0xffff
	ret
table:
	.word	square, cube, shifted

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
