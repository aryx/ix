getline:
	addi	sp, sp, -24
	stw	lr, 12(sp)
	la	r1, sh.s1
	stw	r1, 0(sp)
	call	print
	mov	r1, r13
	addi	r1, sp, 20
	li	r2, 0
	stw	r2, 0(r1)
	mov	r1, r2
sh.L1:
	addi	r1, sp, 20
	ldw	r1, 0(r1)
	li	r2, 256
	li	r3, 1
	sub	r2, r2, r3
	sltu	r1, r1, r2
	beq	r1, zero, sh.L3
	li	r1, 0
	la	r2, line
	addi	r3, sp, 20
	ldw	r3, 0(r3)
	add	r2, r2, r3
	li	r3, 1
	stw	r1, 0(sp)
	stw	r2, 4(sp)
	stw	r3, 8(sp)
	call	read
	mov	r1, r13
	li	r2, 1
	sub	r1, r1, r2
	sltu	r1, zero, r1
	beq	r1, zero, sh.L4
	addi	r1, sp, 20
	ldw	r1, 0(r1)
	li	r2, 0
	sub	r1, r1, r2
	sltiu	r1, r1, 1
	beq	r1, zero, sh.L5
	li	r1, -1
	mov	r13, r1
	ldw	lr, 12(sp)
	addi	sp, sp, 24
	ret
sh.L5:
	j	sh.L3
sh.L4:
	la	r1, line
	addi	r2, sp, 20
	ldw	r2, 0(r2)
	add	r1, r1, r2
	ldb	r1, 0(r1)
	shli	r1, r1, 24
	sari	r1, r1, 24
	li	r2, 10
	sub	r1, r1, r2
	sltiu	r1, r1, 1
	beq	r1, zero, sh.L6
	j	sh.L3
sh.L6:
sh.L2:
	addi	r1, sp, 20
	mov	r2, r1
	ldw	r2, 0(r2)
	li	r3, 1
	add	r2, r2, r3
	stw	r2, 0(r1)
	mov	r1, r2
	li	r2, 1
	sub	r1, r1, r2
	j	sh.L1
sh.L3:
	la	r1, line
	addi	r2, sp, 20
	ldw	r2, 0(r2)
	add	r1, r1, r2
	li	r2, 0
	stb	r2, 0(r1)
	mov	r1, r2
	addi	r1, sp, 20
	ldw	r1, 0(r1)
	mov	r13, r1
	ldw	lr, 12(sp)
	addi	sp, sp, 24
	ret
tokenize:
	addi	sp, sp, -24
	stw	lr, 0(sp)
	addi	r1, sp, 16
	la	r2, spaced
	stw	r2, 0(r1)
	mov	r1, r2
	addi	r1, sp, 20
	la	r2, line
	stw	r2, 0(r1)
	mov	r1, r2
sh.L7:
	addi	r1, sp, 20
	ldw	r1, 0(r1)
	ldb	r1, 0(r1)
	shli	r1, r1, 24
	sari	r1, r1, 24
	beq	r1, zero, sh.L9
	addi	r1, sp, 20
	ldw	r1, 0(r1)
	ldb	r1, 0(r1)
	shli	r1, r1, 24
	sari	r1, r1, 24
	li	r2, 60
	sub	r1, r1, r2
	sltiu	r1, r1, 1
	beq	r1, zero, sh.L15
	li	r1, 1
	j	sh.L16
sh.L15:
	addi	r1, sp, 20
	ldw	r1, 0(r1)
	ldb	r1, 0(r1)
	shli	r1, r1, 24
	sari	r1, r1, 24
	li	r2, 62
	sub	r1, r1, r2
	sltiu	r1, r1, 1
	beq	r1, zero, sh.L17
	li	r1, 1
	j	sh.L18
sh.L17:
	li	r1, 0
sh.L18:
sh.L16:
	beq	r1, zero, sh.L13
	li	r1, 1
	j	sh.L14
sh.L13:
	addi	r1, sp, 20
	ldw	r1, 0(r1)
	ldb	r1, 0(r1)
	shli	r1, r1, 24
	sari	r1, r1, 24
	li	r2, 124
	sub	r1, r1, r2
	sltiu	r1, r1, 1
	beq	r1, zero, sh.L19
	li	r1, 1
	j	sh.L20
sh.L19:
	li	r1, 0
sh.L20:
sh.L14:
	beq	r1, zero, sh.L11
	li	r1, 1
	j	sh.L12
sh.L11:
	addi	r1, sp, 20
	ldw	r1, 0(r1)
	ldb	r1, 0(r1)
	shli	r1, r1, 24
	sari	r1, r1, 24
	li	r2, 59
	sub	r1, r1, r2
	sltiu	r1, r1, 1
	beq	r1, zero, sh.L21
	li	r1, 1
	j	sh.L22
