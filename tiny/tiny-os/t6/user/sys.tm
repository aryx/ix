; Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyMachine.ml)
;
; t6's system calls for C: the arguments from tiny-c's places to r1-r3,
; sys n, the answer from r1 (write is start.tm's, sys 1, tiny-cpu's
; too; the numbers are proc.c's calls[]).

exit:
	ldw	r1, 0(sp)
	ldw	r2, 4(sp)
	ldw	r3, 8(sp)
	sys	0
	mov	r13, r1
	ret
read:
	ldw	r1, 0(sp)
	ldw	r2, 4(sp)
	ldw	r3, 8(sp)
	sys	2
	mov	r13, r1
	ret
spawn:
	ldw	r1, 0(sp)
	ldw	r2, 4(sp)
	ldw	r3, 8(sp)
	sys	3
	mov	r13, r1
	ret
wait:
	ldw	r1, 0(sp)
	ldw	r2, 4(sp)
	ldw	r3, 8(sp)
	sys	4
	mov	r13, r1
	ret
getpid:
	ldw	r1, 0(sp)
	ldw	r2, 4(sp)
	ldw	r3, 8(sp)
	sys	5
	mov	r13, r1
	ret
sbrk:
	ldw	r1, 0(sp)
	ldw	r2, 4(sp)
	ldw	r3, 8(sp)
	sys	6
	mov	r13, r1
	ret
open:
	ldw	r1, 0(sp)
	ldw	r2, 4(sp)
	ldw	r3, 8(sp)
	sys	7
	mov	r13, r1
	ret
close:
	ldw	r1, 0(sp)
	ldw	r2, 4(sp)
	ldw	r3, 8(sp)
	sys	8
	mov	r13, r1
	ret
pipe:
	ldw	r1, 0(sp)
	ldw	r2, 4(sp)
	ldw	r3, 8(sp)
	sys	9
	mov	r13, r1
	ret
mkdir:
	ldw	r1, 0(sp)
	ldw	r2, 4(sp)
	ldw	r3, 8(sp)
	sys	10
	mov	r13, r1
	ret
unlink:
	ldw	r1, 0(sp)
	ldw	r2, 4(sp)
	ldw	r3, 8(sp)
	sys	11
	mov	r13, r1
	ret
chdir:
	ldw	r1, 0(sp)
	ldw	r2, 4(sp)
	ldw	r3, 8(sp)
	sys	12
	mov	r13, r1
	ret
tickets:
	ldw	r1, 0(sp)
	ldw	r2, 4(sp)
	ldw	r3, 8(sp)
	sys	13
	mov	r13, r1
	ret
