# Plan: mini-asm and mini-ld, an assembler and a linker from scratch, for arm and arm64 (`assembler/`, `linker/`)

Companions:
[`notes_asm.md`](../tutorials/notes_asm.md), the tutorial: from a `.s`
to a running program, Plan 9's assembly language, why the linker does
the encoding, the linker's passes, encoding arm and arm64, and the ELF
file. And
[`notes_asm_related_work.md`](../related-work/notes_asm_related_work.md):
from EDSAC's initial orders to GNU as and ld, gold, lld and mold, Plan
9 and Go, Wirth's Oberon, tcc, and the books on linkers. The twins
are the Principia books `assemblers/` and `linkers/` (5a and 5l, in
C), goken's 5a/5l and 7a/7l, and xix's `assembler/` and `linker/`
(o5a/o5l, o7a/o7l, in OCaml).

The fourth ix program, and the first of the toolchain: the C compiler
comes next, and will emit what this assembler reads and this linker
links. Planned as the others were; the principles are in
[`../README.md`](../README.md). Written for the author's review, who
asked to look especially at **the subset of arm and arm64 to handle**,
and **how to reach a low line count, even lower than xix's**.

## Context

An assembler turns `MOVW $42, R0` into bytes, and a linker puts the
bytes of many files together at their final addresses, with a header
the kernel can run. In Plan 9 the work is split differently from Unix:
**the assembler only parses**, and writes the instructions as they are
into an object file; **the linker chooses and encodes the machine
instructions**, once every address is known. That is the design this
plan keeps (decision 1).

Why these two programs now, and why together:

- **A reference runs today, and targets Linux.** goken (`~/goken`,
  goken9cc) is principia's toolchain made portable: its 5a/5l and
  7a/7l write Linux ELF executables that run on this machine, arm64
  (a Neoverse N1, which also runs 32-bit arm code). Checked: goken's
  `tests/s/exit` programs exit 42 natively on both, and its C programs
  with its libc run on both (floats aside, below). The author owns
  goken and allows changing it, behind flags, to ease the comparison.
- **Two architectures, one 32-bit and one 64-bit**, the author's
  choice: **arm (5)** for the Raspberry Pi, the machine of this
  teaching and hobby context, and **arm64 (7)**, which runs natively
  here, on the Pi with a 64-bit system, and on Macs. Two targets force
  the code to separate what is general from what is per-architecture,
  and arm64 is not "arm, wider": 31 registers and a zero register
  against 16 with the PC among them, few conditional instructions
  against all, other immediates, other relocations, ELF64.
- **Together**, because with the encoding in the linker, the assembler
  is a parser and a file format, and the linker's architecture part is
  where both targets live. One design, two programs.

## Principles

Those of [`../README.md`](../README.md), and four of its own:

