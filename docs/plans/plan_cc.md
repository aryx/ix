# Plan: mini-cc, a C compiler from scratch, for arm and arm64 (`languages/c/`)

Companions:
[`notes_cc.md`](../tutorials/notes_cc.md), the tutorial: from a `.c`
to an object, Plan 9's C, the front end, the tree and its rewriting,
generating code from trees, statements and switches, calls and frames,
the two machines, and the objects. And
[`notes_cc_related_work.md`](../related-work/notes_cc_related_work.md):
from Ritchie's and Johnson's compilers to Plan 9's, lcc, the small
compilers (Small-C, c4, tcc, chibicc), the intermediate languages
(C--, QBE), and the books. The twins are the Principia book
`compilers/` (5c, in C), goken's 5c and 7c, and xix's `compiler/`
(occ, in OCaml, unfinished).

The fifth ix program, and the second half of the toolchain: it writes
the objects that mini-ld links, as 5c writes 5l's. Planned as the
others were; the principles are in [`../README.md`](../README.md).
The question that opened it (the author): "I wonder if [we] want to
use an intermediate target like in ~/c--/ instead of getting 5c
directly target 5a and 7c 7a? Is there a way to factorize the code
between mini-cc targets?" This plan's answer, decision 1: Plan 9's
assembly is already the intermediate target, and the factoring is one
code generator with a record per machine.

## Context

A C compiler turns a `.c` file into instructions. Plan 9's is a front
end shared by all the machines (goken's `cc/` or `cck/`: preprocessor,
lexer, parser, declarations, types, the tree's rewriting) and a back
end per machine (`5c/`, `7c/`...: code from trees, statements,
switches, and an optimizer), which writes the instructions straight
into an object for the linker, the same instructions 5a would have
read. What makes Plan 9's compilers small is what its linker does:
constants, literal pools, frames, the reach of a branch, the legal
forms of an operand are the linker's business, so the compiler writes
simple instructions and never knows an address.

Why this program now:

- **Its half of the toolchain is done.** mini-asm's instruction type is
  what the compiler will write, and mini-ld links it byte for byte like
  5l and 7l (plan_asm.md). The compiler adds no format and no new
  machinery: the same objects, the same linker.
- **A reference runs today**: goken's 5c and 7c, on this machine, with
  `-O0` (checked, 2026-09-23: hello with goken's libc, compiled with
  `5c -O0` or `7c -O0` and linked, prints its line). `-O0` turns off
  exactly the two passes that are heuristics, registerization and the
  peephole (`reg.c` and `peep.c`, 2,700 lines per machine; goken's
  `notes_frontend_optlevels.txt`).
- **The corpus is there**: goken's libc (all of it, 149 files that
  mini-asm and mini-ld already build from `5c -S` and `7c -S`), libbio,
  libregexp, libstring, the utilities, and the 17 `hello_libc`
  programs with their expected outputs.

## Principles

Those of [`../README.md`](../README.md), and four of its own:

- **The object is the contract, byte for byte where goken is
  deterministic.** At `-O0`, the executables that mini-cc and
  mini-ld make from goken's libc and programs must be goken's (`5c -O0`
  and `5l`, `7c -O0` and `7l`); the listings (`-S`) must be the same
  instruction for instruction. What goken does at `-O2` (registers,
  peephole) is a later phase, or an exercise.
- **The input is the C the corpus is written in**, counted (below):
  Plan 9's dialect of C89, not C99. A construct outside it is an error,
  named.
- **One front end, one code generator, a record per machine**
  (decision 1): what differs between arm and arm64 is data and a few
  functions, and must be seen to be.
- **goken may change to make the comparison possible**, behind flags,
  as for the toolchain (plan_asm.md, decision 5); each change listed
  here.

## The question: an intermediate target, or Plan 9's?

Three ways to have two targets:

```
   Plan 9 (goken):   cc/ front end --> 5c/ back end --> 5.out objects --> 5l
                                   \-> 7c/ back end --> 7.out objects --> 7l
                     two back ends, copies of each other

   C-- (qc--):       front end --> C-- --> RTLs --> instruction selection per machine
                                            (BURG), dataflow, register allocation,
                                            calling conventions as machine descriptions

   this plan:        front end --> one code generator --> mini-asm's instructions --> mini-ld
                                      |  record: Arm64 or Arm (widths, opcodes,
                                      |  conversions, calls, 64-bit on arm)
```

**Why not C--.** qc-- (Ramsey and Peyton Jones's, in the author's fork
`~/c--`) is the general answer: a portable assembly language and a
backend that turns it into machine code for many machines, with
optimizations. Its cost is its generality: for one target,
`arch/arm64` is 3,300 lines, on top of 12,700 of the shared machinery
(`middle/` 6,755, `backend/` 3,868, `rtl/` 2,060); its arm target is
listed as not compiling (`arch/status.txt`). That is three times this
whole compiler's budget, for what ix doesn't need (many machines,
optimizations), and the IR would need a backend that mini-ld already
is.

**Plan 9's assembly is already an intermediate language.** One syntax
for every machine, pseudo-registers for the frame and the static base
(`FP`, `SP`, `SB`), and a linker that turns an instruction into what
the machine can do: a large constant into a pool or `MOVZ`/`MOVK`, a
far address into a load, `DIV` on arm into a call, a `RETURN` into the
frame's epilogue. So a compiler for Plan 9's toolchain writes nearly
the same instructions for both machines (checked, `5c -O0` and `7c
-O0` on the same function; the tutorial's §8):

```
   5c                          7c
   MOVW  i-4(SP),R4            MOVW  i-4(SP),R4
                               SXTW  R4,R4        widen the index
   SLL   $2,R4                 LSL   $2,R4
   MOVW  a+0(FP),R5            MOV   a+0(FP),R5   a pointer is 8 bytes
   ADD   R5,R4                 ADD   R5,R4
   MOVW  0(R4),R4              MOVW  0(R4),R4
   RET                         RETURN
```

**But goken has two back ends, not one**: 5c and 7c are copies that
drifted. How far, counted (`languages/c/tests/compare_c.py`, comments and
layout removed; the full output in the appendix):

| | 5c | 7c | the same, in order | in any order |
|---|---:|---:|---:|---:|
| back ends, without `reg.c` and `peep.c` (cgen txt sgen swt mul list gc.h) | 3,639 | 3,921 | 65% | **77%** |
| statements and switches (`pgen.c`, `pswt.c`) | 590 | 617 | 53% | 84% |
| front ends (principia's `cc/` for 5c, kencc's `cck/` for 7c) | 7,862 | 8,026 | 75% | **89%** |

The machine is where it should be: in `txt.c`'s `gopcode` (the opcode
for an operator and a type; 59% alike), `gmove` (the conversions
between types; 65%), `naddr` (an operand into an address), and cgen's
`sugen` (copying structures: `MOVM` on arm, words on arm64); `mul.c`
(multiplying by a constant) is 98% alike. The rest differs by width
(`MOVW` against `MOV`), by name (`RET` and `RETURN`), and by order.

