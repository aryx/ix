; Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyMachine.ml)
;
; Sv32 pages, one line each (compared with paging.expected): a word
; stored through a virtual page and read back; the same word read at
; its physical address, pages off; then three faults, each caught with
; its address in tval ("F3y": the fault's cause, and tval as expected):
; an unmapped page, a store into a read-only page, and a user's load
; from a supervisor's page. The tables, built here:
;
;   root 0x100000: [0] -> table 0x101000, [1023] -> table 0x102000
;   0x101000: VA 0x0000 -> PA 0x0000 RWX (this code)
;             VA 0x1000 -> PA 0x1000 RX U (the user's code)
;             VA 0x5000 -> PA 0x200000 RW
;             VA 0x7000 -> PA 0x201000 R
;   0x102000: VA 0xfffff000 -> PA 0xfff000 RW (the devices: -16(r0) is
;             VA 0xfffffff0 with pages on)
;
; An entry: the physical page's number << 10, then U 16, X 8, W 4, R 2,
; V 1.

	la	r1, trap
	csrw	tvec, r1
	li	r1, 0x100000
	li	r2, 0x40401		; 0x101 << 10 | V
	stw	r2, 0(r1)
	li	r2, 0x40801		; 0x102 << 10 | V
	stw	r2, 4092(r1)
	li	r1, 0x101000
	li	r2, 15			; page 0, RWX V
	stw	r2, 0(r1)
	li	r2, 0x41b		; page 1, U X R V
	stw	r2, 4(r1)
	li	r2, 0x80007		; page 0x200, W R V
	stw	r2, 20(r1)
	li	r2, 0x80403		; page 0x201, R V
	stw	r2, 28(r1)
	li	r1, 0x102000
	li	r2, 0x3ffc07		; page 0xfff, W R V
	stw	r2, 4092(r1)
	li	r1, 0x80000100		; on, the root's page 0x100
	csrw	satp, r1

	li	r1, 0x5000		; through the page
	li	r2, 65
	stw	r2, 0(r1)
	ldw	r5, 0(r1)
	stb	r5, -16(r0)
	li	r5, 10
	stb	r5, -16(r0)
	csrw	satp, r0		; pages off: the physical word
	li	r1, 0x200000
	ldw	r5, 0(r1)
	stb	r5, -16(r0)
	li	r5, 10
	stb	r5, -16(r0)
	li	r1, 0x80000100
	csrw	satp, r1

	li	r9, 0x6000		; unmapped
	ldw	r2, 0(r9)
	li	r9, 0x7000		; read-only
	stw	r2, 0(r9)
	li	r9, 0x5000		; the user's load, below
	li	r2, 0x1000
	csrw	epc, r2
	li	r2, 1			; supervisor now, user after eret
	csrw	status, r2
	eret

; a fault: its line, then on past the instruction; the user's sys: the end
trap:
	csrr	r10, cause
	li	r11, 1
	beq	r10, r11, done
	li	r5, 70
	stb	r5, -16(r0)
	addi	r5, r10, 48
	stb	r5, -16(r0)
	csrr	r10, tval
	li	r5, 121			; y
	beq	r10, r9, same
	li	r5, 110			; n
same:
	stb	r5, -16(r0)
	li	r5, 10
	stb	r5, -16(r0)
	csrr	r10, epc
	addi	r10, r10, 4
	csrw	epc, r10
	eret
done:
	stw	r0, -12(r0)

	.align	0x1000
user:
	ldw	r2, 0(r9)
	sys	0
