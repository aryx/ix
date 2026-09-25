; Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyMachine.ml)
;
; d: a letter, then a store into the kernel's memory
;
; A user program for TinyKernel_v0.tm, linked with it by tiny-machine:
; its window is from its first label to its _end, 64KB aligned, and the
; kernel's table names both.

	.align	0x10000
d:
	li	r1, 1
	la	r2, d_letter
	li	r3, 1
	sys	1
	stw	r0, 0(r0)		; the kernel's first word
	sys	0
d_letter:
	.ascii	"d"
	.align	0x10000
d_end:
