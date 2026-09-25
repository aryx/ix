; Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyCPU.ml)
; write(1, msg, 13); exit(0)
	li	r1, 1
	la	r2, msg
	li	r3, 13
	sys	1
	li	r1, 0
	sys	0
msg:
	.ascii	"Hello, world\n"
