; Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyMachine.ml)
;
; b: 20 letters, with a delay between two
;
; A user program for kernel.tm, linked with it by tiny-machine (Makefile):
; its window is from its first label to its _end, 64KB aligned, and the
; kernel's table names both.

	.align	0x10000
b:
	li	r5, 20
b_loop:
	li	r1, 1
	la	r2, b_letter
	li	r3, 1
	sys	1
	li	r6, 30
b_delay:
	addi	r6, r6, -1
	bne	r6, r0, b_delay
	addi	r5, r5, -1
	bne	r5, r0, b_loop
	sys	0
b_letter:
	.ascii	"b"
	.align	0x10000
b_end:
