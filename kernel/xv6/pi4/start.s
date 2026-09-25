// Claude Code
//
// Copyright (C) 2026 Yoann Padioleau
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Library General Public License
// (LGPL) as published by the Free Software Foundation; either version
// 2 of the License, or (at your option) any later version.
//
// mini-xv6 on the Pi4 (plan_kernel.md), what OCaml cannot say: the boot
// (to EL1, the MMU on), the exception entries from EL0 (a system call,
// an abort, an IRQ: the user's registers into the running process's
// trap frame, then the kernel on the process's kernel stack), the way
// back to EL0, the switch between kernel stacks. The Pi1's start.s, for
// ARMv8.
//
// The translation, xv6 arm64-pi4's: 4KB pages, 39-bit addresses on both
// halves (TCR_EL1 0x10B5193519: T0SZ = T1SZ = 25, write-back, inner
// shareable, 16-bit ASIDs); MAIR_EL1 0xff4400: attribute 0 device
// memory, 1 normal non-cacheable, 2 normal write-back. TTBR1 the
// kernel's: KERNBASE (0xffffff8000000000) + the physical addresses, in
// 1GB blocks (the RAM below 2GB, the devices in the fourth); TTBR0 a
// process's (Mmu.ml, Arch.ml), the empty table when none runs.
//
// The boot runs at the physical addresses (loaded at 0x80000, linked at
// KERNBASE + 0x80000: only PC-relative addressing, adr, adrp, literals),
// with TTBR0 mapping the first GB as itself for the jump to the linked
// addresses; QEMU starts every core here: the others wait.

	.set	KERNBASE, 0xffffff8000000000
	.set	NORMAL, 0x709			// a block: AttrIndx 2, inner shareable, AF
	.set	DEVICE, 0x0060000000000401	// a block: AttrIndx 0, AF, UXN, PXN

	.section .text.start
	.global	_start
_start:
	mrs	x1, mpidr_el1
	and	x1, x1, #3
	cbnz	x1, park
	// EL3 (QEMU) to EL2: non-secure, AArch64 below
	mrs	x0, CurrentEL
	and	x0, x0, #0xc
	cmp	x0, #12
	b.ne	el2
	mov	x0, #0x4b1
	msr	scr_el3, x0
	adr	x1, el2
	msr	elr_el3, x1
	mov	x2, #0x3c9
	msr	spsr_el3, x2
	eret
el2:
	// EL2 (the Pi4's firmware) to EL1: AArch64, the floating point not
	// trapped, EL1h with the interrupts masked
	mrs	x0, CurrentEL
	and	x0, x0, #0xc
	cmp	x0, #8
	b.ne	el1
	mov	x0, #(1 << 31)
	orr	x0, x0, #2
	msr	hcr_el2, x0
	mov	x0, #0x33ff
	msr	cptr_el2, x0
	adr	x1, el1
	msr	elr_el2, x1
	mov	x2, #0x3c5
	msr	spsr_el2, x2
	eret
el1:
	// the floating point (ocaml-light's runtime computes with doubles)
	mov	x0, #(3 << 20)
	msr	cpacr_el1, x0
	isb
	// the bss cleared (the page tables in it)
	adrp	x0, __bss_start
	add	x0, x0, :lo12:__bss_start
	adrp	x1, __bss_end
	add	x1, x1, :lo12:__bss_end
1:	cmp	x0, x1
	b.hs	2f
	str	xzr, [x0], #8
	b	1b
