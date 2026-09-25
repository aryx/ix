@ Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyCPUArm.ml)
@ the other forms of the subset, each result folded into a checksum
@ (r10 = r10 ror 7, eor the result), printed in hex; exit status: its
@ low byte
	.syntax unified
	.text
	.global _start
_start:
	ldr	r10, =0x12345678
	ldr	r0, =0xfffffff0
	mov	r1, #0x20
	adds	r2, r0, r1		@ a carry out
	bl	fold
	adc	r2, r1, r1		@ and in
	bl	fold
	subs	r2, r1, r0		@ a borrow
	sbc	r2, r0, r1
	bl	fold
	rsb	r2, r1, #0
	bl	fold
	rscs	r2, r0, r1, lsl #4
	bl	fold
	mvn	r2, #0xff00
	bl	fold
	bic	r2, r0, #0x0f000000
	bl	fold
	orr	r2, r1, r0, lsr #28
	bl	fold
	eor	r2, r0, r1, asr #3
	bl	fold
	mov	r3, #5
	mov	r2, r0, lsl r3		@ shifted by a register
	bl	fold
	asr	r2, r0, r3
	bl	fold
	ror	r2, r0, #12
	bl	fold
	movs	r4, r1, lsr #1		@ the carry: bit 0 of r1
	rrx	r2, r0
	bl	fold
	mul	r2, r0, r1
	bl	fold
	mla	r2, r1, r1, r0
	bl	fold
	mov	r2, #1000		@ a rotated immediate
	add	r2, r2, #-4		@ written add, encoded sub
	bl	fold
	cmp	r0, #-16		@ cmn
	moveq	r2, #1
	movne	r2, #2
	bl	fold
	tst	r1, #0x10
	movne	r2, #3
	bl	fold
	teq	r1, r1
	movseq	r2, #0
	addeq	r2, r2, #4
	bl	fold
@ memory: offsets, indexing, blocks
	ldr	r5, =table
	ldr	r2, [r5, #8]
	bl	fold
	mov	r6, #3
	ldr	r2, [r5, r6, lsl #2]	@ table[3]
	bl	fold
	add	r7, r5, #16
	ldr	r2, [r7, #-12]		@ table[1]
	bl	fold
	ldr	r2, [r7, -r6, lsl #2]	@ table[1] again
	bl	fold
	ldr	r2, [r5, #4]!		@ writeback: r5 = &table[1]
	bl	fold
	ldr	r2, [r5], #4		@ post: r5 = &table[2]
	bl	fold
	ldrb	r2, [r5, #1]
	bl	fold
	ldr	r8, =scratch
	stmia	r8!, {r0, r1, r2}
	sub	r2, r8, #0
	stmdb	r8, {r3, r4}
	ldmib	r8!, {r3}
	ldmda	r8, {r2, r3}
	bl	fold
	ldm	r8, {r2}
	bl	fold
	stmfd	sp!, {r0, r1}
	ldmfd	sp!, {r2, r3}
	bl	fold
@ calls through registers
	adr	r9, twice
	mov	r0, #21
	blx	r9
	mov	r2, r0
	bl	fold
@ the checksum, in hex
	mov	r0, r10
	bl	hex
	and	r0, r10, #0xff
	mov	r7, #1
	svc	#0

twice:
	add	r0, r0, r0
	bx	lr

@ r10 = (r10 ror 7) eor r2
fold:
	eor	r10, r2, r10, ror #7
	bx	lr

@ r0 in hex, 8 digits, and a newline
hex:
	ldr	r1, =digits
	mov	r2, #28
	ldr	r3, =out
nibble:
	mov	r4, r0, lsr r2
	and	r4, r4, #15
	ldrb	r4, [r1, r4]
	strb	r4, [r3], #1
	subs	r2, r2, #4
	bpl	nibble
	mov	r4, #10
	strb	r4, [r3]
	mov	r0, #1
	ldr	r1, =out
	mov	r2, #9
	mov	r7, #4
	svc	#0
	bx	lr

table:
	.word	11, 22, 33, 0x44332211, 55
digits:
	.ascii	"0123456789abcdef"
out:
	.space	12
scratch:
	.space	32