**And one front end serves both.** goken also has `5ck`, 5c's back end
on kencc's `cck/` front end, which is 7c's. Checked over libc's port,
fmt and utf (130 files): `5c -O0 -S` and `5ck -O0 -S` print the same
instructions for 117 of them, and for the 13 others differ only in how
many digits a float constant is printed with. So principia's front end
and kencc's give the same code, and the reference for both machines is
one front end.

## The subset, counted

Counted with `languages/c/tests/count_c.py` over goken's libc (all of
it), libbio, libregexp, libstring, the `hello_libc` programs and the
utilities, with their headers: 399 files, 60,879 lines (the full counts
in the appendix). Tokens, not a parse: so the counts are close, not
exact.

| construct | count | kept |
|---|---:|---|
| `if` `for` `while` `do` `switch`/`case` `break` `continue` `return` | 9,000+ | yes |
| `goto` and labels | 253, 107 | yes |
| `struct` `union` `typedef` `enum` | 243, 50, 370, 52 | yes |
| `->` | 3,012 | yes |
| `?:` | 132 | yes |
| function pointers | 68 | yes |
| varargs (`...`), with Plan 9's `va_arg` macros | 57 | yes |
| `vlong` `uvlong` (Plan 9's 64-bit, `long long` in `u.h`) | 752, 115 | yes: native on arm64, calls to libc's `_addv`... on arm (5c's `com64`) |
| `double` `float`, float literals | 213, 14, 338 | yes (FPA on arm: encoded, not run, as mini-ld) |
| `static` `extern` `register` `volatile` `const` | 595, 237, 2, 1, 43 | yes (`register`, `volatile`, `const` read and ignored, as 5c at `-O0`) |
| bitfields | 0 | no |
| designated initializers, compound literals | 0 | no |
| Plan 9's unnamed members (`Lock;` in a struct) | 1 at most | no (xix drops them too) |
| preprocessor: `#include` `#define` (152 with arguments) `#ifdef` `#ifndef` `#else` `#endif` `#undef` | 897, 612, 45, 15, 23, 55, 2 | yes |
| `#if` with an expression | 0 | no |
| `#pragma varargck`, `profile`, `lib` | 5, 3, ... | read and ignored (format checking, profiling, 5l's libraries) |
| `#line` (in generated files) | 333 | yes |

So: C89 with Plan 9's types, a preprocessor without `#if`, no
bitfields. What 5c's front end has beyond it and mini-cc leaves
out: acid and pickle output (`-a`, the debugger's type info), format
checking (`dpchk.c`), kencc's struct operators (`funct.c`), profiling.

## Groundwork decisions

### 1. One front end, one code generator, a record per machine

The compiler's modules (target lines in "How to be smaller"):

```
   Pre       the preprocessor: #include, #define, #ifdef...     (goken: mac.c)
   Lexer     tokens, with the typedef names known (the lexer hack)
   Parser    declarations and statements into the tree           (cc.y, dcl.c)
   Type      types, their sizes by the machine's record           (dcl.c, sub.c)
   Check     typechecking, conversions made explicit, constants   (com.c, scon.c)
             folded; 64-bit arithmetic on arm into calls          (com64.c)
   Gen       code from the tree: expressions by need (Sethi-Ullman), (cgen.c, sgen.c,
             conditions, structures, statements, switches          pgen.c, swt.c)
   Arm64     the record: widths, registers, opcodes, conversions,  (txt.c, gc.h)
   Arm       calls, what is native and what a call
   Obj       the objects, mini-asm's; -S the same as text          (swt.c's outcode)
```

`Gen` asks the record for everything the machine decides, and nothing
else: how wide a type is, which registers it may use, the instruction
for an operator on a type, how to convert one type to another, how to
copy a structure, and whether an operator is an instruction or a call.
xix already cut its compiler this way (`Arch_compiler.t`, and a 117
line `Arch5`), and the counts above say the cut is where the machines
differ. The risk: where 5c's and 7c's code generators differ by choice
rather than by machine, the record grows functions; the first phase
measures that before the second machine.

### 2. The objects are mini-asm's; `-S` prints what mini-asm reads

The compiler writes `Asm.obj`, the instructions mini-asm would have
written, so mini-ld links them unchanged, and `-S` prints them in Plan 9's
syntax. The law: `mini-cc -S f.c | mini-asm` makes the same object as
`mini-cc f.c`, byte for byte. This is Plan 9's design (5c writes 5l's
objects, and prints 5a's language only when asked), and it is what
makes the toolchain's first half the compiler's backend.

### 3. `-O0`, byte for byte

Against `5c -O0` and `7c -O0`: every local in its stack slot, registers
allocated per expression and freed after it, no peephole. That leaves
the part of 5c and 7c that is the design (trees to instructions), and
drops the part that is tuning (2,700 lines of dataflow and patterns per
machine). The comparison is on the listings, normalized
(`languages/c/tests/`: the operand spellings of 5c's and 5ck's listings,
the digits of a float), and on the executables, with mini-ld.

### 4. The dialect: Plan 9's C, as 5c at `-O0` reads it

`u.h`'s types (`uchar`, `vlong`...), `nil`, `USED`, the calling
convention (the first argument in R0, the rest on the stack, the result
in R0, a structure returned through a hidden pointer), `char` signed on
arm and unsigned... as goken has it (to check per machine). Stricter
where 5c is lax and the corpus doesn't need it (implicit function
declarations, as xix), and a warning never changes the code.

### 5. 64-bit arithmetic on arm: 5c's calls

arm has no 64-bit registers: 5c turns `vlong` arithmetic into calls to
libc's `vlrt.c` (`_addv`, `_mulv`, `_divv`, ...) and a structure-like
return (checked: `return a + b` on vlongs is `BL _addv(SB)`). The
record says which operators are calls; `Check` rewrites them before
`Gen`, as `com64.c` does.

### 6. The parser: ocamlyacc, the typedef names known to the lexer

Revised while building (2026-09-23), on the author's question: C's
grammar is what yacc was made for, and cc.y needs no tricks beyond
the lexer being told when a name is a typedef (`T * x;` is a
declaration or a product) and `%prec` for the dangling `else`. Its
mid-rule actions are small rules in `Parser.mly` (ocamlyacc has none).
Being LALR(1) like cc.y, it runs the declaring actions at the same
points of the input, which is what makes the typedef names and the
line numbers come out as cck's. The grammar and its actions: 517
lines. The lexer stays by hand: C's is one with the preprocessor's
input stack (a macro's expansion is pushed as input), which ocamllex's
one buffer does not fit. By hand stays right for mini-asm (lines of
operands); for mini-rc's `syn.y`, yacc would have been as short.

### 7. Where the code goes, and the names

`compiler/` at first, xix's name (principia's is `compilers/`); moved
to `languages/c/` (2026-09-26, the author) when a second compiler came
(`languages/ml/`, plan_ml.md), as the Playground has
`libs/languages/`. The command is
`mini-cc`, the target a flag (`-m 5` or `-m 7`), with `-S`, `-I`, `-D`,
`-o`. (`mini-cc` is also the common name of Bellard's TCC: the related
work says so, and the README's "mini-cc" stays the program's
name.)

## How to be smaller than goken

goken's C for the same (normalized: no comments, no blank lines, no
generated files): the front end about 7,900 lines and its preprocessor
670; the two back ends without their optimizers 3,639 and 3,921; the
statements and switches about 600. About **16,700** lines, or 22,100
with `reg.c` and `peep.c`. Where mini-cc saves:

| goken | lines | mini-cc | why |
|---|---:|---|---|
| two back ends, copies of each other | 7,560 | one `Gen`, two records | decision 1 |
| `reg.c`, `peep.c` per machine | 5,488 | none | `-O0` (decision 3) |
| acid, pickle, format checking, struct operators, profiling | ~1,500 | none | out of the subset |
| yacc grammar and its actions | 660 + | a parser by hand | decision 6 |
| a preprocessor with `#if` and its expressions | 670 | without `#if` | the counts |

**The target**, by module:

| module | lines | what |
|---|---:|---|
| `languages/c/Pre.ml` | 200 | the preprocessor |
| `languages/c/Lexer.ml` | 250 | tokens, the typedef names |
| `languages/c/Parser.mly` | 650 | declarations, statements, expressions |
| `languages/c/Tree.ml`, `Declare.ml`, `Check.ml` | 700 | types, declarations, typechecking, conversions, constants, 64-bit calls |
| `languages/c/Gen.ml` | 900 | expressions, conditions, structures, statements, switches |
| `languages/c/Arm64.ml` | 300 | the record for arm64 |
| `languages/c/Arm.ml` | 350 | the record for arm, 64-bit arithmetic's calls |
| `languages/c/Obj.ml`, `CLI.ml` | 150 | objects, `-S`, the command |
| **total** | **about 3,500** | a fifth of goken's (without the optimizers), a sixth with |

*As built (2026-09-24, the trees an ADT)*, with comments and blank lines (the `.mli`s,
812 lines, apart):

| module | lines | against the target |
|---|---:|---|
| `Pre.ml` | 329 | 200: `#include`'s search, `#pragma profile` |
| `Lexer.ml` | 220 | 250 |
| `Parser.mly` | 574 | 650 |
| `Tree.ml`, `Declare.ml`, `Check.ml` | 1,878 | 700: declarations and initializers are dcl.c's 1,500 lines of C |
| `Gen.ml`, `Multiply.ml` | 1,188 | 900: com64.c, mul.c's search and its hints |
| `Arm64.ml` | 263 | 300 |
| `Arm.ml` | 229 | 350 |
| `Emit.ml`, `CLI.ml`, `Main.ml` | 572 | 150: the registers and the frame's areas are here, not in Gen, and the listing's format |
| **total** | **5,253** | a third of goken's without the optimizers, a quarter with |

The modules differ from decision 1's list: `Type` is `Tree` (with the
tree and the symbols) and `Declare` (dcl.c's declarations, scopes and
initializers); `Obj` is `Emit`, which also holds the instructions, their
operands and the registers, shared by the two machines; `Multiply` is
mul.c's search, arm's multiplications by a constant.

The second compaction (the author: "using more variants and more elegant
code instead of following the style of 5c/7c") kept the output byte for
byte and changed the representation: types' kinds a variant with no
bit sets or `Obj.magic` ranks, sub.c's operator tables predicates, the
usual conversions a rule instead of a 13x13 table, one no-op-cast rule
for both machines, a declaration's words a variant list, a node's
addressability a variant instead of 20/10/11/12/2/3, the preprocessor
and lexer on chars, the flags booleans and variants, the compare and
its branch shared by the machines. What stayed 5c's is what the output
depends on: register allocation's order, the terms' sort, Plan 9's
`%.17e` (which is not the shortest round trip: 17% of random doubles
print differently, so the emulation stays).

Then the trees became an OCaml ADT (the author: "let's use a real OCaml
ADT, especially if this makes not only the code smaller but clearer"):
expressions a record of attributes around a variant (`Binary`,
`Assign`, `Call`...), statements, declarators and initializers types
of their own, and the passes functions from trees to trees; the
accessors of a node's sides (`Tree.l n`, 134 uses) and the tests of its
op (80) are gone, the assignments to fields down from 331 to 116, and
the listings the same at the first run. The `-x` dump is the ADT's own
now, so `languages/c/tests/front.sh`, which compared it with cck's, is
retired; the listings cover what the front end decides, and
`languages/c/tests/c/` the corners the corpus may not reach. Two fixes on
the way: a wide string initializing an array gives its runes (5c's
nextinit; the port gave zeros), and com64's calls no longer consult
arm's machcap, which is always false.

## Outside the compiler: the one-file variant

The author's question has a second half: an explicit intermediate
language. That is the variant's to try: `tiny/TinyC.ml`, a smaller C
(what the variant's author picks) through an explicit IR of its own,
three-address or stack, to arm64 assembly for TinyAssembler, whose
sizes-before-addresses design suits it. The question it answers is
the one this plan answers the other way: what does an IR buy, against
writing Plan 9's instructions directly, in the same lines? Decided
after the compiler, by what it taught.

## The modules, with their references

- **Pre, Lexer, Parser**: goken's `cc/mac.c`, `lex.c`, `cc.y`, `dcl.c`;
  Kernighan and Ritchie, *The C Programming Language* (1988), appendix
  A; xix's `compiler/Lexer.mll`, `Parser.mly`.
- **Type, Check**: goken's `com.c`, `sub.c`, `scon.c`, `com64.c`; xix's
  `Typecheck.ml`, `Check.ml`.
- **Gen**: goken's `5c/cgen.c`, `sgen.c`, `swt.c`, `cc2/pgen.c`,
  `pswt.c`; Ken Thompson, "Plan 9 C Compilers" (1990); Sethi and Ullman,
  "The Generation of Optimal Code for Arithmetic Expressions" (1970).
- **Arm, Arm64**: goken's `5c/txt.c`, `gc.h`, `7c/txt.c`; xix's
  `Arch5.ml`; the Principia book `compilers/`.

## Tests (what the program is for)

- **The listings**: every function of the corpus, through `mini-cc -S`
  and `5c -O0 -S` (or `7c`), normalized; the same instructions.
- **The objects' law**: `mini-cc -S | mini-asm` against `mini-cc`.
- **Milestone 1: goken's `tests/c`** (mini, variants, regressions) for
  both machines, the listings the same, and the programs run.
- **Milestone 2: libc and the programs, through ix only.** goken's libc
  compiled by mini-cc, linked by mini-ld, and the 17 `hello_libc`
  programs: the executables the same as goken's `-O0` chain, byte for
  byte (but for goken's section table, `elfcmp.py`), and running, on
  both machines.
- **Milestone 3: the utilities** (`cat`, `ls`, `grep`...) compiled and
  run, on both; on a Raspberry Pi and the Mac (the author).
- **A fuzzer**: random programs of the subset (expressions of every
  type, conversions, loops, switches, calls), through goken and ix; the
  listings must be the same. It found what the corpus missed, twice
  (the editor, the linker).

## Phasing

0. **Groundwork**: the counts and the comparisons (done, in
   `languages/c/tests/`); the listing normalizer; `5c -O0` against `5ck
   -O0` over all of libc, to settle the front end's reference; the
   calling convention and `char`'s signedness per machine, checked.
1. **Front end**: Pre, Lexer, Parser, Tree, Declare, Check, for the whole
   corpus: every file parsed and typechecked (a `-dump` against a
   sample by hand; 5c's errors are not compared).
   *Done (2026-09-23)*: `languages/c/tests/front.sh` compares `mini-cc
   -x` with cck's `-x` (5ck, 7c) over the corpus's 235 files that cck
   compiles here: the same trees on both machines. The front end is
   3,023 lines (non-blank), where 1,800 were planned: the
   faithful type checker and declarations (Check 914, Declare 676,
   Tree 395) are three times the target. The total is now expected
   near 5,000, against goken's 16,700 and xix's 7,065 (its code
   generator unfinished); Check and Declare get a second, smaller pass
   once Gen shows what of them the code needs.

2. **Gen and arm**: the listings of the corpus against `5c -O0`,
   function by function; milestone 1 for 5; the fuzzer.
   *Done for arm (2026-09-24)*: `languages/c/tests/listing.sh 5` compares
   `mini-cc -S` with `5c -O0 -S` over the 235 files of the corpus 5c
   compiles: all the same, line for line. And `MINICC=1
   linker/tests/libc.sh 5` builds libc and the 17 hello_libc programs
   with mini-cc and mini-ld: the executables are goken's, byte for byte
   (but goken's section-table bug, which also breaks goken's `pipe`),
   and run the same. What it took beyond the port: 5c is linked with
   glibc's qsort (a merge sort), whose ties on addresses reverse equal
   terms in acom; with Plan 9's fmt, whose `%.17e` prints the fewest
   digits that read back; `#pragma profile`; and mini-ld dropping the
   NOPs that `-O0` leaves, as 5l's noops. 5c -O0 and 5ck -O0 generate
   the same code (all of libc; only their listings' formats differ).
   The compiler is 5,223 lines with arm (Emit 407, Gen 1,192,
   Multiply 150, Arm 296).

3. **arm64**: the second record, and a look back at what it shows of
   decision 1 (how large the records are, what moved into Gen);
   milestone 1 for 7.
   *Done (2026-09-24)*: `listing.sh 7`, the 235 files the same as
   `7c -O0`; `MINICC=1 libc.sh 7`, the 17 programs goken's executables
   byte for byte (but the section table). Decision 1's test: Arm64 is
   318 lines, Arm 302, against Emit 414 and Gen 1,295 shared. What
   moved into Gen was not only instructions: 7c's generator differs
   from 5c's in policy too, and each difference is a field of the
   record (hooks: `fits`, `neg`, `rsb`, `by_left`, `com64`, `shifts`,
   `zero_arg`, `asop_load`, `indreg_ptr`; backend: `ret`, `offset32`,
   `zero_reg`, `float_from_last`). `mem` and `stat` crash at `-O0` on
   arm64, goken's executables as ix's: a goken 7c -O0 bug, to look at.

4. **Milestone 2**, on both; then milestone 3.
5. **The one-file variant**, in `tiny/`.
   *Done (2026-09-24)*: `tiny/TinyC.ml`, 870 lines (678 of code). A C
   subset chosen by what each feature costs (no floats, unions, enums,
   bitfields, function pointers, structures by value or goto), through
   a stack machine of its own (`-ir` prints it), whose stack the back
   end keeps in R1..R15, as Wirth's compilers do; 7c's calling
   convention, so it calls goken's libc, variadic `print` included.
   `TinyC_test.sh` compiles each program with TinyC and with `7c -O0`,
   assembles both with all of libc by TinyAssembler, runs them and
   compares: the 8 of `TinyC_tests/` (arithmetic of every width, pointers
   and arrays, structures and a list, control, globals, calls, a sort
   and an RPN calculator), and 300 random ones of `TinyC_fuzz.py`, all
   the same. What the fuzzer found: Plan 9's C promotes `uchar` and
   `ushort` to `uint` (unsigned-preserving, cck's table), which TinyC
   now does; optimized 7c's MOVW of a negative 64-bit constant
   (`plan_bugs_goken.md`, 5b), hence `-O0` as the reference; and two
   gaps in TinyAssembler, `NOP` and `SXTW $c`, now filled. **The IR's
   answer** (the question of "Outside the compiler"): the front end
   knows no register and no instruction, the back end no C (its 120
   lines are the whole machine), and each is read and tested alone; the
   cost is the code's quality (no Sethi-Ullman order, no addressing
   modes, a load or a store per variable). mini-cc, with no IR and
   5c's decisions, is 5,621 lines for two machines and byte-identical
   code; TinyC, 678 lines of code for one machine and correct code.
   Floats are the first to revisit (the author: "float are pretty
   fundamental"): a second register class on the same stack (a depth
   in Rd or Fd by its type), 7c's convention for them (a double
   argument in its slot, the result in F0), the conversions and
   compares TinyAssembler already has; started, then left for later.

   *A second machine (2026-09-25)*, the author: "ideally we can have
   tiny-c that can also output .tm". `tiny-c -tm` compiles for
   TinyCPU (`tiny/TinyLibCPU.ml`, the teaching machine of plan_arm.md)
   with the same front end and stack machine and a second back end,
   100 lines: the stack in r1..r12, r13 the result, every argument in
   memory, 4 bytes each (so a variadic function walks them from its
   last named one's address), relations by `slt`/`sltu`, a short by two
   byte accesses, unsigned division by the runtime's `__udivmod`
   (TinyCPU divides signed only). The front end changed where the
   machine shows: a pointer's size (4), a declared `long long`
   refused (the registers are 32 bits), and the data, arm64's `DATA`
   and `GLOBL` or `.byte`/`.word`/`.space` under a label, each global's
   kept until its label (a string in an initializer is written before
   its array). TinyC grew from 883 to 1,074 lines; arm64's output is
   byte for byte what it was, on all of `TinyC_tests/`. The runtime,
   `tiny/TinyC_runtime/`: `start.tm` (`_start`, `write`, `exits`,
   `__udivmod`, 75 lines) and `libc.c` (print, sprint, the strings,
   atoi, a bump malloc; 163 lines of C, compiled by `tiny-c -tm`).
   tiny-cpu learned to link several `.tm` into an image and to pass
   argc and argv, as Linux does.

   `TinyC_test.sh` now also compiles each program with `-tm`, links it,
   runs it on tiny-cpu, and compares with 7c's: control, globals,
   hello, ptr, sort, and a new `udiv.c` (unsigned division at its
   edges) the same; arith, calls and struct refused (their long long).
   `TinyC_fuzz.py --32` writes random programs without long long, for
   both: 500 the same (and 100 in `make test-goken`). What it found:
   goken's `print` takes `%u` as a verb, not Plan 9's flag (its libc is
   built without PLAN9PORT: `%ud` is the number then a `d`), which the
   runtime's print follows, the reference being goken's; and, by a
   mutation not caught, that `__udivmod`'s carry case cannot happen
   (after k steps the remainder is below 2^k), removed. A `<=` made
   `<` in the back end fails 4 of 30 random programs; a division
   step skipped fails `udiv.c`. The runtime moved to `tiny/tiny-os/`
   the same day, with a Makefile that compiles, links and runs a C
   program (`hello.c`) with the installed tools.

6. **Docs**: `notes_cc.md` checked against the code, the numbers.
   *Done (2026-09-24)*: the tutorial's module table and three
   statements corrected (the lexer's typedefs, where com64 runs, the
   parser's ocamlyacc); each module's `.mli` written, with its
   references (Thompson's paper, quoted from principia's
   `compiler.ms`; Sethi-Ullman; the Dragon book; Baker; Johnson;
   Bernstein); the runners pass the mkfiles' `$CFLAGS_EXTRA` (`-DUnix`
   in utilities/pipe and files), the 235 files still the same.

## Status

- **2026-09-23, the plan written, for review** (the author: "let's do
  it", on decision 1's answer). Checked for it:
  - `5c -O0` and `7c -O0` compile hello with goken's libc, and it runs;
    `-O0` turns off `reg.c` and `peep.c` and nothing else (goken's
    notes);
  - the back ends' and front ends' alikeness (the table above), with
    `languages/c/tests/compare_c.py`;
  - `5c -O0` and `5ck -O0` print the same code for 130 libc files (13
    differ in a float's printed digits only);
  - the corpus's C, with `languages/c/tests/count_c.py`;
  - the tutorial's listings (hello, a loop, a switch, a vlong add, a
    structure returned), from `5c -O0 -S` and `7c -O0 -S`;
  - qc--'s size per target, and xix's compiler: 5,553 lines, its
    front end complete, its code generator mostly `raise Todo`.
- **2026-09-26, amended**: two back ends, compat (byte for byte, the
  default) and `-simple` (behavior only), one front end; see
  "Amendment (2026-09-26)" before the appendix. All four steps done
  the same day, simple/ on both machines; opti/ later.

## Verification

`make test` will run the listings' corpus against recorded outputs (as
`linker/tests/golden.sh`), and `make test-goken` the live comparisons
and the milestones.

## Out of scope

Registerization and the peephole (`-O2`), a later phase; C99 and later
(designated initializers, compound literals, `//` is read), bitfields,
`#if`; acid and pickle, format checking, profiling; other machines;
the preprocessor as its own program; optimizations of any kind beyond
5c's `-O0` (its constant folding and its multiplications by shifts are
in).

## Related work

[`notes_cc_related_work.md`](../related-work/notes_cc_related_work.md).

## Amendment (2026-09-26): two back ends, `-simple`

The question (the author): mini-ml is smaller than mini-cc, but
TinyML bigger than TinyC; "what if we were relaxing the constraint on
mini-c like we did on mini-ml? Would that lead to far simpler code?
... not the full TinyC road, just a simpler mini-c"; then: "split the
code in languages/c/ and have the common code there, and then a
subfolder for a version that is byte-to-byte compatible, and another
folder for a more free version? And a flag to switch".

Why the sizes cross: a mini twin's size is its contract's, a tiny
variant's its language's. mini-ml's contract is the behavior
(plan_ml.md: "Unlike mini-cc against 5c, nothing is compared byte for
byte"), so it lowers to a stack machine (`Lower.ml`, then a 317-line
`Gen.ml`); mini-cc's is the listing, instruction for instruction
(decision 3). In tiny/, both are stack machines with no contract, and
ML's own work shows: types inferred, patterns compiled, closures,
exceptions, the collector's roots.

### What relaxing would buy: a quarter, not more

Estimates, from reading the modules (not measured; step 4 measures):

- **The language, whatever the contract** (about 2,900 lines): `Pre`,
  `Lexer`, `Parser.mly`, `Tree`, `Declare` (dcl.c's declarations and
  initializers are C's semantics, not 5c's habits), `Check`'s typing
  (the promotions, the usual conversions), and the ABI (decision 4's
  calling convention, the structures' layout: libc's assembly and the
  kernel link with what mini-cc writes).
- **5c's, for the listing only** (about 1,100 to 1,300 lines):
  `Multiply` and `mulcon` (a `MUL` would do); `acom`, the sums
  regrouped, down to glibc's merge sort's order of equal terms; most of
  `ccom`'s rewrites (the constants' folding stays: case labels and
  initializers need it); the `hooks` record's twelve choices (`rsb`,
  `mul32`, `asop_load`, `zero_arg`...) and part of `Arm` and `Arm64`;
  Sethi-Ullman's order (`xcom`), 5c's registers, `boolgen`'s jumps,
  the switch's binary search and tables.

So mini-cc relaxed would be about 4,000 lines against 5,250: simpler,
not far simpler. Relaxing alone would lose the oracle (the listings
found what the corpus missed, twice, and check mini-asm and mini-ld by
the way) and the twin (Gen reads as cgen.c, sgen.c and com64.c, for
the reader of principia's `compilers/`). Hence both, split.

### Decision 8: one front end, two back ends, a flag

```
languages/c/          the language, shared (~2,900)
  Pre, Lexer, Parser, Tree, Declare,
  Check (typing, commas, constants folded),
  Machines (the types' sizes, the calling convention), CLI, Main
languages/c/compat/   byte for byte with 5c and 7c -O0: today's back end
  Acom (out of Check), Gen, Multiply, Emit, Arm, Arm64
languages/c/simple/   the behavior only, mini-ml's design (~1,000-1,200)
  Lower (the tree to a stack machine), Gen (a record per machine)
languages/c/opti/     later: passes on simple's IR, each switchable
```

`mini-cc` stays 5c's twin by default; `mini-cc -simple` picks the other
back end. The cut exists already: `CLI.ml` gives the front end its back
end through four hooks (`Check.xcom`, `Check.outstring`,
`Declare.gextern`, `Declare.on_function`), and the flag chooses who
fills them. This is the optimizations' rule the other way round (the
simple path clear, the rest a section of its own, switchable): the
reader reads the front end and `simple/`, about 4,000 lines, and
`compat/` is fidelity to 5c, read to see how 5c does it. The total
grows, to about 6,300.

What the cut must settle:

1. **`acom` leaves `Check.complex`** (`!xcom (acom (ccom (comma n)))`):
   it is 5c's, run by compat's `xcom` hook. `ccom`'s folding stays in
   Check; what of the rest of `ccom` is 5c's only, the cut measures.
2. **The strings' data is written while typing**, in 5c's order
   (`Check.outstring`): for simple, only where they go, its own
   `outstring`; a constraint of compat's, said in `Check.mli`.
3. **`Emit` splits**: both back ends write mini-asm's instructions, so
   decision 2's law holds for both (`mini-cc -S f.c | mini-asm` the
   same object as `mini-cc f.c`). The instructions, operands (`naddr`),
   data (`outstring`, `gextern`), the file's end and the listing's
   format are shared, in `languages/c/`; the registers
   (`regalloc`...) and the frame's areas are compat's.
   *Deferred to step 2* (2026-09-26, at the cut): `Emit`'s operands
   are compat's trees (`naddr` takes a `Reg` node, 5c's 32-bit
   offsets, the float registers numbered from `nreg`), so what simple
   can share is known only once simple is written; step 1 moved `Emit`
   whole into `compat/`.
4. **64-bit arithmetic on arm** (Gen's com64 section, decision 5) is
   behavior, not fidelity: simple needs the calls too, so the rewrite
   moves to the shared side, or simple has its own, smaller.

Tests: compat keeps its own (`listing.sh 5` and `7`, the executables
byte for byte). simple's are behavior's, against 7c's and 5c's:
`hello_libc` and its outputs, `tiny/TinyC_tests/`, `TinyC_fuzz.py`'s
programs, and all of goken's libc compiled with `-simple`, linked,
the programs run. The fuzzer against the reference, as every program.

It also answers "Outside the compiler"'s question inside the compiler:
what an IR buys, against writing Plan 9's instructions from the trees,
on the same C and the same front end.

### Phasing

1. **The cut, no behavior changed**: the files moved, `acom` out of
   Check, `Emit` split, `-simple` refused. Done when `listing.sh 5`
   and `listing.sh 7` are the same, and the executables still goken's.
   *Done (2026-09-26)*: `compat/` (`Acom`, `Emit`, `Multiply`, `Gen`,
   `Arm`, `Arm64`: the library `ix_cc_compat`, which opens `Ix_cc`);
   the machines' records (sizes, `typecmplx`, `machcap`...) out of
   `Arm` and `Arm64` into `Machines.ml`, the front end's; `CLI.ml` a
   library of its own (`ix_cc_cli`), the back end a record (`init`,
   `codgen`, `finish`, `listing`, `obj`), compat's `init` setting the
   four hooks, `Check.xcom` as `Gen.xcom (Acom.acom n)`; `-simple`
   refused. `Emit` not split (item 3). Checked: `listing.sh 5` and
   `7`, 241 the same, 0 different; `fuzz.sh 150`, 300 the same;
   `MINICC=1 linker/tests/libc.sh 5` and `7`, every executable the
   same as goken's (but the section table).
2. **simple on arm64**: `Lower`, the arm64 record; the tests above,
   against 7c.
3. **simple on arm**: the record, the 64-bit calls; against 5c.
4. **The numbers**: lines per directory measured
   (`scripts/stats/loc.py`), this amendment's estimates corrected,
   `notes_cc.md` told of the two back ends.

*Steps 2 to 4 done (2026-09-26)*, both machines at once:

- **The cut's rest**: `Emit` split (item 3), the instructions,
  operands, data, GLOBLs, listing and object shared
  (`languages/c/Emit.ml`), the registers, nodes and 5c's
  `backend` record compat's (`compat/Regs.ml`); com64 (item 4) shared,
  `languages/c/Com64.ml`, compat's xcom calling it as before. The
  listings still 241 the same on both machines, `fuzz.sh` 300.
- **simple/**: `Lower.ml`, the typed tree to a stack machine (values
  of 1 to 8 bytes, floats, a block's address), the frame's temporaries
  and outgoing area, 7c's calling convention; `Gen.ml`, the stack on
  R1-R15 and F1-F15 (arm64) or R1-R7 and F1-F6 (arm), the slot at depth
  i Ri or Fi by its value's kind, a call spilling the live slots. On
  arm, a vlong is a block and its operations libc's calls (the hook
  runs `Com64` bottom up). `mini-cc -simple`.
- **What the tests found** (`notes_fuzzing_techniques.md`, 10 to 12):
  CBZ, which mini-ld's flow cannot invert (7c never emits it), so
  `CMP $0` and `BEQ`; a label no jump reaches, whose stack depth came
  from the dead code before it (`x || 255`); an address held across
  `setjmp` in a spill slot a later call reused, so a call's value is
  computed before the address it goes to; expressions too deep for
  arm's 7 registers in 3 of 60 random programs, so a binary
  operator's deeper operand goes first (Ershov's number), 0 since.
- **Checked** (`languages/c/tests/simple.sh`, and `linker/tests/libc.sh`
  with `MINICC=1 MINICC_FLAGS=-simple`): all of goken's libc compiled by
  -simple on both machines; on arm64, 227 of 228 programs run as 7c's
  (goken's 17 hello_libc, the 11 TinyC_tests, 200 of `TinyC_fuzz.py`),
  the last, `mem`, crashing in `sbrk` as goken's own `7c -O0` build
  does; on arm, the 200 of `TinyC_fuzz.py --32`, the 11 TinyC_tests
  (vlong through libc's calls included) and 16 of the 17 hello_libc as
  5c's, the 17th, `pipe`, printing right where goken's `5c -O0` build
  prints garbage. On `args`, `stat`, `utfmisc` and `pipe`, -simple's
  executables are right where goken's -O0 ones are not.
- **The numbers** (`scripts/stats/loc.py -v`, code lines): the shared
  front end 2,990, `compat/` 1,622, `simple/` 497, against the estimate
  of 1,000 to 1,200: a C compiler for two machines, front end and
  simple, 3,487 lines of code, and compat's fidelity to 5c 1,125 more
  than simple.

### Later: `opti/` (the author: "we could even have an opti/ variant, in addition to simple/ later")

Two optimizers, by their reference:

- **compat's `-O2`**: 5c's registerization and peephole (`reg.c`,
  `peep.c`, 2,700 lines per machine), byte for byte with goken's
  default, so the oracle still holds. They rewrite compat's
  instructions after Gen, so they are compat's modules (`compat/Reg`,
  `compat/Peep`); "Out of scope"'s later phase.
- **`languages/c/opti/`, free**, the third directory beside
  `compat/` and `simple/` (the author: "so compat/ simple/ opti/"):
  passes on simple's stack machine, not a third lowering: `Lower`'s IR
  in, the same IR out (constants, locals kept in registers, a
  peephole), before simple's `Gen`; `mini-cc -O` is `-simple` with
  them. Each pass its own module and flag (one per pass), as the
  optimizations' rule asks; tested as simple is, by behavior, plus the same programs with
  each pass on and off. What it is worth is measured: the instructions
  run (mini-qemu's count) and the lines, against simple's.

Decided after simple is built, by what its IR allows.

## Appendix: the counts and the comparisons

The evidence, from `languages/c/tests/` (2026-09-23).

### The C of the corpus (`count_c.py`)

```
399 files, 60879 lines, in lib_core/libc, lib_core/libbio, lib_strings/libregexp, lib_strings/libstring, tests/c/hello_libc, utilities

keywords and constructs:
  if                       4473
  int                      3957
  ->                       3032
  return                   2377
  char                     2137
  void                     2016
  long                     1370
  case                     1321
  break                    1054
  vlong                     752
  else                      714
  for                       601
  static                    595
  extern                    560
  nil                       559
  while                     433
  sizeof                    388
  typedef                   370
  float literal             338
  continue                  285
  ulong                     255
  goto                      253
  struct                    243
  double                    213
  uint                      176
  uchar                     171
  ?:                        169
  unsigned                  160
  switch                    132
  uvlong                    115
  label                     107
  default                   104
  short                      87
  function pointer           68
  varargs (...)              57
  signed                     53
  enum                       52
  union                      50
  const                      49
  long long                  45
  do                         44
  ushort                     38
  USED                       31
  float                      14
  register                    2
  volatile                    1
  unnamed member              1

preprocessor:
  #define                  1257
  #include                  951
  #line                     333
  #define(                  152
  #endif                     60
  #ifdef                     45
  #else                      25
  #ifndef                    15
  #pragma varargck            5
  #pragma profile             3
  #undef                      2
  #pragma lib                 2
```

### 5c against 7c, the back ends without their optimizers (`compare_c.py 5c 7c`)

```
cgen.c         961  1036   54% the same in order,  77% in any order
    bcgen: 5 / 5 lines, 80% in order, 80% in any order
    boolgen: 140 / 140 lines, 74% in order, 80% in any order
    castup: in B only (17 lines)
    cgen: 2 / 2 lines, 50% in order, 50% in any order
    cgenrel: 473 / 503 lines, 45% in order, 85% in any order
    cond: in B only (17 lines)
    hardconst: in B only (2 lines)
    layout: in B only (29 lines)
    reglcgen: 26 / 32 lines, 68% in order, 68% in any order
    reglpcgen: in A only (11 lines)
    sugen: 254 / 236 lines, 68% in order, 70% in any order
txt.c         1035  1159   54% the same in order,  70% in any order
    exreg: 64 / 64 lines, 34% in order, 34% in any order
    fop: in B only (8 lines)
    garg1: 44 / 48 lines, 79% in order, 79% in any order
    gbranch: 11 / 15 lines, 40% in order, 53% in any order
    ginit: 77 / 83 lines, 50% in order, 80% in any order
    gmove: 275 / 330 lines, 48% in order, 65% in any order
    gmover: 23 / 29 lines, 79% in order, 79% in any order
    gmovm: in A only (5 lines)
    gopcode: 184 / 217 lines, 35% in order, 59% in any order
    gpseudo: 11 / 13 lines, 69% in order, 69% in any order
    isaddcon: in B only (6 lines)
    naddr: 79 / 79 lines, 45% in order, 81% in any order
    nodgconst: in B only (5 lines)
    nodreg: 5 / 5 lines, 80% in order, 80% in any order
    raddr: 11 / 14 lines, 71% in order, 71% in any order
    regret: 7 / 7 lines, 85% in order, 85% in any order
    samaddr: 7 / 2 lines, 14% in order, 14% in any order
    sconst: 9 / 9 lines, 55% in order, 55% in any order
    sval: 9 / 2 lines, 0% in order, 0% in any order
    tmpreg: in A only (7 lines)
    usableoffset: in B only (12 lines)
sgen.c         161   185   74% the same in order,  85% in any order
    gtext: in B only (3 lines)
    xcom: 148 / 168 lines, 73% in order, 86% in any order
swt.c          498   529   80% the same in order,  80% in any order
    align: 52 / 52 lines, 86% in order, 86% in any order
    maxround: 4 / 4 lines, 75% in order, 75% in any order
    outcode: 63 / 63 lines, 88% in order, 88% in any order
    outhist: 43 / 51 lines, 76% in order, 76% in any order
    outstring: 18 / 18 lines, 88% in order, 88% in any order
    swit2: 54 / 56 lines, 82% in order, 82% in any order
    zaddr: 48 / 73 lines, 58% in order, 61% in any order
    zname: 25 / 23 lines, 28% in order, 28% in any order
    zwrite: 16 / 14 lines, 43% in order, 43% in any order
mul.c          465   465   98% the same in order,  98% in any order
list.c         245   265   72% the same in order,  73% in any order
    Dconv: 62 / 100 lines, 51% in order, 51% in any order
    Nconv: 29 / 29 lines, 51% in order, 55% in any order
    Pconv: 40 / 21 lines, 37% in order, 37% in any order
gc.h           274   282   61% the same in order,  63% in any order
total         3639  3921   65% the same in order,  77% in any order
```

### principia's front end against kencc's (`compare_c.py cc cck`)

```
lex.c         1177  1138   74% the same in order,  86% in any order
    Lconv: 50 / 55 lines, 89% in order, 89% in any order
    Oconv: in B only (6 lines)
    VBconv: 16 / 16 lines, 87% in order, 87% in any order
    alloc: in B only (11 lines)
    allocn: in B only (13 lines)
    compile: 106 / 59 lines, 37% in order, 37% in any order
    errorexit: in B only (4 lines)
    filbuf: 39 / 27 lines, 69% in order, 69% in any order
    getnsc: 15 / 14 lines, 86% in order, 86% in any order
    if: in A only (76 lines)
    main: in B only (81 lines)
    pathchar: in B only (2 lines)
    setinclude: 20 / 20 lines, 85% in order, 85% in any order
    syminit: 328 / 20 lines, 4% in order, 4% in any order
    systemtype: in B only (2 lines)
    yylex: in B only (383 lines)
cc.y           660   742   40% the same in order,  66% in any order
    if: in B only (655 lines)
sub.c         1525  1569   84% the same in order,  87% in any order
    allfloat: 22 / 22 lines, 81% in order, 81% in any order
    bitno: 16 / 7 lines, 37% in order, 37% in any order
    copytyp: 12 / 5 lines, 33% in order, 33% in any order
    deadhead: 35 / 38 lines, 39% in order, 63% in any order
    deadheads: 2 / 2 lines, 0% in order, 0% in any order
    fatal: 489 / 506 lines, 82% in order, 83% in any order
    garbt: in B only (7 lines)
    new: 14 / 14 lines, 85% in order, 85% in any order
    nilcast: 21 / 21 lines, 57% in order, 57% in any order
    nocast: 14 / 14 lines, 71% in order, 71% in any order
    prtree: 4 / 4 lines, 75% in order, 75% in any order
    simplec: in B only (21 lines)
    simpleg: 30 / 10 lines, 10% in order, 10% in any order
    stcompat: 21 / 21 lines, 76% in order, 76% in any order
    tcompat: 10 / 10 lines, 80% in order, 80% in any order
    tinit: 89 / 98 lines, 84% in order, 88% in any order
    typ: 13 / 13 lines, 84% in order, 84% in any order
    typebitor: in B only (9 lines)
    typeext1: 3 / 3 lines, 33% in order, 33% in any order
    yyerror: in B only (14 lines)
dcl.c         1197  1201   81% the same in order,  89% in any order
    argmark: in B only (17 lines)
    contig: in B only (60 lines)
    dcllabel: in B only (29 lines)
    dodecl: 83 / 87 lines, 62% in order, 86% in any order
    doenum: in B only (29 lines)
    dotag: in B only (18 lines)
    edecl: in B only (28 lines)
    fnproto: 8 / 8 lines, 87% in order, 87% in any order
    fnproto1: 24 / 24 lines, 58% in order, 87% in any order
    isstruct: 22 / 23 lines, 69% in order, 69% in any order
    markdcl: in B only (8 lines)
    maxtype: 37 / 8 lines, 21% in order, 21% in any order
    newlist: 61 / 6 lines, 8% in order, 8% in any order
    ofnproto: 36 / 19 lines, 52% in order, 52% in any order
    pdecl: 13 / 13 lines, 53% in order, 53% in any order
    push: 6 / 6 lines, 83% in order, 83% in any order
    revertdcl: in B only (62 lines)
    rsametype: 65 / 65 lines, 73% in order, 73% in any order
    sametype: 4 / 4 lines, 25% in order, 25% in any order
    snap: 52 / 5 lines, 9% in order, 9% in any order
    sualign: in B only (55 lines)
    symadjust: 76 / 18 lines, 9% in order, 17% in any order
    tcopy: 14 / 15 lines, 86% in order, 86% in any order
    tmerge: 79 / 51 lines, 60% in order, 60% in any order
    walkparam: 120 / 51 lines, 38% in order, 40% in any order
    xdecl: 43 / 44 lines, 47% in order, 65% in any order
com.c         1172  1170   59% the same in order,  94% in any order
    complex: 30 / 13 lines, 40% in order, 40% in any order
    if: in B only (18 lines)
    tcom: 2 / 2 lines, 50% in order, 50% in any order
    tcoma: 61 / 61 lines, 80% in order, 80% in any order
    tcomd: 10 / 10 lines, 70% in order, 70% in any order
    tcomx: 38 / 38 lines, 84% in order, 84% in any order
    tlvalue: 5 / 5 lines, 60% in order, 60% in any order
com64.c        507   521   92% the same in order,  92% in any order
    convftov: in B only (4 lines)
    convftox: in B only (4 lines)
    convvtof: in B only (4 lines)
scon.c         473   469   89% the same in order,  97% in any order
funct.c        314   316   74% the same in order,  97% in any order
    dclfunct: 78 / 138 lines, 53% in order, 55% in any order
dpchk.c        389   388   72% the same in order,  97% in any order
    pragincomplete: 44 / 43 lines, 86% in order, 86% in any order
    pragprofile: 16 / 16 lines, 87% in order, 87% in any order
bits.c          41    49   81% the same in order,  81% in any order
    band: in B only (6 lines)
    blsh: 8 / 5 lines, 50% in order, 50% in any order
    bor: 6 / 6 lines, 83% in order, 83% in any order
    bset: in B only (3 lines)
acid.c         245   246   96% the same in order,  97% in any order
pickle.c       162   217   74% the same in order,  74% in any order
    picklefun: in B only (24 lines)
    picklesue: 25 / 9 lines, 32% in order, 32% in any order
    picklevar: in B only (44 lines)
total         7862  8026   75% the same in order,  89% in any order
```

### the statements and switches (`compare_c.py cc2 cck pgen.c pswt.c`)

```
pgen.c         438   465   38% the same in order,  79% in any order
    bcomplex: 12 / 25 lines, 32% in order, 32% in any order
    codgen: in B only (62 lines)
    gen: 325 / 332 lines, 30% in order, 85% in any order
    supgen: 17 / 17 lines, 41% in order, 47% in any order
pswt.c         152   152  100% the same in order, 100% in any order
total          590   617   53% the same in order,  84% in any order
```
