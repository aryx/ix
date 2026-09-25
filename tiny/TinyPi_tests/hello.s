@ The smallest bare-metal program for the Pi1 (TinyPi_test.sh runs it
@ under TinyPi, mini-qemu and QEMU's raspi1ap): loaded at 0x8000,
@ entered in SVC mode, IRQ and FIQ masked. It writes a line to the
@ PL011 and halts: a WFI with IRQs masked never wakes.
	.text
	.global _start
_start:
	ldr r0, =message
	ldr r2, =0x20201000	@ the PL011
next:
	ldrb r1, [r0], #1
	cmp r1, #0
	beq halt
wait:
	ldr r3, [r2, #0x18]	@ FR: while the transmit FIFO is full
	tst r3, #0x20
	bne wait
	str r1, [r2]		@ DR: the character out
	b next
halt:
	wfi
	b halt
message:
	.asciz "hello, Pi\n"