sh.L21:
	li	r1, 0
sh.L22:
sh.L12:
	beq	r1, zero, sh.L10
	addi	r1, sp, 16
	mov	r2, r1
	ldw	r2, 0(r2)
	li	r3, 1
	add	r2, r2, r3
	stw	r2, 0(r1)
	mov	r1, r2
	li	r2, 1
	sub	r1, r1, r2
	li	r2, 32
	stb	r2, 0(r1)
	mov	r1, r2
	addi	r1, sp, 16
	mov	r2, r1
	ldw	r2, 0(r2)
	li	r3, 1
	add	r2, r2, r3
	stw	r2, 0(r1)
	mov	r1, r2
	li	r2, 1
	sub	r1, r1, r2
	addi	r2, sp, 20
	ldw	r2, 0(r2)
	ldb	r2, 0(r2)
	shli	r2, r2, 24
	sari	r2, r2, 24
	stb	r2, 0(r1)
	mov	r1, r2
	addi	r1, sp, 16
	mov	r2, r1
	ldw	r2, 0(r2)
	li	r3, 1
	add	r2, r2, r3
	stw	r2, 0(r1)
	mov	r1, r2
	li	r2, 1
	sub	r1, r1, r2
	li	r2, 32
	stb	r2, 0(r1)
	mov	r1, r2
	j	sh.L23
sh.L10:
	addi	r1, sp, 16
	mov	r2, r1
	ldw	r2, 0(r2)
	li	r3, 1
	add	r2, r2, r3
	stw	r2, 0(r1)
	mov	r1, r2
	li	r2, 1
	sub	r1, r1, r2
	addi	r2, sp, 20
	ldw	r2, 0(r2)
	ldb	r2, 0(r2)
	shli	r2, r2, 24
	sari	r2, r2, 24
	stb	r2, 0(r1)
	mov	r1, r2
sh.L23:
sh.L8:
	addi	r1, sp, 20
	mov	r2, r1
	ldw	r2, 0(r2)
	li	r3, 1
	add	r2, r2, r3
	stw	r2, 0(r1)
	mov	r1, r2
	li	r2, 1
	sub	r1, r1, r2
	j	sh.L7
sh.L9:
	addi	r1, sp, 16
	ldw	r1, 0(r1)
	li	r2, 0
	stb	r2, 0(r1)
	mov	r1, r2
	addi	r1, sp, 12
	li	r2, 0
	stw	r2, 0(r1)
	mov	r1, r2
	addi	r1, sp, 20
	la	r2, spaced
	stw	r2, 0(r1)
	mov	r1, r2
sh.L24:
	addi	r1, sp, 20
	ldw	r1, 0(r1)
	ldb	r1, 0(r1)
	shli	r1, r1, 24
	sari	r1, r1, 24
	beq	r1, zero, sh.L27
	addi	r1, sp, 12
	ldw	r1, 0(r1)
	li	r2, 63
	slt	r1, r1, r2
	beq	r1, zero, sh.L29
	li	r1, 1
	j	sh.L30
sh.L29:
	li	r1, 0
sh.L30:
	j	sh.L28
sh.L27:
	li	r1, 0
sh.L28:
	beq	r1, zero, sh.L26
sh.L31:
	addi	r1, sp, 20
	ldw	r1, 0(r1)
	ldb	r1, 0(r1)
	shli	r1, r1, 24
	sari	r1, r1, 24
	li	r2, 32
	sub	r1, r1, r2
	sltiu	r1, r1, 1
	beq	r1, zero, sh.L34
	li	r1, 1
	j	sh.L35
sh.L34:
	addi	r1, sp, 20
	ldw	r1, 0(r1)
	ldb	r1, 0(r1)
	shli	r1, r1, 24
	sari	r1, r1, 24
	li	r2, 9
	sub	r1, r1, r2
	sltiu	r1, r1, 1
	beq	r1, zero, sh.L36
	li	r1, 1
	j	sh.L37
sh.L36:
	li	r1, 0
sh.L37:
sh.L35:
	beq	r1, zero, sh.L33
	addi	r1, sp, 20
	mov	r2, r1
	ldw	r2, 0(r2)
	li	r3, 1
	add	r2, r2, r3
	stw	r2, 0(r1)
	mov	r1, r2
	li	r2, 1
	sub	r1, r1, r2
	li	r2, 0
	stb	r2, 0(r1)
	mov	r1, r2
sh.L32:
	j	sh.L31