- **The executable is the contract** (the author: "what is important
  is the final exe"). Objects and libraries are ix's own, marshalled as
  xix does, not goken's or Plan 9's formats: nothing but ix reads them.
  The tests compare what runs, and the bytes of the code.
- **The inputs are what a compiler emits.** The subset of instructions
  is what 5c and 7c emit, counted over a corpus (below), plus the
  hand-written assembly of goken's libc: "the most important
  instructions, not 100% coverage" (the author). An instruction outside
  it is an error, named.
- **goken may change to make the comparison possible**, behind flags,
  and each change is listed here (phase 0) and in goken's own log.
- **Integer arm, all of arm64.** 5c emits floating point for FPA, a
  coprocessor retired long ago: checked, a float program built by
  goken for arm dies with SIGILL on this machine and under qemu-arm,
  and a Raspberry Pi has no FPA either (it has VFP). So arm floating
  point is not run, until the compiler or goken emits VFP (an
  exercise, later a phase); arm64's floating point is kept. It is
  *encoded*, though (Status, the arm milestones): libc's `print`
  links float code even where it never runs.

## The input: Plan 9's assembly language

One syntax for every architecture, which is what makes one parser
possible (decision 2):

```
   TEXT  strchr(SB), $8           a function, its frame size
   MOVW  c+4(FP), R6              an argument: FP is the caller's frame
   MOVW  R0, s-4(SP)              a local: SP is this frame
   MOVW  $table(SB), R1           an address: SB is the static base
   CMP   $0, R6                   operands are source, destination
   BNE   2(PC)                    a branch, relative in instructions
   MOVW.EQ R1, R2                 a condition, as a suffix (arm)
   MOVM.IA [R0-R3], (R1)          a register list
   ADD   R1<<2, R2, R3            a shifted operand (arm)
   RET
   DATA  msg+0(SB)/8, $"Hello, w" initialized data
   GLOBL msg(SB), $14             its size
```

## The subset, counted

Counted with a script (`assembler/tests/count_opcodes.py`; the full
counts are in the appendix at the end) that compiles goken's C libraries -- libc's `port`, `fmt`,
`utf` and `math`, libbio, libregexp, libstring: 170 of 173 files
compile -- with `5c -S` and `7c -S`, and tallies each opcode and each
opcode's operand shapes, registers and constants normalized.

**arm (5c)**: 18,755 instructions, 138 opcodes with their conditions,
**51 without**. 16 opcodes make 90% of the instructions, 29 make 95%,
67 (with conditions) 99%:

| opcodes | count | kept |
|---|---:|---|
| `MOVW` (loads, stores, moves, constants) | 8,686 | yes |
| `B` `BL` `RET` and 11 conditional branches (`BEQ` ... `BPL`) | 5,335 | yes |
| `CMP` `CMN` | 1,607 | yes |
| `ADD` `SUB` `RSB` `AND` `ORR` `EOR` `MVN` | 1,536 | yes |
| `MOVB` `MOVBU` `MOVH` `MOVHU` | 502 | yes |
| `MOVM` (load and store multiple: block copies) | 133 | yes |
| `BCASE` `CASE` (switch tables) | 98 | yes |
| `SLL` `SRL` `SRA` | 115 | yes |
| `MUL` `MULU`, and `DIV` `DIVU` `MOD` `MODU` (calls to `_div`...) | 55 | yes |
| from libc's `.s`: `SWI` (the system call), `MULLU` | 2 | yes |
| floating point, FPA: `MOVD` `ADDD` `SUBD` `MULD` `DIVD` `CMPD` `MOVWD` `MOVDW` `MOVF` `MOVFD` `MOVDF` | 688 | encoded, not run (was **no**: see the Status) |

Every opcode may carry any of the 14 conditions (`.EQ` ... `.LE`; 5c
uses 12), and `.S` (set flags), `.P` and `.W` (post- and pre-index):
conditions are one 4-bit field, so they cost nothing.

**arm64 (7c)**: 19,223 instructions, **69 opcodes**: 16 make 90%, 25
make 95%, 39 make 99%. All kept:

| opcodes | count |
|---|---:|
| `MOV` `MOVW` `MOVWU` `MOVB` `MOVBU` `MOVH` `MOVHU` (loads, stores, moves, constants) | 8,626 |
| `B` `BL` `RETURN` and the conditional branches, `CBZ` (libc) | 5,836 |
| `CMP` `CMPW` `CMNW` | 1,776 |
| `ADD` `ADDW` `SUB` `SUBW` `AND` `ANDW` `ORR` `ORRW` `EORW` `NEG` `NEGW` `MVN` `MVNW` | 1,659 |
| `LSL` `LSLW` `LSRW` `ASRW`, `SXTW` | 494 |
| floating point: `FMOVD` `FMOVS` `FADDD` `FSUBD` `FMULD` `FDIVD` `FCMPD`, conversions (`SCVTFWD` `UCVTFWD` `FCVTZSDW` ...) | 673 |
| `MUL` `MULW` `UMULL` `SDIV` `SDIVW` `UDIV` `UDIVW` `REM` `REMW` `UREM` `UREMW` | 61 |
| `BCASE` `CASE`, and `SVC` (libc) | 98 |

**The operand shapes** are few. The corpus has 226 distinct
(opcode, operand shapes) pairs on arm, of which 33 make 90% of the
instructions and 69 make 97%; on arm64, 256 pairs, 54 for 90% and 91
for 97%. The shapes reduce to register, constant, `o(R)`, `o(FP)`,
`o(SP)`, `sym(SB)`, `$sym(SB)` and `$o(SP)` (addresses), `R<<n`
(shifted), `(R)(R)` (indexed), and a register list; arm64 has the
same without the shifts in loads. The encoders take all the pairs of
the corpus, not a percentage of them: a pair is a case of a few rules
(an arm data-processing instruction takes a register or a rotated
immediate whatever its opcode), so 226 pairs are some 40 rules, where
5l's optab has 204 rows and 7l's 302.

**What the subset leaves out**, all of it outside what a compiler for
user programs emits: arm's coprocessor and system instructions
(`MRC`, `MCR`, `MOVW CPSR`...: principia's kernels), the saturating
and SIMD instructions, Thumb; arm64's system registers, SIMD, atomics
beyond what libc needs; and the preprocessor of the assemblers
(`#include`, `#define`), which goken's libc `.s` files don't use --
principia's kernel `.s` files do (they include `mem.h` and `arm.h`),
so they wait for the compiler's preprocessor.

## Groundwork decisions

### 1. The linker chooses and encodes the instructions; the assembler only parses

The assembler writes the instructions it read, unencoded, and the
linker encodes them once it has laid out the whole program. This is
Plan 9's design (Rob Pike and Ken Thompson's toolchain), the one xix
follows, and **the one ix keeps, because it is the smallest design**:

- **No relocations.** Encoding after layout means every address is
  known when a word is made: objects carry no relocation records, and
  the linker has no relocation machinery, which is most of a Unix
  linker's complexity (GNU ld's and lld's relocation code per target).
- **One encoder per architecture.** The C compiler (next) will write
  the same instruction lists straight into an object, as 5c does,
  without printing assembly; the encoder lives once, in the linker,
  shared by both paths, instead of in the assembler and again in the
  compiler.
- **Decisions made once, when everything is known**: which form a
  branch takes, where literal pools go, how a large constant is built
  (`MOVW $0x12345678` is one pool load on arm, up to four `MOVZ`/`MOVK`
  on arm64), how a function's prologue looks. With the encoding in the
  assembler, each needs a guess and a fixup later.
- **It is where the two targets' difference belongs.** The assembler
  becomes nearly independent of the architecture: a parser, and a
  table of register names. The linker splits into what is general
  (loading, symbols, layout, data, ELF) and what is not (choosing and
  encoding: 5l's and 7l's optab and asmout), so the generality the two
  targets force lands in one module per architecture.

The costs don't matter here: an object can't be disassembled (there
is nothing to disassemble yet), and the linker is the biggest program
of the two. This rationale also goes, as the author asked, in the
header comments of `linker/Link.mli` and `assembler/Asm.mli`.

### 2. One instruction type and one parser for both architectures

xix has a typed syntax tree per architecture (`Ast_asm5`, `Ast_asm7`,
and one grammar each, `Parser_asm5.mly`, `Parser_asm7.mly`): the
assembler rejects `ADD R1<<2, R2` on arm64 as a type error. mini-asm
has **one instruction type**: an opcode (a string, with its suffixes
split off) and a list of operands, from one small set:

```
   operand = Reg r | FReg r | Imm n | Fimm x | Str s
           | Mem of { base : Reg r | SB | FP | SP | PC; sym; off }   o(R) sym+o(SB) o(PC)
           | Addr of mem                                             $sym(SB) $o(SP)
           | Shift of r * kind * amount | Index of r * r | Regs of r list
```

and one parser, since the syntax is the same; what differs per
architecture is a table: the register names (`R0`-`R15` and `PC`, or
`R0`-`R30`, `RSP`, `ZR`) and nothing else. The checking moves to the
encoder, which pattern-matches (opcode, operands) and says "illegal
combination" for the rest, as 5l does. mini-asm calls the same
classifier, without addresses, to report the error at assembly time
with its line: one check, in one place. This single decision is most
of the difference in size with xix (below).

### 3. Objects and libraries: marshalled, with a symbol index

An object is `Marshal` of the architecture, the file name and the
instruction list (TEXT, DATA and GLOBL included), with a version
number, as xix's `Object_file`. A library is a marshalled list of
objects and the symbols each defines, so the linker takes only the
objects a program needs (as `ar` and 5l do). `Marshal` is not stable
across OCaml versions: fine for a toolchain whose objects are rebuilt
with it.

### 4. The linker's passes

```
   load       objects and libraries; the objects a program needs, from its
              undefined symbols (and _div... on arm, for DIV and MOD)
   rewrite    per architecture: prologues and epilogues from TEXT's frame
              size (on arm, one pre-indexed store both saves R14 and makes
              the frame; a leaf with no locals has neither), RET, DIV and
              MOD into calls, CASE tables
   layout     an address for each instruction and each datum: code at
              0x80a0 (arm) or 0x4000f0 (arm64), as 5l and 7l; data after,
              page-aligned; literal pools after the functions that use them
   encode     per architecture: each instruction to its words
   write      the format (decision 7): ELF32 or ELF64, Mach-O, or a.out
```

Instructions are 4 bytes on both targets, so an instruction's size
depends on its operands, not on the addresses, except for what the
pools and the large constants make: layout is one pass, then pools.

### 5. Byte for byte against goken, with goken's help

The test oracle is goken's executable, and the text and data segments
are to be **identical**. goken does things mini-ld won't, which a flag
in goken will turn off for the comparison (phase 0, in goken):

- 5l's `follow()` reorders the code: it removes the jumps to jumps and
  the unreachable instructions 5c leaves (`B 3(PC); B 2(PC); B 17(PC)`
  in `strcpy`). mini-ld keeps the code in order; a goken flag keeps 5l's
  too. (Or mini-ld does it, if it is small: the Status will say.)
- 7l loads some small constants from a literal pool that fit an
  instruction (checked: `MOV $12, R0` became a pool load in the exit
  program); a flag, or the same choice, whichever is smaller.
- The Plan 9 symbol table and line tables (`-s` strips them in goken,
  and mini-ld writes none); 5l's section headers (mini-ld writes the same
  three if that costs less than 30 lines, else the headers are compared
  apart).