2:	// the kernel's table: the RAM (2GB), the devices (the fourth GB)
	adrp	x0, kernel_l1
	ldr	x1, =NORMAL
	str	x1, [x0]
	ldr	x1, =(0x40000000 + NORMAL)
	str	x1, [x0, #8]
	ldr	x1, =(0xc0000000 + DEVICE)
	str	x1, [x0, #24]
	// the boot's: the first GB as itself
	adrp	x0, boot_l1
	ldr	x1, =NORMAL
	str	x1, [x0]
	ldr	x0, =0xff4400
	msr	mair_el1, x0
	ldr	x0, =0x10B5193519
	msr	tcr_el1, x0
	adrp	x0, boot_l1
	msr	ttbr0_el1, x0
	adrp	x0, kernel_l1
	msr	ttbr1_el1, x0
	isb
	tlbi	vmalle1
	dsb	sy
	isb
	// the MMU and the caches on; no alignment checks
	mrs	x0, sctlr_el1
	mov	x1, #0x1005
	orr	x0, x0, x1
	bic	x0, x0, #2
	msr	sctlr_el1, x0
	isb
	ldr	x0, =high
	br	x0
high:
	// at the linked addresses: the stack, the vectors, TTBR0 the empty
	// table, then the board, then C's kmain, which starts OCaml
	ldr	x0, =stack_top
	mov	sp, x0
	adr	x0, vectors
	msr	vbar_el1, x0
	ldr	x0, =empty_pgdir
	ldr	x1, =KERNBASE
	sub	x0, x0, x1
	msr	ttbr0_el1, x0
	isb
	tlbi	vmalle1
	dsb	sy
	isb
	bl	board_init
	bl	kmain
halt:
	wfi
	b	halt
park:
	wfe
	b	park

// the vectors: 2KB aligned, 16 entries of 0x80 bytes; the kernel's own
// exceptions (the first 8) stop the machine, EL0's system calls,
// aborts and IRQs go to the kernel
	.balign	2048
vectors:
	.rept	8
	.balign	0x80
	b	kernel_exception
	.endr
	.balign	0x80
	b	el0_sync
	.balign	0x80
	b	el0_irq
	.rept	6
	.balign	0x80
	b	kernel_exception
	.endr

// from EL0: the user's registers into the trap frame (the running
// process's, cur_tf: x0-x30, sp_el0, elr_el1, spsr_el1), the kernel on
// the kernel stack where it left it (SP_EL1, banked: the process's)
	.macro	save
	stp	x0, x1, [sp, #-16]!
	adrp	x0, cur_tf
	ldr	x0, [x0, :lo12:cur_tf]
	stp	x2, x3, [x0, #16]
	stp	x4, x5, [x0, #32]
	stp	x6, x7, [x0, #48]
	stp	x8, x9, [x0, #64]
	stp	x10, x11, [x0, #80]
	stp	x12, x13, [x0, #96]
	stp	x14, x15, [x0, #112]
	stp	x16, x17, [x0, #128]
	stp	x18, x19, [x0, #144]
	stp	x20, x21, [x0, #160]
	stp	x22, x23, [x0, #176]
	stp	x24, x25, [x0, #192]
	stp	x26, x27, [x0, #208]
	stp	x28, x29, [x0, #224]
	str	x30, [x0, #240]
	ldp	x2, x3, [sp], #16
	stp	x2, x3, [x0]
	mrs	x1, sp_el0
	str	x1, [x0, #248]
	mrs	x1, elr_el1
	str	x1, [x0, #256]
	mrs	x1, spsr_el1
	str	x1, [x0, #264]
	.endm

// a synchronous exception: a system call (ESR's class 0x15, svc), else
// the process's fault
el0_sync:
	save
	mrs	x0, esr_el1
	lsr	x1, x0, #26
	cmp	x1, #0x15
	b.ne	1f
	bl	trap
	b	user_return
1:	bl	user_abort64
	b	user_return

el0_irq:
	save
	bl	pi4_irq
	b	user_return

// back to EL0, from the running process's trap frame (it may be another
// process's than the one that trapped: a switch in between)
	.global	user_return
user_return:
	adrp	x0, cur_tf
	ldr	x0, [x0, :lo12:cur_tf]
	ldr	x1, [x0, #248]
	msr	sp_el0, x1
	ldr	x1, [x0, #256]
	msr	elr_el1, x1
	ldr	x1, [x0, #264]
	msr	spsr_el1, x1
	ldp	x2, x3, [x0, #16]
	ldp	x4, x5, [x0, #32]
	ldp	x6, x7, [x0, #48]
	ldp	x8, x9, [x0, #64]
	ldp	x10, x11, [x0, #80]
	ldp	x12, x13, [x0, #96]
	ldp	x14, x15, [x0, #112]
	ldp	x16, x17, [x0, #128]
	ldp	x18, x19, [x0, #144]
	ldp	x20, x21, [x0, #160]
	ldp	x22, x23, [x0, #176]
	ldp	x24, x25, [x0, #192]
	ldp	x26, x27, [x0, #208]
	ldp	x28, x29, [x0, #224]
	ldr	x30, [x0, #240]
	ldp	x0, x1, [x0]
	eret

kernel_exception:
	mrs	x0, esr_el1
	mrs	x1, elr_el1
	mrs	x2, far_el1
	bl	kfault64
	b	halt

// swtch(from, to): the callee-saved registers (x19-x29, sp, lr, d8-d15:
// runtime.c's struct context) saved in from, loaded from to
	.global	swtch
swtch:
	stp	x19, x20, [x0, #0]
	stp	x21, x22, [x0, #16]
	stp	x23, x24, [x0, #32]
	stp	x25, x26, [x0, #48]
	stp	x27, x28, [x0, #64]
	str	x29, [x0, #80]
	mov	x2, sp
	stp	x2, x30, [x0, #88]
	stp	d8, d9, [x0, #104]
	stp	d10, d11, [x0, #120]
	stp	d12, d13, [x0, #136]
	stp	d14, d15, [x0, #152]
	ldp	x19, x20, [x1, #0]
	ldp	x21, x22, [x1, #16]
	ldp	x23, x24, [x1, #32]
	ldp	x25, x26, [x1, #48]
	ldp	x27, x28, [x1, #64]
	ldr	x29, [x1, #80]
	ldp	x2, x30, [x1, #88]
	mov	sp, x2
	ldp	d8, d9, [x1, #104]
	ldp	d10, d11, [x1, #120]
	ldp	d12, d13, [x1, #136]
	ldp	d14, d15, [x1, #152]
	ret

// the file system's image, xv6 arm64-pi4's fs.img: the ramdisk, written
// in place (a data section: the kernel's to change)
	.data
	.balign	4096
	.global	fs_image
	.global	fs_image_end
fs_image:
	.incbin	"build/pi4/fs.img"
fs_image_end:

// the tables: the kernel's, the boot's, the empty one (TTBR0 when no
// process runs); cleared with the bss
	.bss
	.balign	4096
kernel_l1:
	.space	4096
boot_l1:
	.space	4096
	.global	empty_pgdir
empty_pgdir:
	.space	4096