sh.L33:
	addi	r1, sp, 20
	ldw	r1, 0(r1)
	ldb	r1, 0(r1)
	shli	r1, r1, 24
	sari	r1, r1, 24
	li	r2, 0
	sub	r1, r1, r2
	sltiu	r1, r1, 1
	beq	r1, zero, sh.L38
	j	sh.L26
sh.L38:
	la	r1, toks
	addi	r2, sp, 12
	mov	r3, r2
	ldw	r3, 0(r3)
	li	r4, 1
	add	r3, r3, r4
	stw	r3, 0(r2)
	mov	r2, r3
	li	r3, 1
	sub	r2, r2, r3
	li	r3, 4
	mul	r2, r2, r3
	add	r1, r1, r2
	addi	r2, sp, 20
	ldw	r2, 0(r2)
	stw	r2, 0(r1)
	mov	r1, r2
sh.L39:
	addi	r1, sp, 20
	ldw	r1, 0(r1)
	ldb	r1, 0(r1)
	shli	r1, r1, 24
	sari	r1, r1, 24
	beq	r1, zero, sh.L44
	addi	r1, sp, 20
	ldw	r1, 0(r1)
	ldb	r1, 0(r1)
	shli	r1, r1, 24
	sari	r1, r1, 24
	li	r2, 32
	sub	r1, r1, r2
	sltu	r1, zero, r1
	beq	r1, zero, sh.L46
	li	r1, 1
	j	sh.L47
sh.L46:
	li	r1, 0
sh.L47:
	j	sh.L45
sh.L44:
	li	r1, 0
sh.L45:
	beq	r1, zero, sh.L42
	addi	r1, sp, 20
	ldw	r1, 0(r1)
	ldb	r1, 0(r1)
	shli	r1, r1, 24
	sari	r1, r1, 24
	li	r2, 9
	sub	r1, r1, r2
	sltu	r1, zero, r1
	beq	r1, zero, sh.L48
	li	r1, 1
	j	sh.L49
sh.L48:
	li	r1, 0
sh.L49:
	j	sh.L43
sh.L42:
	li	r1, 0
sh.L43:
	beq	r1, zero, sh.L41
	addi	r1, sp, 20
	mov	r2, r1
	ldw	r2, 0(r2)
	li	r3, 1
	add	r2, r2, r3
	stw	r2, 0(r1)
	mov	r1, r2
	li	r2, 1
	sub	r1, r1, r2
sh.L40:
	j	sh.L39
sh.L41:
sh.L25:
	j	sh.L24
sh.L26:
	addi	r1, sp, 12
	ldw	r1, 0(r1)
	mov	r13, r1
	ldw	lr, 0(sp)
	addi	sp, sp, 24
	ret
command:
	addi	sp, sp, -184
	stw	lr, 12(sp)
	addi	r1, sp, 48
	li	r2, 0
	stw	r2, 0(r1)
	mov	r1, r2
	addi	r1, sp, 28
	addi	r2, sp, 24
	li	r3, -1
	stw	r3, 0(r2)
	mov	r2, r3
	stw	r2, 0(r1)
	mov	r1, r2
	addi	r1, sp, 52
	li	r2, 0
	stw	r2, 0(r1)
	mov	r1, r2
sh.L50:
	addi	r1, sp, 52
	ldw	r1, 0(r1)
	addi	r2, sp, 188
	ldw	r2, 0(r2)
	slt	r1, r1, r2
	beq	r1, zero, sh.L52
	addi	r1, sp, 184
	ldw	r1, 0(r1)
	addi	r2, sp, 52
	ldw	r2, 0(r2)
	li	r3, 4
	mul	r2, r2, r3
	add	r1, r1, r2
	ldw	r1, 0(r1)
	la	r2, sh.s2
	stw	r1, 0(sp)
	stw	r2, 4(sp)
	call	strcmp
	mov	r1, r13
	li	r2, 0
	sub	r1, r1, r2
	sltiu	r1, r1, 1
	beq	r1, zero, sh.L54
	addi	r1, sp, 52
	ldw	r1, 0(r1)
	li	r2, 1
	add	r1, r1, r2
	addi	r2, sp, 188
	ldw	r2, 0(r2)
	slt	r1, r1, r2
	beq	r1, zero, sh.L56
	li	r1, 1
	j	sh.L57
sh.L56:
	li	r1, 0
sh.L57:
	j	sh.L55
sh.L54:
	li	r1, 0
