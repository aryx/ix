# Plan: TinyAsm and TinyLd, an assembler and a linker from scratch, for arm and arm64 (`assembler/`, `linker/`)

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
  and a Raspberry Pi has no FPA either (it has VFP). So TinyLd has no
  floating point on arm, until the compiler or goken emits VFP (an
  exercise, later a phase); arm64's floating point is kept.

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

Counted with a script (in the scratchpad; kept in `assembler/tests/`
in phase 0) that compiles goken's C libraries -- libc's `port`, `fmt`,
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
| floating point, FPA: `MOVD` `ADDD` `SUBD` `MULD` `DIVD` `CMPD` `MOVWD` `MOVDW` `MOVF` `MOVFD` `MOVDF` | 688 | **no** (can't run) |

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
assembler rejects `ADD R1<<2, R2` on arm64 as a type error. TinyAsm
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
combination" for the rest, as 5l does. TinyAsm calls the same
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
   write      ELF32 or ELF64: a header, three program headers, the bytes
```

Instructions are 4 bytes on both targets, so an instruction's size
depends on its operands, not on the addresses, except for what the
pools and the large constants make: layout is one pass, then pools.

### 5. Byte for byte against goken, with goken's help

The test oracle is goken's executable, and the text and data segments
are to be **identical**. goken does things TinyLd won't, which a flag
in goken will turn off for the comparison (phase 0, in goken):

- 5l's `follow()` reorders the code: it removes the jumps to jumps and
  the unreachable instructions 5c leaves (`B 3(PC); B 2(PC); B 17(PC)`
  in `strcpy`). TinyLd keeps the code in order; a goken flag keeps 5l's
  too. (Or TinyLd does it, if it is small: the Status will say.)
- 7l loads some small constants from a literal pool that fit an
  instruction (checked: `MOV $12, R0` became a pool load in the exit
  program); a flag, or the same choice, whichever is smaller.
- The Plan 9 symbol table and line tables (`-s` strips them in goken,
  and TinyLd writes none); 5l's section headers (TinyLd writes the same
  three if that costs less than 30 lines, else the headers are compared
  apart).

And one fix in goken, for the corpus: `5c -S` and `7c -S` print a few
operands that 5a and 7a don't read back (`BL 0(R6)` for `BL (R6)`;
arm64's stack pointer as `R31`). Checked: where they do read back
(`strchr`), the two listings are the same but for source lines. With
the fix, all of goken's C libraries become assembly TinyAsm reads.

### 6. Large constants, bitmask immediates, and literal pools

arm makes an immediate from 8 bits rotated by an even amount; others
come from a literal pool, a word after the function loaded PC-relative
(and data is reached from R12, set to the data segment plus 4,092:
5l's `setR12` and `BIG`). arm64's logical instructions take a "bitmask
immediate", a repeated pattern of ones; 7l tabulates them in
`bits.c`, **5,382 lines**. TinyLd computes them: decomposing a
constant into element size, run of ones and rotation is some 30 lines,
the same answer as the table.

### 7. ELF only, static, no debugging information

`-H7` only: no Plan 9 a.out, no Mach-O, no PE, no dynamic linking;
no Plan 9 symbol table, no pc/line table, no DWARF; an entry symbol
(`-E`, default `_main`, libc's start-up, or `_start`).

### 8. Where the code goes, and the names

`assembler/` and `linker/`, xix's names (principia's are
`assemblers/` and `linkers/`). The commands are `tinyasm` and `tinyld`,
the target a flag (`-m 5` or `-m 7`), as one executable each serves
both. The instruction type and the object format are in the assembler's
library, which the linker and later the compiler use.

## How to be smaller than xix

xix's 5 and 7 path (assembler, linker, their shared types and file
formats) is **11,036 lines, 5,542 of code** (counted without blanks
and comments, as TinyBuildSystem's 261). goken's C for the same:
5a 2,886, 7a 3,581, libas 2,235, 5l 8,210, 7l 13,685, lk 1,737: about
**32,000**. Where TinyAsm and TinyLd save, against xix:

| xix | lines of code | TinyAsm and TinyLd | why |
|---|---:|---|---|
| a grammar and a typed AST per architecture (`Parser_asm5.mly` 422, `Parser_asm7.mly` 331, `Ast_asm5` 166, `Ast_asm7` 154, `Parse_asm5/7`, `Check_asm5`) | ~1,400 | one parser, one instruction type | decision 2 |
| an ocamllex lexer (`Lexer_asm.mll`) | ~200 | a hand-written one, ~80 | the tokens are few |
| encoders over all of 5l's and 7l's forms (`Codegen5` 945, `Codegen7` 951) | ~1,900 | the subset, ~40 forms each | the counts above |
| `Elf.ml` (358) and `A_out.ml` | ~400 | ELF32 and ELF64 only, ~120 | decision 7 |
| `CLI.ml`s (160 + 339), `Flags`, `Profile`, `Optimize5` | ~650 | ~80 | no listing, profiling or optimizer |
| per-architecture `Types5/7`, `Layout5/7`, `Rewrite5/7` | ~700 | one file per architecture, with the encoder | decision 1 |

**The target**, set by module as for TinyRc and TinyEd:

| module | lines | what |
|---|---:|---|
| `assembler/Asm.ml(i)` | 90 | the instruction and operand types, the object format |
| `assembler/Lexer.ml`, `Parser.ml` | 250 | the tokens, and the one parser |
| `assembler/CLI.ml`, `Main.ml` | 40 | |
| `linker/Link.ml(i)` | 250 | load, libraries, symbols, layout, data, pools |
| `linker/Elf.ml` | 120 | ELF32 and ELF64 |
| `linker/Arm.ml` | 500 | arm: rewrite, classify, encode |
| `linker/Arm64.ml` | 550 | arm64: the same, and the bitmask immediates |
| `linker/CLI.ml`, `Main.ml` | 60 | |
| **total** | **about 1,850** | a third of xix's code, 6% of the C |

TinyEd came out 26% over its line target (and on it in code lines);
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
- **A fuzzer**, as TinyEd's: random instructions of the subset,
  through goken's 5a/5l or 7a/7l and through TinyAsm/TinyLd; the code
  bytes must be the same. The encoders' oracle.
- **Milestone 1: goken's `tests/s`**: `exit` and `hello_arch` for 5
  and 7, assembled and linked by ix, running, byte for byte.
- **Milestone 2: C programs with goken's libc, through ix.** libc's
  `.s` files and the `5c -S`/`7c -S` output of its C files and of a
  program (hello, a sort, a few of principia's utilities), assembled by
  TinyAsm, linked by TinyLd: the same output as goken's executables,
  on both targets, natively.
- **Milestone 3: a Raspberry Pi.** The arm executables of milestone 2,
  on a Pi (by the author).

## Phasing

0. **Groundwork**: `assembler/` and `linker/`'s dune, the counting
   script, the corpus harness; in goken, the `-S` fixes and the
   comparison flags (decision 5).
1. **TinyAsm**: the types, the lexer and the parser for both targets;
   the objects; the round-trip law over the corpus and goken's libc
   `.s`.
2. **TinyLd, general part**: load, libraries, symbols, layout, data,
   ELF32 and ELF64.
3. **arm**: rewrite, classify, encode; milestone 1 for 5; the fuzzer.
4. **arm64**: the same, and a look back at what the second target
   showed in the first's design; milestone 1 for 7.
5. **Milestone 2**, on both.
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

## Verification

`make test` runs the corpus against its recorded outputs and bytes,
and the laws; `linker/tests/differential.sh live` and the fuzzer run
against goken, which must be built.

## Out of scope

Dynamic linking and shared libraries; debugging information (Plan 9's
symbol table, DWARF); the other executable formats (Plan 9 a.out,
Mach-O, PE); the other architectures of goken (386, amd64, mips,
riscv...); arm floating point (FPA, and VFP until a later phase);
kernel code (system instructions, the assemblers' preprocessor).

## Related work

[`notes_asm_related_work.md`](../related-work/notes_asm_related_work.md).
