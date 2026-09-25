; Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyMachine.ml)
;
; The relocating window (status's bit 16, t6's): the user's code copied
; to physical 0x100000 and run at 0, its window 4 KB. The user stores
; 'A' at its 0x100, then loads from its 0x2000, past the window: the
; fault's handler prints the byte found at physical 0x100100, the
; cause, and whether tval is the user's 0x2000 ("A3y").

	la	r1, trap
	csrw	tvec, r1
	la	r1, user		; the user's six words, to 0x100000
	li	r2, 0x100000
	li	r3, 6
copy:
	ldw	r4, 0(r1)
	stw	r4, 0(r2)
	addi	r1, r1, 4
	addi	r2, r2, 4
	addi	r3, r3, -1
	bne	r3, zero, copy
	li	r1, 0x100000
	csrw	base, r1
	li	r1, 0x1000
	csrw	bound, r1
	csrw	epc, zero
	li	r1, 17			; supervisor, relocating; user after eret
	csrw	status, r1
	eret

trap:
	li	r1, 0x100100
	ldb	r5, 0(r1)
	stb	r5, -16(r0)
	csrr	r5, cause
	addi	r5, r5, 48
	stb	r5, -16(r0)
	csrr	r5, tval
	li	r6, 0x2000
	li	r7, 121			; y
	beq	r5, r6, same
	li	r7, 110			; n
same:
	stb	r7, -16(r0)
	li	r5, 10
	stb	r5, -16(r0)
	stw	r0, -12(r0)

; at 0 once copied: no address of its own but 0x100 and 0x2000
user:
	li	r1, 0x100
	li	r2, 65
	stw	r2, 0(r1)
	li	r1, 0x2000
	ldw	r2, 0(r1)
	sys	0