sh.L55:
	beq	r1, zero, sh.L53
	addi	r1, sp, 28
	addi	r2, sp, 184
	ldw	r2, 0(r2)
	addi	r3, sp, 52
	mov	r4, r3
	ldw	r4, 0(r4)
	li	r5, 1
	add	r4, r4, r5
	stw	r4, 0(r3)
	mov	r3, r4
	li	r4, 4
	mul	r3, r3, r4
	add	r2, r2, r3
	ldw	r2, 0(r2)
	li	r3, 0
	stw	r1, 20(sp)
	stw	r2, 0(sp)
	stw	r3, 4(sp)
	call	open
	ldw	r1, 20(sp)
	mov	r2, r13
	stw	r2, 0(r1)
	mov	r1, r2
	j	sh.L58
sh.L53:
	addi	r1, sp, 184
	ldw	r1, 0(r1)
	addi	r2, sp, 52
	ldw	r2, 0(r2)
	li	r3, 4
	mul	r2, r2, r3
	add	r1, r1, r2
	ldw	r1, 0(r1)
	la	r2, sh.s3
	stw	r1, 0(sp)
	stw	r2, 4(sp)
	call	strcmp
	mov	r1, r13
	li	r2, 0
	sub	r1, r1, r2
	sltiu	r1, r1, 1
	beq	r1, zero, sh.L60
	addi	r1, sp, 52
	ldw	r1, 0(r1)
	li	r2, 1
	add	r1, r1, r2
	addi	r2, sp, 188
	ldw	r2, 0(r2)
	slt	r1, r1, r2
	beq	r1, zero, sh.L62
	li	r1, 1
	j	sh.L63
sh.L62:
	li	r1, 0
sh.L63:
	j	sh.L61
sh.L60:
	li	r1, 0
sh.L61:
	beq	r1, zero, sh.L59
	addi	r1, sp, 24
	addi	r2, sp, 184
	ldw	r2, 0(r2)
	addi	r3, sp, 52
	mov	r4, r3
	ldw	r4, 0(r4)
	li	r5, 1
	add	r4, r4, r5
	stw	r4, 0(r3)
	mov	r3, r4
	li	r4, 4
	mul	r3, r3, r4
	add	r2, r2, r3
	ldw	r2, 0(r2)
	li	r3, 512
	li	r4, 1
	or	r3, r3, r4
	li	r4, 1024
	or	r3, r3, r4
	stw	r1, 20(sp)
	stw	r2, 0(sp)
	stw	r3, 4(sp)
	call	open
	ldw	r1, 20(sp)
	mov	r2, r13
	stw	r2, 0(r1)
	mov	r1, r2
	j	sh.L64
sh.L59:
	addi	r1, sp, 48
	ldw	r1, 0(r1)
	li	r2, 31
	slt	r1, r1, r2
	beq	r1, zero, sh.L65
	addi	r1, sp, 56
	addi	r2, sp, 48
	mov	r3, r2
	ldw	r3, 0(r3)
	li	r4, 1
	add	r3, r3, r4
	stw	r3, 0(r2)
	mov	r2, r3
	li	r3, 1
	sub	r2, r2, r3
	li	r3, 4
	mul	r2, r2, r3
	add	r1, r1, r2
	addi	r2, sp, 184
	ldw	r2, 0(r2)
	addi	r3, sp, 52
	ldw	r3, 0(r3)
	li	r4, 4
	mul	r3, r3, r4
	add	r2, r2, r3
	ldw	r2, 0(r2)
	stw	r2, 0(r1)
	mov	r1, r2
sh.L65:
sh.L64:
sh.L58:
sh.L51:
	addi	r1, sp, 52
	mov	r2, r1
	ldw	r2, 0(r2)
	li	r3, 1
	add	r2, r2, r3
	stw	r2, 0(r1)
	mov	r1, r2
	li	r2, 1
	sub	r1, r1, r2
	j	sh.L50
sh.L52:
	addi	r1, sp, 56
	addi	r2, sp, 48
	ldw	r2, 0(r2)
	li	r3, 4
	mul	r2, r2, r3
	add	r1, r1, r2
	li	r2, 0
	stw	r2, 0(r1)
	mov	r1, r2
	addi	r1, sp, 36
	li	r2, 0
	li	r3, 4
	mul	r2, r2, r3
	add	r1, r1, r2
	addi	r2, sp, 28
	ldw	r2, 0(r2)
	li	r3, 0
	slt	r2, r2, r3
	xori	r2, r2, 1
	beq	r2, zero, sh.L66
	addi	r2, sp, 28
	ldw	r2, 0(r2)
	j	sh.L67
sh.L66:
	addi	r2, sp, 192
	ldw	r2, 0(r2)
