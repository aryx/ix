; Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyMachine.ml)
;
; c: a letter, then an instruction only the kernel may execute
;
; A user program for TinyKernel_v0.tm, linked with it by tiny-machine:
; its window is from its first label to its _end, 64KB aligned, and the
; kernel's table names both.

	.align	0x10000
c:
	li	r1, 1
	la	r2, c_letter
	li	r3, 1
	sys	1
	csrw	tvec, r0
	sys	0
c_letter:
	.ascii	"c"
	.align	0x10000
c_end:
