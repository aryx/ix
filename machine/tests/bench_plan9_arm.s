// Claude Code
//
// Copyright (C) 2026 Yoann Padioleau
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Library General Public License
// (LGPL) as published by the Free Software Foundation; either version
// 2 of the License, or (at your option) any later version.
//
// bench.py's loop for goken's 5i, which runs Plan 9 a.out programs
// only (plan_arm.md, phase 6): 5,000,000 times 7 instructions (mul
// in place of mla, the count kept). Built and run with goken's tools:
//
//   5a -c bench_plan9_arm.s
//   5l -o loop.exe -H 2 -E _main bench_plan9_arm.5
//   time (printf ':c\n$q\n' | $GOKEN/machines/5i/o.out ./loop.exe)
//
TEXT _main(SB), $40
	MOVW $5000000, R0
loop:
	ADD R0, R1
	EOR R1<<3, R2
	MOVW 8(R13), R3
	MOVW R1, 16(R13)
	MUL R1, R2, R4
	SUB.S $1, R0
	BNE loop
	MOVW $0, R1
	MOVW R1, 4(R13)
	MOVW $3, R0
	SWI $0
	RET