sh.L67:
	stw	r2, 0(r1)
	mov	r1, r2
	addi	r1, sp, 36
	li	r2, 1
	li	r3, 4
	mul	r2, r2, r3
	add	r1, r1, r2
	addi	r2, sp, 24
	ldw	r2, 0(r2)
	li	r3, 0
	slt	r2, r2, r3
	xori	r2, r2, 1
	beq	r2, zero, sh.L68
	addi	r2, sp, 24
	ldw	r2, 0(r2)
	j	sh.L69
sh.L68:
	addi	r2, sp, 196
	ldw	r2, 0(r2)
sh.L69:
	stw	r2, 0(r1)
	mov	r1, r2
	addi	r1, sp, 36
	li	r2, 2
	li	r3, 4
	mul	r2, r2, r3
	add	r1, r1, r2
	li	r2, 2
	stw	r2, 0(r1)
	mov	r1, r2
	addi	r1, sp, 32
	li	r2, -1
	stw	r2, 0(r1)
	mov	r1, r2
	addi	r1, sp, 48
	ldw	r1, 0(r1)
	li	r2, 0
	slt	r1, r2, r1
	beq	r1, zero, sh.L70
	addi	r1, sp, 56
	li	r2, 0
	li	r3, 4
	mul	r2, r2, r3
	add	r1, r1, r2
	ldw	r1, 0(r1)
	li	r2, 0
	add	r1, r1, r2
	ldb	r1, 0(r1)
	shli	r1, r1, 24
	sari	r1, r1, 24
	li	r2, 47
	sub	r1, r1, r2
	sltiu	r1, r1, 1
	beq	r1, zero, sh.L72
	li	r1, 1
	j	sh.L73
sh.L72:
	addi	r1, sp, 56
	li	r2, 0
	li	r3, 4
	mul	r2, r2, r3
	add	r1, r1, r2
	ldw	r1, 0(r1)
	li	r2, 0
	add	r1, r1, r2
	ldb	r1, 0(r1)
	shli	r1, r1, 24
	sari	r1, r1, 24
	li	r2, 46
	sub	r1, r1, r2
	sltiu	r1, r1, 1
	beq	r1, zero, sh.L74
	li	r1, 1
	j	sh.L75
sh.L74:
	li	r1, 0
sh.L75:
sh.L73:
	beq	r1, zero, sh.L71
	la	r1, paths
	addi	r2, sp, 200
	ldw	r2, 0(r2)
	li	r3, 64
	mul	r2, r2, r3
	add	r1, r1, r2
	addi	r2, sp, 56
	li	r3, 0
	li	r4, 4
	mul	r3, r3, r4
	add	r2, r2, r3
	ldw	r2, 0(r2)
	stw	r1, 0(sp)
	stw	r2, 4(sp)
	call	strcpy
	mov	r1, r13
	j	sh.L76
sh.L71:
	la	r1, paths
	addi	r2, sp, 200
	ldw	r2, 0(r2)
	li	r3, 64
	mul	r2, r2, r3
	add	r1, r1, r2
	la	r2, sh.s4
	addi	r3, sp, 56
	li	r4, 0
	li	r5, 4
	mul	r4, r4, r5
	add	r3, r3, r4
	ldw	r3, 0(r3)
	stw	r1, 0(sp)
	stw	r2, 4(sp)
	stw	r3, 8(sp)
	call	sprint
	mov	r1, r13
sh.L76:
	addi	r1, sp, 32
	la	r2, paths
	addi	r3, sp, 200
	ldw	r3, 0(r3)
	li	r4, 64
	mul	r3, r3, r4
	add	r2, r2, r3
	addi	r3, sp, 56
	addi	r4, sp, 36
	stw	r1, 20(sp)
	stw	r2, 0(sp)
	stw	r3, 4(sp)
	stw	r4, 8(sp)
	call	spawn
	ldw	r1, 20(sp)
	mov	r2, r13
	stw	r2, 0(r1)
	mov	r1, r2
	li	r2, 0
	slt	r1, r1, r2
	beq	r1, zero, sh.L77
	la	r1, sh.s5
	addi	r2, sp, 56
	li	r3, 0
	li	r4, 4
	mul	r3, r3, r4
	add	r2, r2, r3
	ldw	r2, 0(r2)
	stw	r1, 0(sp)
	stw	r2, 4(sp)
	call	print
	mov	r1, r13
sh.L77:
sh.L70:
	addi	r1, sp, 28
	ldw	r1, 0(r1)
	li	r2, 0
	slt	r1, r1, r2
	xori	r1, r1, 1
	beq	r1, zero, sh.L78
	addi	r1, sp, 28
	ldw	r1, 0(r1)
	stw	r1, 0(sp)
	call	close
	mov	r1, r13
