@ Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyArm.ml)
@ write(1, msg, 13); exit(0)
	.syntax unified
	.text
	.global _start
_start:
	mov	r0, #1
	ldr	r1, =msg
	mov	r2, #13
	mov	r7, #4
	svc	#0
	mov	r0, #0
	mov	r7, #1
	svc	#0
msg:
	.ascii	"Hello, world\n"
