; Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
;
; The runtime of tiny-c -tm's programs, what C cannot say: the start,
; the system calls, the unsigned division TinyCPU lacks. Linked first
; (the machine starts at 0), then libc (libc.c, compiled by tiny-c -tm),
; then the program (the Makefile):
;
;     tiny-c -tm -o prog.tm prog.c
;     tiny-cpu -o prog start.tm libc.tm prog.tm && tiny-cpu ./prog one two
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

; the unsigned division, called in the middle of an expression: the
; dividend at -4(sp), the divisor at -8(sp); the quotient in r13, the
; remainder at -4(sp); r1-r12 kept (saved below). One bit at a time:
; the remainder shifted left with the dividend's next bit, the divisor
; subtracted when it goes. The shift never loses a bit: after k steps
; the remainder is at most the dividend's first k bits, below 2^31
; before the last.
__udivmod:
	stw	r1, -12(sp)
	stw	r2, -16(sp)
	stw	r3, -20(sp)
	stw	r4, -24(sp)
	stw	r5, -28(sp)
	ldw	r1, -4(sp)		; the dividend, shifted out from the top
	ldw	r2, -8(sp)		; the divisor
	li	r13, 0			; the quotient
	li	r3, 0			; the remainder
	li	r4, 32
udm_loop:
	shri	r5, r1, 31		; the dividend's next bit
	shli	r1, r1, 1
	shli	r3, r3, 1
	or	r3, r3, r5
	shli	r13, r13, 1
	bltu	r3, r2, udm_next
	sub	r3, r3, r2
	ori	r13, r13, 1
udm_next:
	addi	r4, r4, -1
	bne	r4, zero, udm_loop
	stw	r3, -4(sp)
	ldw	r1, -12(sp)
	ldw	r2, -16(sp)
	ldw	r3, -20(sp)
	ldw	r4, -24(sp)
	ldw	r5, -28(sp)
	ret