sh.L78:
	addi	r1, sp, 24
	ldw	r1, 0(r1)
	li	r2, 0
	slt	r1, r1, r2
	xori	r1, r1, 1
	beq	r1, zero, sh.L79
	addi	r1, sp, 24
	ldw	r1, 0(r1)
	stw	r1, 0(sp)
	call	close
	mov	r1, r13
sh.L79:
	addi	r1, sp, 32
	ldw	r1, 0(r1)
	mov	r13, r1
	ldw	lr, 12(sp)
	addi	sp, sp, 184
	ret
pipeline:
	addi	sp, sp, -48
	stw	lr, 20(sp)
	addi	r1, sp, 36
	li	r2, 0
	stw	r2, 0(r1)
	mov	r1, r2
	addi	r1, sp, 24
	li	r2, 0
	stw	r2, 0(r1)
	mov	r1, r2
	addi	r1, sp, 40
	li	r2, 0
	stw	r2, 0(r1)
	mov	r1, r2
sh.L80:
	addi	r1, sp, 40
	ldw	r1, 0(r1)
	addi	r2, sp, 52
	ldw	r2, 0(r2)
	slt	r1, r1, r2
	beq	r1, zero, sh.L82
	addi	r1, sp, 44
	addi	r2, sp, 40
	ldw	r2, 0(r2)
	stw	r2, 0(r1)
	mov	r1, r2
sh.L83:
	addi	r1, sp, 44
	ldw	r1, 0(r1)
	addi	r2, sp, 52
	ldw	r2, 0(r2)
	slt	r1, r1, r2
	beq	r1, zero, sh.L86
	addi	r1, sp, 48
	ldw	r1, 0(r1)
	addi	r2, sp, 44
	ldw	r2, 0(r2)
	li	r3, 4
	mul	r2, r2, r3
	add	r1, r1, r2
	ldw	r1, 0(r1)
	la	r2, sh.s6
	stw	r1, 0(sp)
	stw	r2, 4(sp)
	call	strcmp
	mov	r1, r13
	li	r2, 0
	sub	r1, r1, r2
	sltu	r1, zero, r1
	beq	r1, zero, sh.L88
	li	r1, 1
	j	sh.L89
sh.L88:
	li	r1, 0
sh.L89:
	j	sh.L87
sh.L86:
	li	r1, 0
sh.L87:
	beq	r1, zero, sh.L85
sh.L84:
	addi	r1, sp, 44
	mov	r2, r1
	ldw	r2, 0(r2)
	li	r3, 1
	add	r2, r2, r3
	stw	r2, 0(r1)
	mov	r1, r2
	li	r2, 1
	sub	r1, r1, r2
	j	sh.L83
sh.L85:
	addi	r1, sp, 28
	li	r2, 0
	li	r3, 4
	mul	r2, r2, r3
	add	r1, r1, r2
	li	r2, -1
	stw	r2, 0(r1)
	mov	r1, r2
	addi	r1, sp, 28
	li	r2, 1
	li	r3, 4
	mul	r2, r2, r3
	add	r1, r1, r2
	li	r2, 1
	stw	r2, 0(r1)
	mov	r1, r2
	addi	r1, sp, 44
	ldw	r1, 0(r1)
	addi	r2, sp, 52
	ldw	r2, 0(r2)
	slt	r1, r1, r2
	beq	r1, zero, sh.L91
	addi	r1, sp, 28
	stw	r1, 0(sp)
	call	pipe
	mov	r1, r13
	li	r2, 0
	slt	r1, r1, r2
	beq	r1, zero, sh.L93
	li	r1, 1
	j	sh.L94
sh.L93:
	li	r1, 0
sh.L94:
	j	sh.L92
sh.L91:
	li	r1, 0
sh.L92:
	beq	r1, zero, sh.L90
	la	r1, sh.s7
	stw	r1, 0(sp)
	call	print
	mov	r1, r13
	j	sh.L82
sh.L90:
	addi	r1, sp, 48
	ldw	r1, 0(r1)
	addi	r2, sp, 40
	ldw	r2, 0(r2)
	li	r3, 4
	mul	r2, r2, r3
	add	r1, r1, r2
	addi	r2, sp, 44
	ldw	r2, 0(r2)
	addi	r3, sp, 40
	ldw	r3, 0(r3)
	sub	r2, r2, r3
	addi	r3, sp, 36
	ldw	r3, 0(r3)
	addi	r4, sp, 28
	li	r5, 1
	li	r6, 4
	mul	r5, r5, r6
	add	r4, r4, r5
	ldw	r4, 0(r4)
	addi	r5, sp, 24
	ldw	r5, 0(r5)
	stw	r1, 0(sp)
	stw	r2, 4(sp)
	stw	r3, 8(sp)
	stw	r4, 12(sp)
	stw	r5, 16(sp)
	call	command
	mov	r1, r13
	li	r2, 0
	slt	r1, r1, r2
	xori	r1, r1, 1
	beq	r1, zero, sh.L95
	addi	r1, sp, 24
	mov	r2, r1
	ldw	r2, 0(r2)
	li	r3, 1
	add	r2, r2, r3
	stw	r2, 0(r1)
	mov	r1, r2
	li	r2, 1
	sub	r1, r1, r2
