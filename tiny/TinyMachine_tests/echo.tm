; Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyMachine.ml)
;
; The console's input by its interrupt: the machine waits in a loop;
; each interrupt, every byte that came is read, upper-cased and
; written; the input's end halts. TinyMachine_test.sh gives it
; echo.input and compares with echo.expected.

	la	r1, trap
	csrw	tvec, r1
	li	r1, 2			; the console's interrupt only
	csrw	ie, r1
	li	r1, 3			; supervisor, interrupts on
	csrw	status, r1
wait:
	j	wait

trap:
	ldw	r3, -8(r0)
	li	r4, -1			; none now: back to waiting
	beq	r3, r4, back
	li	r4, -2			; the end
	beq	r3, r4, end
	li	r6, 97
	blt	r3, r6, out
	li	r6, 123
	bge	r3, r6, out
	addi	r3, r3, -32
out:
	stb	r3, -16(r0)
	j	trap
back:
	eret
end:
	stw	r0, -12(r0)
