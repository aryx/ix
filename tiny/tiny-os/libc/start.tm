; Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
;
; The runtime of tiny-c -tm's programs, what C cannot say: the start and
; the system calls (the unsigned division is udivmod.tm). Linked first
; (the machine starts at 0), then udivmod.tm, then libc (libc.c,
; compiled by tiny-c -tm), then the program (the Makefile):
;
;     tiny-c -tm -o prog.tm prog.c
;     tiny-cpu -o prog start.tm udivmod.tm libc.tm prog.tm && tiny-cpu ./prog one two
;
; The convention is tiny-c -tm's: the arguments at 0(sp), 4(sp)...,
; the result in r13, any register but sp free to the callee.

; tiny-cpu leaves argc at 0(sp) and argv at 4(sp): main's arguments
_start:
	call	main
	mov	r1, r13
	sys	0

; int write(int fd, void *buf, int n)
write:
	ldw	r1, 0(sp)
	ldw	r2, 4(sp)
	ldw	r3, 8(sp)
	sys	1
	mov	r13, r1
	ret

; void exits(char *msg): Plan 9's; status 0 if msg is nil or empty, 1 if not
exits:
	ldw	r2, 0(sp)
	li	r1, 0
	beq	r2, zero, exits_now
	ldb	r3, 0(r2)
	beq	r3, zero, exits_now
	li	r1, 1
exits_now:
	sys	0