And one fix in goken, for the corpus: `5c -S` and `7c -S` print a few
operands that 5a and 7a don't read back (`BL 0(R6)` for `BL (R6)`;
arm64's stack pointer as `R31`). Checked: where they do read back
(`strchr`), the two listings are the same but for source lines. With
the fix, all of goken's C libraries become assembly mini-asm reads.

### 6. Large constants, bitmask immediates, and literal pools

arm makes an immediate from 8 bits rotated by an even amount; others
come from a literal pool, a word after the function loaded PC-relative
(and data is reached from R12, set to the data segment plus 4,092:
5l's `setR12` and `BIG`). arm64's logical instructions take a "bitmask
immediate", a repeated pattern of ones; 7l tabulates them in
`bits.c`, **5,382 lines**. mini-ld computes them: decomposing a
constant into element size, run of ones and rotation is some 30 lines,
the same answer as the table.

### 7. Three executable formats: ELF, Mach-O, Plan 9 a.out

The author: "we might want to also support Mach-O at least (Plan9
a.out and Windows PE are optional, add them if it does not add too
much code). With Mach-O I could also run binaries produced by tinyas
and mini-ld on my macbook pro". So, one module per format, all behind
the same interface (the laid-out segments in, a file out), as 5l's and
7l's `-H`:

