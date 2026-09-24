@ Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyArm.ml)
@ the primes below 1000, Eratosthenes' sieve in a byte array; exit
@ status: how many (168)
	.syntax unified
	.text
	.global _start
_start:
	ldr	r8, =sieve
	mov	r4, #2			@ the candidate
	mov	r9, #0			@ the count
next:
	ldrb	r0, [r8, r4]		@ crossed out?
	cmp	r0, #0
	bne	skip
	add	r9, r9, #1
	mov	r0, r4
	bl	print
	add	r5, r4, r4		@ its multiples, from 2p
cross:
	cmp	r5, #1000
	bhs	skip
	mov	r0, #1
	strb	r0, [r8, r5]
	add	r5, r5, r4
	b	cross
skip:
	add	r4, r4, #1
	cmp	r4, #1000
	blo	next
	mov	r0, r9
	mov	r7, #1
	svc	#0

@ print: r0 in decimal and a newline (no divide on this ARM: each
@ power of ten subtracted while it fits)
print:
	push	{r4, r5, r6, r7, lr}
	ldr	r1, =buf
	ldr	r2, =powers
	mov	r6, #0			@ a digit written yet
digit:
	ldr	r3, [r2], #4		@ the next power of ten
	cmp	r3, #0
	beq	done
	mov	r5, #48
count:
	cmp	r0, r3
	subhs	r0, r0, r3
	addhs	r5, r5, #1
	bhs	count
	teq	r3, #1			@ the units digit always
	moveq	r6, #1
	cmp	r5, #48
	movne	r6, #1
	cmp	r6, #0
	strbne	r5, [r1], #1
	b	digit
done:
	mov	r3, #10
	strb	r3, [r1], #1
	ldr	r3, =buf
	sub	r2, r1, r3
	mov	r1, r3
	mov	r0, #1
	mov	r7, #4
	svc	#0
	pop	{r4, r5, r6, r7, pc}
powers:
	.word	1000000000, 100000000, 10000000, 1000000, 100000, 10000, 1000, 100, 10, 1, 0
buf:
	.space	16
sieve:
	.space	1000