sh.L95:
	addi	r1, sp, 36
	ldw	r1, 0(r1)
	li	r2, 0
	sub	r1, r1, r2
	sltu	r1, zero, r1
	beq	r1, zero, sh.L96
	addi	r1, sp, 36
	ldw	r1, 0(r1)
	stw	r1, 0(sp)
	call	close
	mov	r1, r13
sh.L96:
	addi	r1, sp, 28
	li	r2, 1
	li	r3, 4
	mul	r2, r2, r3
	add	r1, r1, r2
	ldw	r1, 0(r1)
	li	r2, 1
	sub	r1, r1, r2
	sltu	r1, zero, r1
	beq	r1, zero, sh.L97
	addi	r1, sp, 28
	li	r2, 1
	li	r3, 4
	mul	r2, r2, r3
	add	r1, r1, r2
	ldw	r1, 0(r1)
	stw	r1, 0(sp)
	call	close
	mov	r1, r13
sh.L97:
	addi	r1, sp, 36
	addi	r2, sp, 28
	li	r3, 0
	li	r4, 4
	mul	r3, r3, r4
	add	r2, r2, r3
	ldw	r2, 0(r2)
	stw	r2, 0(r1)
	mov	r1, r2
sh.L81:
	addi	r1, sp, 40
	addi	r2, sp, 44
	ldw	r2, 0(r2)
	li	r3, 1
	add	r2, r2, r3
	stw	r2, 0(r1)
	mov	r1, r2
	j	sh.L80
sh.L82:
	addi	r1, sp, 36
	ldw	r1, 0(r1)
	li	r2, 0
	slt	r1, r2, r1
	beq	r1, zero, sh.L98
	addi	r1, sp, 36
	ldw	r1, 0(r1)
	stw	r1, 0(sp)
	call	close
	mov	r1, r13
sh.L98:
sh.L99:
	addi	r1, sp, 24
	ldw	r1, 0(r1)
	li	r2, 0
	slt	r1, r2, r1
	beq	r1, zero, sh.L101
	li	r1, 0
	stw	r1, 0(sp)
	call	wait
	mov	r1, r13
sh.L100:
	addi	r1, sp, 24
	mov	r2, r1
	ldw	r2, 0(r2)
	li	r3, 1
	sub	r2, r2, r3
	stw	r2, 0(r1)
	mov	r1, r2
	li	r2, 1
	add	r1, r1, r2
	j	sh.L99
sh.L101:
	ldw	lr, 20(sp)
	addi	sp, sp, 48
	ret
main:
	addi	sp, sp, -32
	stw	lr, 8(sp)
sh.L102:
	call	getline
	mov	r1, r13
	li	r2, 0
	slt	r1, r1, r2
	xori	r1, r1, 1
	beq	r1, zero, sh.L104
	addi	r1, sp, 28
	stw	r1, 12(sp)
	call	tokenize
	ldw	r1, 12(sp)
	mov	r2, r13
	stw	r2, 0(r1)
	mov	r1, r2
	addi	r1, sp, 24
	li	r2, 0
	stw	r2, 0(r1)
	mov	r1, r2
sh.L105:
	addi	r1, sp, 24
	ldw	r1, 0(r1)
	addi	r2, sp, 28
	ldw	r2, 0(r2)
	slt	r1, r1, r2
	beq	r1, zero, sh.L107
	addi	r1, sp, 20
	addi	r2, sp, 24
	ldw	r2, 0(r2)
	stw	r2, 0(r1)
	mov	r1, r2
sh.L108:
	addi	r1, sp, 20
	ldw	r1, 0(r1)
	addi	r2, sp, 28
	ldw	r2, 0(r2)
	slt	r1, r1, r2
	beq	r1, zero, sh.L111
	la	r1, toks
	addi	r2, sp, 20
	ldw	r2, 0(r2)
	li	r3, 4
	mul	r2, r2, r3
	add	r1, r1, r2
	ldw	r1, 0(r1)
	la	r2, sh.s8
	stw	r1, 0(sp)
	stw	r2, 4(sp)
	call	strcmp
	mov	r1, r13
	li	r2, 0
	sub	r1, r1, r2
	sltu	r1, zero, r1
	beq	r1, zero, sh.L113
	li	r1, 1
	j	sh.L114
