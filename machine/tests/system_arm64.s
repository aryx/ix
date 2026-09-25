// Claude Code
//
// Copyright (C) 2026 Yoann Padioleau
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Library General Public License
// (LGPL) as published by the Free Software Foundation; either version
// 2 of the License, or (at your option) any later version.
//
// The system instructions Arm64 decodes (plan_pi.md, phase G1): its
// table of system registers and operations, the hints, barriers,
// exception generating instructions, the exclusive and ordered loads
// and stores. census_system.sh assembles it (GNU as) into
// words_arm64_system.txt, with xv6 arm64-pi4's instructions.
mrs x0, nzcv
mrs x0, daif
mrs x0, currentel
mrs x0, spsel
mrs x0, fpcr
mrs x0, fpsr
mrs x0, sp_el0
mrs x0, sp_el1
mrs x0, sp_el2
mrs x0, spsr_el1
mrs x0, elr_el1
mrs x0, spsr_el2
mrs x0, elr_el2
mrs x0, spsr_el3
mrs x0, elr_el3
mrs x0, sctlr_el1
mrs x0, actlr_el1
mrs x0, cpacr_el1
mrs x0, sctlr_el2
mrs x0, hcr_el2
mrs x0, cptr_el2
mrs x0, sctlr_el3
mrs x0, scr_el3
mrs x0, cptr_el3
mrs x0, ttbr0_el1
mrs x0, ttbr1_el1
mrs x0, tcr_el1
mrs x0, esr_el1
mrs x0, esr_el2
mrs x0, esr_el3
mrs x0, far_el1
mrs x0, far_el2
mrs x0, far_el3
mrs x0, par_el1
mrs x0, mair_el1
mrs x0, vbar_el1
mrs x0, vbar_el2
mrs x0, vbar_el3
mrs x0, contextidr_el1
mrs x0, tpidr_el0
mrs x0, tpidrro_el0
mrs x0, tpidr_el1
mrs x0, midr_el1
mrs x0, mpidr_el1
mrs x0, revidr_el1
mrs x0, ctr_el0
mrs x0, dczid_el0
mrs x0, id_aa64pfr0_el1
mrs x0, id_aa64mmfr0_el1
mrs x0, id_aa64isar0_el1
mrs x0, cntfrq_el0
mrs x0, cntpct_el0
mrs x0, cntvct_el0
mrs x0, cntp_tval_el0
mrs x0, cntp_ctl_el0
mrs x0, cntp_cval_el0
mrs x0, cntv_tval_el0
mrs x0, cntv_ctl_el0
mrs x0, cntv_cval_el0
mrs x0, cntkctl_el1
mrs x0, cnthctl_el2
mrs x0, cntvoff_el2
msr spsel, #1
msr daifset, #2
msr daifclr, #0xf
ic ialluis
ic iallu
ic ivau, x1
dc ivac, x1
dc isw, x1
dc csw, x1
dc cisw, x1
dc zva, x1
dc cvac, x1
dc cvau, x1
dc civac, x1
dc cvap, x1
at s1e1r, x1
at s1e1w, x1
at s1e0r, x1
at s1e0w, x1
tlbi vmalle1is
tlbi vmalle1
tlbi vae1is, x1
tlbi vae1, x1
tlbi aside1, x1
tlbi aside1is, x1
tlbi vaae1, x1
tlbi vaae1is, x1
tlbi vale1, x1
tlbi vale1is, x1
tlbi vaale1, x1
tlbi alle2
tlbi alle3
tlbi alle1
tlbi alle1is
sys #0, c8, c7, #0, x1
yield
wfe
wfi
sev
sevl
dsb sy
dsb ish
dsb ishst
dsb ld
dsb #0
dsb #4
dmb ish
dmb oshld
isb
isb #3
clrex
clrex #5
eret
hvc #0
smc #1
brk #3
ldxr w1, [x2]
ldxr x1, [x2]
ldxrb w1, [x2]
ldxrh w1, [x2]
ldaxr x1, [x2]
stxr w3, x1, [x2]
stlxr w3, w1, [x2]
stlxrh w3, w1, [sp]
ldar x1, [x2]
ldarb w1, [x2]
stlr w1, [x2]
stlrh w1, [sp]
ldlar x1, [x2]
stllr x1, [x2]
