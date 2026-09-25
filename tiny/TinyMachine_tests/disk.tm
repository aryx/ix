; Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyMachine.ml)
;
; The disk: block 1 read into memory and printed, then WRITTEN written
; to block 2; each transfer waited for by its interrupt, whose cause
; and sources are printed ("44": an interrupt, the disk's). The image
; is made by TinyMachine_test.sh (block 1 "hello, disk"), which checks
; block 2 after the halt.

	la	r1, trap
	csrw	tvec, r1
	li	r1, 4			; the disk's interrupt only
	csrw	ie, r1
	li	r1, 3			; supervisor, interrupts on
	csrw	status, r1
	li	r2, 0x10000		; the buffer
	li	r1, 1
	stw	r1, -32(r0)		; block 1
	stw	r2, -28(r0)
	li	r11, 0
	stw	r1, -24(r0)		; read
wait1:
	beq	r11, zero, wait1
	li	r3, 12
	mov	r4, r2
print:
	ldb	r5, 0(r4)
	stb	r5, -16(r0)
	addi	r4, r4, 1
	addi	r3, r3, -1
	bne	r3, zero, print
	la	r4, written		; into the buffer, then to block 2
	ldw	r5, 0(r4)
	stw	r5, 0(r2)
	ldw	r5, 4(r4)
	stw	r5, 4(r2)
	li	r1, 2
	stw	r1, -32(r0)
	li	r11, 0
	stw	r1, -24(r0)		; write
wait2:
	beq	r11, zero, wait2
	li	r5, 10
	stb	r5, -16(r0)
	stw	r0, -12(r0)

; the interrupt: its cause and sources, the transfer acknowledged
trap:
	csrr	r5, cause
	addi	r5, r5, 48
	stb	r5, -16(r0)
	csrr	r5, tval
	addi	r5, r5, 48
	stb	r5, -16(r0)
	stw	r0, -20(r0)
	li	r11, 1
	eret

written:
	.ascii	"WRITTEN\n"