sh.L113:
	li	r1, 0
sh.L114:
	j	sh.L112
sh.L111:
	li	r1, 0
sh.L112:
	beq	r1, zero, sh.L110
sh.L109:
	addi	r1, sp, 20
	mov	r2, r1
	ldw	r2, 0(r2)
	li	r3, 1
	add	r2, r2, r3
	stw	r2, 0(r1)
	mov	r1, r2
	li	r2, 1
	sub	r1, r1, r2
	j	sh.L108
sh.L110:
	addi	r1, sp, 20
	ldw	r1, 0(r1)
	addi	r2, sp, 24
	ldw	r2, 0(r2)
	sub	r1, r1, r2
	sltiu	r1, r1, 1
	beq	r1, zero, sh.L115
	j	sh.L106
sh.L115:
	la	r1, toks
	addi	r2, sp, 24
	ldw	r2, 0(r2)
	li	r3, 4
	mul	r2, r2, r3
	add	r1, r1, r2
	ldw	r1, 0(r1)
	la	r2, sh.s9
	stw	r1, 0(sp)
	stw	r2, 4(sp)
	call	strcmp
	mov	r1, r13
	li	r2, 0
	sub	r1, r1, r2
	sltiu	r1, r1, 1
	beq	r1, zero, sh.L116
	addi	r1, sp, 20
	ldw	r1, 0(r1)
	addi	r2, sp, 24
	ldw	r2, 0(r2)
	sub	r1, r1, r2
	li	r2, 2
	slt	r1, r1, r2
	beq	r1, zero, sh.L118
	li	r1, 1
	j	sh.L119
sh.L118:
	la	r1, toks
	addi	r2, sp, 24
	ldw	r2, 0(r2)
	li	r3, 1
	add	r2, r2, r3
	li	r3, 4
	mul	r2, r2, r3
	add	r1, r1, r2
	ldw	r1, 0(r1)
	stw	r1, 0(sp)
	call	chdir
	mov	r1, r13
	li	r2, 0
	slt	r1, r1, r2
	beq	r1, zero, sh.L120
	li	r1, 1
	j	sh.L121
sh.L120:
	li	r1, 0
sh.L121:
sh.L119:
	beq	r1, zero, sh.L117
	la	r1, sh.s10
	stw	r1, 0(sp)
	call	print
	mov	r1, r13
sh.L117:
	j	sh.L122
sh.L116:
	la	r1, toks
	addi	r2, sp, 24
	ldw	r2, 0(r2)
	li	r3, 4
	mul	r2, r2, r3
	add	r1, r1, r2
	addi	r2, sp, 20
	ldw	r2, 0(r2)
	addi	r3, sp, 24
	ldw	r3, 0(r3)
	sub	r2, r2, r3
	stw	r1, 0(sp)
	stw	r2, 4(sp)
	call	pipeline
sh.L122:
sh.L106:
	addi	r1, sp, 24
	addi	r2, sp, 20
	ldw	r2, 0(r2)
	li	r3, 1
	add	r2, r2, r3
	stw	r2, 0(r1)
	mov	r1, r2
	j	sh.L105
sh.L107:
sh.L103:
	j	sh.L102
sh.L104:
	li	r1, 0
	stw	r1, 0(sp)
	call	exit
	ldw	lr, 8(sp)
	addi	sp, sp, 32
	ret
	.align	4
line:
	.space	256
	.align	4
spaced:
	.space	512
	.align	4
paths:
	.space	1024
	.align	4
toks:
	.space	256
	.align	4
sh.s1:
	.byte	36, 32, 0
	.align	4
sh.s2:
	.byte	60, 0
	.align	4
sh.s3:
	.byte	62, 0
	.align	4
sh.s4:
	.byte	47, 37, 115, 0
	.align	4
sh.s5:
	.byte	115, 104, 58, 32, 37, 115, 58, 32
	.byte	110, 111, 116, 32, 102, 111, 117, 110
	.byte	100, 10, 0
	.align	4
sh.s6:
	.byte	124, 0
	.align	4
sh.s7:
	.byte	115, 104, 58, 32, 110, 111, 32, 112
	.byte	105, 112, 101, 10, 0
	.align	4
sh.s8:
	.byte	59, 0
	.align	4
sh.s9:
	.byte	99, 100, 0
	.align	4
sh.s10:
	.byte	115, 104, 58, 32, 99, 100, 32, 102
	.byte	97, 105, 108, 101, 100, 10, 0