| format | targets | goken | how it is tested | lines |
|---|---|---|---|---:|
| ELF (`-H7`) | arm, arm64 | 5l, 7l | run here; bytes against goken | 120 |
| Mach-O (`-H6`) | arm64 (macOS has no 32-bit arm) | 7l | bytes here, against 7l's unsigned output; run on the author's MacBook | 180 |
| Plan 9 a.out (`-H2`) | arm, arm64 | 5l, 7l | bytes against goken; the arm one runs here under goken's 5i (checked: `hello_plan9_arm.exe` prints `Hello, world`) | 30 |
| PE (Windows) | -- | none for arm or arm64 (only 386 and amd64: goken's `notes_exec_pe.txt`) | -- | out: no reference to test against |

**a.out** is a 32-byte big-endian header (magic `0x647` for arm, the
text, data, bss and symbol sizes, the entry) and the segments: cheap,
and the format principia's own kernel runs, for later.

**Mach-O on arm64 is more than a header**, and goken's notes
(`docs/claude_notes/notes_exec_macho.txt`, from bringing up 7l's
`-H6`) say what the kernel demands, each checked by them the hard way
(a silent SIGKILL at exec otherwise):

- **Signed.** An ad-hoc signature is enough, and `codesign -s -`
  adds it on the Mac (goken's `scripts/macos-codesign`); mini-ld leaves
  room for it (`__LINKEDIT` last, page-aligned, space after the load
  commands). Computing the signature in mini-ld needs SHA-256, which
  OCaml 4.14's standard library lacks: an exercise.
- **Dynamic in name.** The kernel runs no static executable: the file
  names `/usr/lib/dyld` and `libSystem.B.dylib`, and its entry is
  `LC_MAIN`. The program still calls nothing in libSystem: libc's
  darwin files make system calls directly (the number in R16, `SVC
  $0x80`), unsupported by Apple but working.
- **Position independent.** The kernel slides every program, so an
  address is never a constant: on Mach-O, `MOV $sym(SB), R` becomes
  `ADRP` and `ADD` (7l's `asmout` case 66) instead of a pool load, and
  the pointers in initialized data are listed for dyld to adjust (a
  "rebase" stream, `LC_DYLD_INFO_ONLY`). That is some 30 lines in
  `Arm64` and `Link`, besides the writer.
- **16 KB pages**, a 4 GB `__PAGEZERO`, `__TEXT` at 0x100000000.

Static in every other way: no shared libraries, no Plan 9 symbol
table or pc/line table, no DWARF; an entry symbol (`-E`, default
`_main`, libc's start-up, or `_start`).

### 8. Where the code goes, and the names

`assembler/` and `linker/`, xix's names (principia's are
`assemblers/` and `linkers/`). The commands are `mini-asm` and `mini-ld`,
the target a flag (`-m 5` or `-m 7`), as one executable each serves
both. The instruction type and the object format are in the assembler's
library, which the linker and later the compiler use.

## How to be smaller than xix

xix's 5 and 7 path (assembler, linker, their shared types and file
formats) is **11,036 lines, 5,542 of code** (counted without blanks
and comments, as TinyBuildSystem's 261). goken's C for the same:
5a 2,886, 7a 3,581, libas 2,235, 5l 8,210, 7l 13,685, lk 1,737: about
**32,000**. Where mini-asm and mini-ld save, against xix:

| xix | lines of code | mini-asm and mini-ld | why |
|---|---:|---|---|
| a grammar and a typed AST per architecture (`Parser_asm5.mly` 422, `Parser_asm7.mly` 331, `Ast_asm5` 166, `Ast_asm7` 154, `Parse_asm5/7`, `Check_asm5`) | ~1,400 | one parser, one instruction type | decision 2 |
| an ocamllex lexer (`Lexer_asm.mll`) | ~200 | a hand-written one, ~80 | the tokens are few |
| encoders over all of 5l's and 7l's forms (`Codegen5` 945, `Codegen7` 951) | ~1,900 | the subset, ~40 forms each | the counts above |
| `Elf.ml` (358) and `A_out.ml` | ~400 | ELF32 and ELF64 ~120, a.out ~30 (and Mach-O, which xix doesn't have, ~180) | decision 7 |
| `CLI.ml`s (160 + 339), `Flags`, `Profile`, `Optimize5` | ~650 | ~80 | no listing, profiling or optimizer |
| per-architecture `Types5/7`, `Layout5/7`, `Rewrite5/7` | ~700 | one file per architecture, with the encoder | decision 1 |

**The target**, set by module as for mini-rc and mini-ed:

| module | lines | what |
|---|---:|---|
| `assembler/Asm.ml(i)` | 90 | the instruction and operand types, the object format |
| `assembler/Lexer.ml`, `Parser.ml` | 250 | the tokens, and the one parser |
| `assembler/CLI.ml`, `Main.ml` | 40 | |
| `linker/Link.ml(i)` | 250 | load, libraries, symbols, layout, data, pools |
| `linker/Elf.ml` | 120 | ELF32 and ELF64 |
| `linker/Macho.ml` | 180 | Mach-O for arm64, with the rebase stream |
| `linker/Aout.ml` | 30 | Plan 9 a.out |
| `linker/Arm.ml` | 500 | arm: rewrite, classify, encode |
| `linker/Arm64.ml` | 580 | arm64: the same, the bitmask immediates, and position-independent addresses for Mach-O |
| `linker/CLI.ml`, `Main.ml` | 60 | |
| **total** | **about 2,090** | two fifths of xix's code (which has no Mach-O), 6% of the C |

mini-ed came out 26% over its line target (and on it in code lines);
the Status will compare.

## Outside the toolchain: the one-file variant

As `tiny/` has one file per program, the free variant here drops
separate compilation, which is what makes an assembler and a linker
two programs: **an assembler that writes the executable**, reading
one program's assembly (its own and libc's, concatenated), laying it
out and encoding it in one go -- no objects, no libraries, no symbols
between files. The question it answers: what is left of a toolchain
without separate compilation (tcc and Wirth's Oberon answer it their
ways; see the related work). One architecture or both is for then, by
lines; the test is the same: the same executables, running.

## The modules, with their references

- **Asm, Lexer, Parser**: Rob Pike, "A Manual for the Plan 9 assembler"
  (Plan 9 documentation, `principia/assemblers/docs`); goken's
  `assemblers/5a/a.y` and `lex.c`, `7a`; xix's `assembler/`.
- **Link**: goken's `linkers/5l/{obj,pass,layout,span}.c`,
  `linkers/lk/`; Ken Thompson, "Plan 9 C Compilers" (1990), for the
  split; John R. Levine, *Linkers and Loaders* (2000).
- **Arm**: 5l's `optab.c`, `span.c` (`oplook`), `codegen.c`
  (`asmout`), `noop.c`; the ARM Architecture Reference Manual (ARMv7-A,
  the A32 encodings).
- **Arm64**: 7l's `optab.c`, `asmout.c`, `span.c`, `noop.c`; the Arm
  Architecture Reference Manual for A-profile (A64).
- **Macho**: goken's `linkers/lk/macho.c` and
  `docs/claude_notes/notes_exec_macho.txt`; Apple's `mach-o/loader.h`.
- **Aout**: 5l's and 7l's `asm.c` (`H_PLAN9`); a.out(6) of Plan 9.
- **Elf**: goken's `linkers/lk/elf.c`; the System V ABI, and its ARM
  and AArch64 supplements.

## Tests (what the programs are for)

- **The corpus**, `linker/tests/corpus/`: small `.s` programs, one per
  instruction group and per quirk, each with its expected output when
  run and the code bytes goken's 5l or 7l made for it, recorded (so
  `make test` needs no goken); `differential.sh live` compares with
  goken directly.
- **The laws**: assembling is a function of the text (a `.s` printed
  from an object reads back to the same object); the code bytes of the
  subset are goken's; every program of the corpus runs to its output,
  on both targets.
- **A fuzzer**, as mini-ed's: random instructions of the subset,
  through goken's 5a/5l or 7a/7l and through mini-asm/mini-ld; the code
  bytes must be the same. The encoders' oracle.
- **Milestone 1: goken's `tests/s`**: `exit` and `hello_arch` for 5
  and 7, assembled and linked by ix, running, byte for byte.
- **Milestone 2: C programs with goken's libc, through ix.** libc's
  `.s` files and the `5c -S`/`7c -S` output of its C files and of a
  program (hello, a sort, a few of principia's utilities), assembled by
  mini-asm, linked by mini-ld: the same output as goken's executables,
  on both targets, natively.
- **Milestone 3: a Raspberry Pi.** The arm executables of milestone 2,
  on a Pi (by the author).
- **Milestone 4: a Mac.** The arm64 programs of milestone 2, linked
  for Mach-O with libc's darwin files: here, byte for byte against 7l's
  `-H6`; on the author's MacBook, signed with `codesign -s -`, running.
- **Plan 9 a.out**: the corpus's arm programs linked with `-H2`, run
  under 5i, which needs no Plan 9.

## Phasing

0. **Groundwork**: `assembler/` and `linker/`'s dune, the counting
   script, the corpus harness; in goken, the `-S` fixes and the
   comparison flags (decision 5).
1. **mini-asm**: the types, the lexer and the parser for both targets;
   the objects; the round-trip law over the corpus and goken's libc
   `.s`.
2. **mini-ld, general part**: load, libraries, symbols, layout, data,
   ELF32 and ELF64, and a.out.
3. **arm**: rewrite, classify, encode; milestone 1 for 5; the fuzzer.
4. **arm64**: the same, and a look back at what the second target
   showed in the first's design; milestone 1 for 7.
5. **Milestone 2**, on both; then **Mach-O** for arm64 and
   milestone 4.
6. **The one-file variant**, in `tiny/`.
7. **Docs**: `notes_asm.md` checked against the code, the numbers.

## Status

- **2026-09-23, the plan written, for review** (the author: "I'll
  review, especially the subset of ARM (and ARM64) to handle, and how
  to reach low number of LOC, how to be even smaller than xix"). What
  was decided with the author before it, and checked:
  - the targets 5 and 7; Plan 9's split, with the linker encoding;
    ix's own marshalled objects; the executable as the contract; goken
    as the reference, changeable behind flags;
  - goken rebuilt from `mk nuke`; its arm `libc.a` had been left as
    the Plan 9 one by goken's own `mk test` (system call number in R0,
    arguments on the stack), which hung or trapped on Linux; rebuilt
    with `mk -a objtype=arm` for Linux, an integer C program runs on
    arm natively, and C with floats on arm64; on arm, floats trap
    (FPA);
  - the subset counts above; `5c -S` output reads back into 5a where
    it parses (`strchr`: the same listing but for source lines), and
    doesn't for `BL 0(R6)` and arm64's `R31`;
  - 5l inserts a prologue and an epilogue itself (`TEXT _start(SB),
    $20` gets `MOVW.W R14,-24(R13)` and `MOVW.P 24(R13),R15`); 7l turns
    `MOV $12, R0` into a pool load; the exit programs are 326 bytes
    (ELF32) and 486 (ELF64).

- **2026-09-23, the formats widened, before any code** (the author:
  "we might want to also support Mach-O at least (Plan9 a.out and
  Windows PE are optional, add them if it does not add too much code).
  With Mach-O I could also run binaries produced by tinyas and mini-ld
  on my macbook pro"). Decision 7 is now three formats. Checked for
  it: 7l writes Mach-O for arm64 (`-H6`) and 5l and 7l a.out (`-H2`);
  goken's `hello_plan9_arm.exe` runs under 5i here; goken has no PE
  for arm or arm64, so PE stays out. goken's Mach-O notes list what
  the arm64 kernel requires (a signature, dyld named, position
  independence, 16 KB pages); the line target grows by 240, to about
  2,090.

- **2026-09-23, mini-asm, and mini-ld for arm: milestones 1 and 2 on
  arm, byte for byte.** `assembler/` (Asm, Lexer, Parser, CLI) and
  `linker/` (Link, Arm, Exe for ELF and a.out, CLI).
  - Milestone 1: `linker/tests/fixtures5.sh` over xix's `arm_diff`
    and goken's `tests/s` arm files: 41 executables the same as 5l's
    `-H7 -s`, and `hello_plan9_arm` the same as `-H2`. Out: 3 fixtures
    in xix-only syntax (goken's 5a rejects them), and 4 outside the
    subset (PSR and FPSR moves, SWP, coprocessor registers).
  - Milestone 2: `linker/tests/libc5.sh` builds goken's libc twice,
    with 5c and 5a into goken's objects, and with `5c -S`, mini-asm and
    `mini-ld -a` into ix's (149 files, all through). It then links the
    17 programs of goken's `tests/c/hello_libc` both ways. All 17 are
    the same, byte for byte (`linker/tests/elfcmp.py`), except for
    the one goken bug below, and they print the same.
  - **Two decisions changed, forced by the libc.** First, **5l's
    `follow`** (the plan left it out): without it no program with a
    loop matches. Second, **FPA encoding** (the plan had no arm
    floating point): libc's `fmt` has `fltfmt` and `strtod`, so any
    `print` links float code, even code that never runs. Both are in
    Arm.ml: `follow` ~75 lines, FPA ~55.
  - **Byte identity also needed** these details:
    - ar's index lists the members last first, and drops a text name
      that an earlier member defines (fmt's `strtod` over port's);
    - the entry is the first undefined name;
    - `_div` and the rest are asked for only after all the loading;
    - `n+4(FP)` names no symbol;
    - a literal pool shares one constant across objects;
    - `\z` in strings is NUL;
    - `5c -S` prints static locals as `x$7<>`, and its warnings on
      stdout.
  - **goken's bugs, found on the way** (not fixed in goken, for the
    author to decide):
    - 5l's ELF section table goes at HEADR+text+data, which is inside
      the data's page, so it overwrites the end of a large data
      segment. 9 of the 17 programs have it, and goken's `dirread`
      fails because of it (patched with ix's bytes, it passes). mini-ld
      puts the table after the data, and `elfcmp.py` skips it.
    - 5l's `immrot` runs in a 64-bit `ulong`, so only 0..255 are
      immediates; `$0x400` goes to a literal pool. The code is correct
      but longer. mini-ld does the same, with a `rotate` flag for the
      real rule.
  - Code lines (no blanks or comments): assembler 516, linker 1,075
    (Link 275, Arm 680, Exe 71, CLI 49), so 1,591 against the
    target's 1,030 for this part (assembler 380, Link 250, Elf and
    a.out 150, Arm 500, CLI 60). Arm is 180 over, `follow` and FPA.
  - Next: arm64 (Arm64.ml, milestone 1 for 7), then milestone 2 on
    arm64 and Mach-O.

- **2026-09-23, mini-ld for arm64: milestones 1 and 2 on arm64, byte
  for byte** (the author: "let's do it"). `linker/Arm64.ml`, from 7l's
  optab, span, noops and asmout.
  - Milestone 1: `fixtures.sh 7` gives 20 the same as 7l `-H7 -s`:
    goken's exit and hello, and 18 of xix's 22 `arm64_diff`. Out of
    the subset: atomics, barriers, CSEL and TBZ.
  - Milestone 2: `libc.sh 7` builds goken's libc through `7c -S`, and
    all 17 hello_libc programs match. goken's section table bug
    appears on arm64 too (10 of 17), and `dirread` fails from it here
    as well. `mem` crashes in goken's own build, with bytes the same as
    ix's, so that bug is goken's (on arm the program passes).
  - 7l is not 5l: it has its own hash (int32, complemented), its own
    data alignment (8 and 16), and one literal pool at the end of the
    program, with 8-byte words for MOV. There are no FMOV immediates:
    every float constant goes in the data. The frame is 16-aligned
    with R30 at its bottom. mini-ld reproduces 7l's bitmask encoding
    (the element size is left out below 64 bits), and it generates
    the table of 5,334 immediates rather than copying bits.c.
  - The design held: `follow` and the float constants moved into Link,
    shared by the two machines, as did the data layout and the hash,
    with a case per machine. Arm64.ml has no view of 5l's conditions
    and 5l has no view of 7l's widths. Each machine is one module of
    about 590 code lines.
  - Code lines: Arm64 593 (the target was 580, which included Mach-O's
    position independence), Link 332, Arm 582 (smaller, since `follow`
    moved out).

- **2026-09-23, Mach-O and arm64's a.out: milestone 4 here, byte for
  byte.** For `-H6` (Exe.macho):
  - 3 KB of header and load commands, the segments __PAGEZERO, __TEXT,
    __DATA and __LINKEDIT, dyld and libSystem named, LC_MAIN, and the
    rebase stream of the data's pointers (`Link.pointers`);
  - in the code, PIE addresses by ADRP and ADD (7l's case 66, the one
    rule added to Arm64).

  Results:
  - all 17 in-subset arm64 fixtures and goken's `hello_macos_arm64`
    are the same as 7l `-H6`;
  - `GOOS=darwin H=-H6 libc.sh 7` builds macOS's libc, and 15
    hello_libc programs are the same (goken's 7l itself fails on alarm
    and notify, with redefinitions in the darwin libc);
  - arm64's a.out (`-H2`, 40-byte header) is the same on the fixtures
    tried.

  Left for the author: signing with `codesign -s -` and running on the
  MacBook (milestone 4's second half). Code lines: Exe 129 (ELF, a.out
  and Mach-O; the target was 330), Arm64 599.

- **2026-09-23, the one-file variant, the fuzzer, and the
  finalization** (the author: "yes let's make the tiny/ one and
  finalize the assember and linker part").
  - `tiny/TinyAssembler.ml`, 410 lines of code (the arm64 path through
    mini-asm and mini-ld is about 1,580). It is arm64 only: it runs here
    and on the Mac, and it has no FPA and no division calls. It takes
    all of a program's assembly and writes a one-segment ELF. It drops
    the byte identity with 7l, so every size is known before any
    address:
    - constants by MOVZ, MOVK and MOVN;
    - addresses by ADRP and ADD;
    - logical immediates through a register;
    - no pool, no bitmask encoder.

    Each instruction becomes closures from pc to word. A library
    becomes the functions reachable from the entry, with the first
    definition of a name winning. 7l's frames are kept, since 7c's code
    counts on them.
  - Its test, `TinyAssembler_test.sh`: goken's exit and hello, then
    libc (all of it, through `7c -S`) with the 17 hello_libc programs,
    against goken's `*_expected.txt`. All 19 pass, including `dirread`
    and `mem`, which goken's own executables fail.
  - The fuzzer, `linker/tests/fuzz.py`: random programs of the subset,
    through goken and ix. It found two bugs the corpus hadn't:
    - `Link.rnd` of a negative frame (`$-4`, 5l's leaf marker, rounded
      to 0 in a function that calls);
    - which pool words are shared. 5l compares whole operand records:
      a word built from an offset is never shared with an operand's,
      and a constant is 32 bits sign-extended once read, so a `SUB` of
      `$0x80000000` becomes an `ADD` of +2³¹, not `$-2³¹`.

    After the fixes, the last runs are clean on both machines (the
    counts are in the commit).
  - `make test` now has `golden.sh` (62 recorded executables);
    `make test-goken` has the rest. The tutorial is checked against
    the code: modules, passes (`follow`), the loading order, FPA,
    immrot, 7l's pool and bitmasks, the section-table bug, the tests,
    the exercises, and the variant.
  - **Capabilities** (the author: "please use capabilities in new code,
    so the Assembler and linker should take Cap.open_in and
    Cap.open_out if they want to read or write files"). Every function
    that reads or writes a file now takes `< Cap.open_in; .. >` or
    `< Cap.open_out; .. >`, in builder/'s way:
    - `Asm.read_file`, `write_file`, `save` and `load`, and
      `Lexer.preprocess` for `#include`;
    - `Link.load` and `make_library`, and `Exe.write`;
    - TinyAssembler's parse and link.

    The mains start from `Cap.main`, and the CLIs print through
    `Cap.stdout` and `Cap.stderr`. The bytes are unchanged (golden,
    libc, TinyAssembler's test).
  - Final code lines, interfaces included: assembler 516; linker
    1,785 (in the .ml files: Link 342, Arm 583, Arm64 598, Exe 129,
    CLI 59). That is 2,301 in all, against the plan's 2,090, 10% over.
    The excess is arm's `follow` and FPA, which the target left out,
    less what Exe saved. For xix's 5 and 7 path the figure is 5,542, and
    goken's C is about 32,000. The variant is 410.

## Verification

`make test` runs `linker/tests/golden.sh`: 62 fixtures, each assembled
and linked by ix, against the digest of goken's executable (`golden.sh
record` re-records them, with goken). `make test-goken`, with goken
built, runs `libc.sh 5` and `libc.sh 7` (goken's libc and its 17
hello_libc programs, byte for byte and run) and TinyAssembler's test.
`linker/tests/fuzz.py 5|7 N seed` is the fuzzer, and `fixtures.sh` and
`elfcmp.py` are the tools for a single file.

## Out of scope

Dynamic linking and shared libraries (Mach-O's dyld and libSystem are
named, not used); debugging information (Plan 9's symbol table,
DWARF); PE, for which goken has no arm or arm64 reference; Mach-O for
anything but arm64, and universal binaries; signing Mach-O in mini-ld
(`codesign` does it); the other architectures of goken (386, amd64, mips,
riscv...); running arm floating point (FPA is encoded, as libc has it,
but no machine runs it; VFP until a later phase);
kernel code (system instructions, the assemblers' preprocessor).

## Related work

[`notes_asm_related_work.md`](../related-work/notes_asm_related_work.md).

## Appendix: the full counts

Every opcode, and every (opcode, operand shapes) pair that makes the
first 97% of the instructions, from `assembler/tests/count_opcodes.py`
over goken's libraries (2026-09-23). Shapes: `R` a register, `F` a
floating-point one, `$c` a constant, `o(R)` an offset from a register,
`sym(SB)` a global, `o(FP)` an argument, `o(SP)` a local, `o(PC)` a
branch target, `$...` an address or a constant as a value.

### arm: arm: 170/173 files compiled, 18755 instructions

Opcodes (with arm's condition suffixes), count, cumulative %:

```
   MOVW 8155 43.48%               B 1863 53.42%                  CMP 1599 61.94%
   ADD 965 67.09%                 RET 899 71.88%                 BL 889 76.62%
   BEQ 572 79.67%                 MOVD 386 81.73%                MOVB 375 83.73%
   BNE 351 85.60%                 MOVW.NE 188 86.60%             MOVW.EQ 185 87.59%
   SUB 148 88.38%                 MOVM.U 129 89.06%              BLT 114 89.67%
   AND.S 109 90.25%               BGE 97 90.77%                  BLE 92 91.26%
   BCASE 81 91.69%                BGT 75 92.09%                  RET.EQ 72 92.48%
   AND 69 92.84%                  MOVBU 68 93.21%                BLS 68 93.57%
   MULD 67 93.93%                 BHS 65 94.27%                  CMPD 60 94.59%
   ORR 58 94.90%                  MOVW.S 57 95.21%               ADDD 51 95.48%
   BHI 43 95.71%                  SLL 39 95.92%                  RSB 38 96.12%
   SRA 38 96.32%                  MOVW.LT 37 96.52%              SRL 36 96.71%
   SUBD 29 96.86%                 BLO 27 97.01%                  BPL 23 97.13%
   ADD.EQ 23 97.25%               RET.LT 20 97.36%               ADD.NE 19 97.46%
   MOVB.P 18 97.56%               RET.NE 18 97.65%               MOVWD 18 97.75%
   EOR 18 97.85%                  DIVD 17 97.94%                 CASE.LS 17 98.03%
   MOD 15 98.11%                  MOVD.NE 14 98.18%              MOVH 14 98.26%
   RET.GE 13 98.33%               MUL 13 98.40%                  DIV 12 98.46%
   MOVW.CC 11 98.52%              MOVW.GT 10 98.57%              MOVW.GE 9 98.62%
   RSB.NE 8 98.66%                CMN 8 98.70%                   RET.MI 8 98.75%
   MOVDW 8 98.79%                 MOVW.MI 8 98.83%               MOVW.HI 8 98.87%
   ADD.LT 8 98.92%                MOVB.NE 7 98.95%               MOVW.LE 7 98.99%
   RSB.LT 7 99.03%                BL.NE 6 99.06%                 ADD.MI 6 99.09%
   SUB.EQ 6 99.13%                ADDD.NE 6 99.16%               SUBD.NE 5 99.18%
   MODU 5 99.21%                  DIVU 5 99.24%                  RET.LE 5 99.26%
   MULU 5 99.29%                  ADD.CC 5 99.32%                BL.EQ 4 99.34%
   MOVB.EQ 4 99.36%               RSB.MI 4 99.38%                MOVD.EQ 4 99.40%
   MOVD.MI 4 99.42%               ADD.GT 4 99.45%                MVN 4 99.47%
   SUB.S 4 99.49%                 MOVW.P 4 99.51%                MOVM.W.U 4 99.53%
   RET.LS 3 99.55%                MOVBU.EQ 3 99.56%              MOVBU.P 3 99.58%
   SUB.NE 3 99.59%                SUBD.MI 3 99.61%               RET.HI 3 99.63%
   DIVD.NE 3 99.64%               MOVHU 3 99.66%                 ORR.NE 3 99.67%
   ADD.LE 3 99.69%                MOVD.GE 2 99.70%               AND.MI 2 99.71%
   AND.PL 2 99.72%                SUB.GT 2 99.73%                RSB.S 2 99.74%
   RET.CS 2 99.75%                ADD.HI 2 99.77%                RSB.EQ 2 99.78%
   AND.LT 2 99.79%                AND.GE 2 99.80%                MOVD.LT 2 99.81%
   ORR.EQ 2 99.82%                RET.GT 2 99.83%                MOVB.W 2 99.84%
   MOVW.LS 2 99.85%               MOVW.CS 2 99.86%               SUB.CS 2 99.87%
   MOVD.LS 1 99.88%               ADDD.LS 1 99.88%               MOVW.PL 1 99.89%
   MULD.NE 1 99.89%               RET.CC 1 99.90%                MOVD.GT 1 99.90%
   SUBD.GT 1 99.91%               SRL.LT 1 99.91%                MVN.NE 1 99.92%
   MOVF 1 99.93%                  MOVFD 1 99.93%                 MOVDF 1 99.94%
   SRA.GE 1 99.94%                MULD.EQ 1 99.95%               AND.EQ 1 99.95%
   MOVH.NE 1 99.96%               MOVB.LE 1 99.96%               MOVW.NE.P 1 99.97%
   MOVB.EQ.P 1 99.97%             RSB.CC 1 99.98%                MOVB.LS 1 99.98%
   ADD.S 1 99.99%                 MOVW.W 1 99.99%                MOVBU.NE 1 100.00%
```

The (opcode, operand shapes) pairs up to 97% (69 of them):

```
   B        o(PC)                               1863  9.9%
   MOVW     R,o(R)                              1664  18.8%
   CMP      $c,R                                1257  25.5%
   MOVW     o(SP),R                             1245  32.1%
   MOVW     o(FP),R                             1183  38.5%
   MOVW     $c,R                                1125  44.5%
   RET                                          1046  50.0%
   MOVW     o(R),R                               878  54.7%
   BL       sym(SB)                              862  59.3%
   MOVW     R,o(SP)                              812  63.6%
   MOVW     R,R                                  666  67.2%
   BEQ      o(PC)                                572  70.2%
   ADD      $c,R,R                               535  73.1%
   BNE      o(PC)                                351  75.0%
   CMP      R,R                                  342  76.8%
   MOVW     $o(SP),R                             320  78.5%
   MOVW     $sym(SB),R                           255  79.9%
   MOVW     R,o(FP)                              241  81.1%
   MOVB     o(R),R                               239  82.4%
   ADD      $c,R                                 203  83.5%
   ADD      R,R,R                                122  84.1%
   AND      $c,R                                 122  84.8%
   BLT      o(PC)                                114  85.4%
   MOVM     o(R),[R,R]                           112  86.0%
   MOVB     R,o(R)                               107  86.6%
   BGE      o(PC)                                 97  87.1%
   MOVD     $c.00000000000000000e+00,F            94  87.6%
   BLE      o(PC)                                 92  88.1%
   ADD      R,R                                   90  88.6%
   BCASE    o(PC)                                 81  89.0%
   BGT      o(PC)                                 75  89.4%
   MOVW     sym(SB),R                             73  89.8%
   SUB      R,R                                   69  90.1%
   BLS      o(PC)                                 68  90.5%
   MOVD     F,o(R)                                67  90.9%
   SUB      R,R,R                                 66  91.2%
   BHS      o(PC)                                 65  91.6%
   CMPD     F,F                                   60  91.9%
   AND      $c,R,R                                60  92.2%
   MOVD     o(FP),F                               56  92.5%
   MOVW     R,sym(SB)                             53  92.8%
   MOVBU    o(R),R                                46  93.0%
   RSB      $c,R,R                                44  93.3%
   BHI      o(PC)                                 43  93.5%
   MOVW     $o(FP),R                              42  93.7%
   ADDD     F,F                                   38  93.9%
   ADD      R<<2,R,R                              38  94.1%
   BL       o(R)                                  37  94.3%
   MULD     F,F,F                                 35  94.5%
   MOVW     R<<o(R),R                             35  94.7%
   MULD     F,F                                   34  94.9%
   SUBD     F,F,F                                 29  95.0%
   ORR      $c,R                                  29  95.2%
   MOVD     F,F                                   27  95.3%
   BLO      o(PC)                                 27  95.5%
   SLL      $c,R,R                                26  95.6%
   MOVD     o(SP),F                               26  95.8%
   BPL      o(PC)                                 23  95.9%
   MOVW     R,R<<o(R)                             23  96.0%
   MOVD     F,o(SP)                               22  96.1%
   ADD      R<<3,R,R                              21  96.2%
   ADDD     F,F,F                                 20  96.3%
   SRA      $c,R,R                                19  96.4%
   MOVWD    R,F                                   18  96.5%
   SRL      $c,R                                  18  96.6%
   RSB      $c,R                                  17  96.7%
   CASE     R                                     17  96.8%
   MOVM     [R,R],o(R)                            17  96.9%
   DIVD     F,F,F                                 15  97.0%
```

### arm64: arm64: 170/173 files compiled, 19223 instructions

Opcodes (with arm's condition suffixes), count, cumulative %:

```
   MOV 3870 20.13%                MOVW 3100 36.26%               B 2115 47.26%
   CMPW 1421 54.65%               MOVWU 1152 60.65%              RETURN 1048 66.10%
   BL 837 70.45%                  ADD 736 74.28%                 BEQ 700 77.92%
   ADDW 427 80.14%                BNE 419 82.32%                 MOVB 410 84.46%
   FMOVD 404 86.56%               CMP 347 88.36%                 SXTW 209 89.45%
   ANDW 179 90.38%                BGE 151 91.17%                 BLT 131 91.85%
   LSL 112 92.43%                 SUBW 110 93.00%                BLE 95 93.50%
   BGT 91 93.97%                  LSLW 85 94.41%                 BCASE 81 94.83%
   MOVBU 76 95.23%                BLS 76 95.63%                  BHS 76 96.02%
   FMULD 69 96.38%                SUB 67 96.73%                  ORRW 62 97.05%
   FCMPD 60 97.36%                FADDD 52 97.63%                NEGW 51 97.90%
   BHI 47 98.14%                  ASRW 47 98.39%                 LSRW 41 98.60%
   FSUBD 38 98.80%                BLO 26 98.93%                  BPL 23 99.05%
   FDIVD 20 99.16%                CASE 17 99.25%                 REMW 15 99.32%
   MOVH 15 99.40%                 MULW 13 99.47%                 SDIVW 12 99.53%
   SCVTFWD 12 99.59%              EORW 12 99.66%                 CMNW 8 99.70%
   FCVTZSDW 6 99.73%              UCVTFWD 6 99.76%               UREMW 5 99.79%
   UDIVW 5 99.81%                 MVNW 5 99.84%                  UMULL 5 99.86%
   AND 4 99.89%                   NEG 4 99.91%                   MOVHU 3 99.92%
   SDIV 2 99.93%                  MUL 2 99.94%                   FCVTZUDW 2 99.95%
   BMI 1 99.96%                   SCVTFD 1 99.96%                ORR 1 99.97%
   FMOVS 1 99.97%                 FCVTSD 1 99.98%                FCVTDS 1 99.98%
   UREM 1 99.99%                  UDIV 1 99.99%                  MVN 1 100.00%
```

The (opcode, operand shapes) pairs up to 97% (91 of them):

```
   B        o(PC)                               2115  11.0%
   CMPW     $c,R                                1220  17.3%
   RETURN                                       1048  22.8%
   BL       sym(SB)                              800  27.0%
   MOVW     $c,R                                 752  30.9%
   BEQ      o(PC)                                700  34.5%
   MOVW     R,o(R)                               635  37.8%
   MOV      o(FP),R                              629  41.1%
   MOV      R,R                                  613  44.3%
   MOV      R,o(R)                               609  47.4%
   MOV      o(R),R                               465  49.9%
   MOVWU    R,R                                  456  52.2%
   MOVW     o(SP),R                              441  54.5%
   ADD      $c,R,R                               427  56.8%
   BNE      o(PC)                                419  58.9%
   MOV      o(SP),R                              328  60.6%
   MOVW     o(R),R                               305  62.2%
   MOVW     R,o(SP)                              298  63.8%
   MOV      R,o(SP)                              261  65.1%
   MOVB     o(R),R                               251  66.4%
   MOV      $sym(SB),R                           242  67.7%
   MOV      $o(SP),R                             222  68.9%
   MOVWU    o(R),R                               216  70.0%
   SXTW     R,R                                  209  71.1%
   MOVW     o(FP),R                              209  72.2%
   CMPW     R,R                                  201  73.2%
   MOVW     R,R                                  196  74.2%
   CMP      $c,R                                 195  75.2%
   ADDW     $c,R,R                               189  76.2%
   ADD      R,R                                  179  77.1%
   MOV      R,o(FP)                              166  78.0%
   MOVWU    o(FP),R                              161  78.8%
   CMP      R,R                                  152  79.6%
   BGE      o(PC)                                151  80.4%
   MOVWU    o(SP),R                              145  81.2%
   BLT      o(PC)                                131  81.9%
   MOV      $c,R                                 129  82.5%
   ANDW     $c,R                                 115  83.1%
   ADDW     R,R,R                                103  83.7%
   ADDW     $c,R                                 102  84.2%
   LSL      $c,R                                 101  84.7%
   BLE      o(PC)                                 95  85.2%
   MOVW     $c,o(R)                               95  85.7%
   FMOVD    $c.00000000000000000e+00,F            94  86.2%
   BGT      o(PC)                                 91  86.7%
   MOVB     R,o(R)                                91  87.1%
   BCASE    o(PC)                                 81  87.6%
   ADD      R,R,R                                 78  88.0%
   BLS      o(PC)                                 76  88.4%
   BHS      o(PC)                                 76  88.8%
   MOVWU    R,o(R)                                73  89.1%
   FMOVD    F,o(R)                                67  89.5%
   SUBW     R,R,R                                 63  89.8%
   FCMPD    F,F                                   60  90.1%
   ANDW     $c,R,R                                59  90.4%
   MOV      $c,o(R)                               58  90.7%
   FMOVD    o(FP),F                               56  91.0%
   LSLW     $c,R,R                                56  91.3%
   ADD      $c,R                                  52  91.6%
   NEGW     R,R                                   51  91.9%
   MOV      sym(SB),R                             51  92.1%
   MOVBU    o(R),R                                50  92.4%
   MOVW     $c,o(SP)                              49  92.6%
   BHI      o(PC)                                 47  92.9%
   MOVWU    R,o(SP)                               44  93.1%
   MOVW     R,o(FP)                               43  93.3%
   MOVWU    $c,R                                  42  93.6%
   SUB      R,R,R                                 40  93.8%
   MOV      $o(FP),R                              38  94.0%
   FMULD    F,F,F                                 37  94.2%
   BL       o(R)                                  37  94.3%
   ADDW     R,R                                   33  94.5%
   FMULD    F,F                                   32  94.7%
   FADDD    F,F                                   30  94.8%
   FSUBD    F,F,F                                 29  95.0%
   MOVB     $c,o(R)                               28  95.1%
   LSRW     $c,R                                  28  95.3%
   ORRW     $c,R                                  28  95.4%
   MOV      R,sym(SB)                             27  95.6%
   MOVW     sym(SB),R                             27  95.7%
   BLO      o(PC)                                 26  95.8%
   FMOVD    o(SP),F                               26  96.0%
   SUB      R,R                                   26  96.1%
   BPL      o(PC)                                 23  96.2%
   FMOVD    F,F                                   23  96.4%
   FADDD    F,F,F                                 22  96.5%
   FMOVD    F,o(SP)                               22  96.6%
   SUBW     R,R                                   21  96.7%
   ASRW     $c,R                                  21  96.8%
   ASRW     $c,R,R                                18  96.9%
   CASE     R,R                                   17  97.0%
```
