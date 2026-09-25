@ Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyCPUArm.ml)
@ standard input's first 256 bytes, reversed (the final newline kept
@ last); exit status: how many bytes read
	.syntax unified
	.text
	.global _start
_start:
	mov	r0, #0
	ldr	r1, =buf
	mov	r2, #256
	mov	r7, #3
	svc	#0			@ read(0, buf, 256)
	mov	r6, r0			@ n
	ldr	r4, =buf		@ the left end
	add	r5, r4, r6		@ the right end, past the last byte
	ldrb	r0, [r5, #-1]
	cmp	r0, #10			@ a final newline stays put
	subeq	r5, r5, #1
swap:
	sub	r5, r5, #1
	cmp	r4, r5
	bhs	out
	ldrb	r0, [r4]
	ldrb	r1, [r5]
	strb	r1, [r4], #1		@ post-indexed
	strb	r0, [r5]
	b	swap
out:
	mov	r0, #1
	ldr	r1, =buf
	mov	r2, r6
	mov	r7, #4
	svc	#0
	mov	r0, r6
	mov	r7, #1
	svc	#0
buf:
	.space	256
