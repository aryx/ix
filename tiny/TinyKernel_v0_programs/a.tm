; Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyMachine.ml)
;
; a: 20 letters, with a delay between two
;
; A user program for TinyKernel_v0.tm, linked with it by tiny-machine:
; its window is from its first label to its _end, 64KB aligned, and the
; kernel's table names both.

	.align	0x10000
a:
	li	r5, 20
a_loop:
	li	r1, 1
	la	r2, a_letter
	li	r3, 1
	sys	1
	li	r6, 30
a_delay:
	addi	r6, r6, -1
	bne	r6, r0, a_delay
	addi	r5, r5, -1
	bne	r5, r0, a_loop
	sys	0
a_letter:
	.ascii	"a"
	.align	0x10000
a_end:
