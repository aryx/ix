; Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyCPU.ml)
; standard input's first 256 bytes, the lowercase letters made
; uppercase; exit status: how many bytes
	li	r1, 0
	la	r2, buf
	li	r3, 256
	sys	2			; read
	mov	r9, r1			; n
	la	r10, buf
	add	r11, r10, r9		; the end
	li	r12, 97			; 'a'
	li	r13, 26
each:
	bgeu	r10, r11, done
	ldb	r2, 0(r10)
	sub	r3, r2, r12		; unsigned: below 'a' wraps above 26
	bgeu	r3, r13, keep
	xori	r2, r2, 32		; the case bit
	stb	r2, 0(r10)
keep:
	addi	r10, r10, 1
	j	each
done:
	li	r1, 1
	la	r2, buf
	mov	r3, r9
	sys	1
	mov	r1, r9
	sys	0
buf:
	.space	256
