; Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyMachine.ml)
; n! for n = 0 to 12, recursively: a frame per call on the stack
	li	r9, 0
next:
	mov	r1, r9
	call	fact
	call	print
	addi	r9, r9, 1
	slti	r2, r9, 13
	bne	r2, zero, next
	li	r1, 0
	sys	0

; fact: r1 = r1!, recursively
fact:
	addi	sp, sp, -8
	stw	lr, 0(sp)
	stw	r1, 4(sp)
	li	r2, 1
	blt	r2, r1, recurse		; 1 < n
	li	r1, 1
	j	return
recurse:
	addi	r1, r1, -1
	call	fact
	ldw	r2, 4(sp)
	mul	r1, r1, r2
return:
	ldw	lr, 0(sp)
	addi	sp, sp, 8
	ret

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
