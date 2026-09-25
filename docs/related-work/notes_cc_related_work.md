# mini-cc vs. the rest of the C compilers

Where a tiny C compiler sits among the real ones: the first compilers
of expressions, Ritchie's and Johnson's C compilers, Plan 9's, the
retargetable ones (lcc, GCC, LLVM), the small ones (Small-C, tcc, c4,
chibicc), the intermediate languages (C--, QBE, CompCert's), and the
books. What they do that ix won't, and which of their ideas fit in a
program small enough to read. Companions:
[`notes_cc.md`](../tutorials/notes_cc.md) (how it works) and
[`plan_cc.md`](../plans/plan_cc.md) (what gets built). The lineage
file is `principia/compilers/lineage.txt`; the dates below are from
memory unless a source is named, and are to be checked before relying
on them for teaching.

## The one-line version

| | What it optimizes for | Between the front end and the machine |
|---|---|---|
| FORTRAN I (1957), Ershov (1958), Sethi and Ullman (1970) | Code from expressions as good as by hand | nothing: trees to instructions |
| Ritchie's cc (1972-73) | A systems language on a small machine | code tables per operator |
| Johnson's pcc (1977-79) | Porting Unix: one compiler, many machines | trees, and a table of templates per machine |
| Plan 9's 2c/5c/8c (1990) | Small and fast compilers, many machines | the linker's instructions; a back end per machine |
| lcc (1991-95) | Retargeting, as a book | trees, and a tree grammar per machine (lburg) |
| GCC (1987), LLVM (2003) | Every language, every machine, optimizing | an IR (RTL, GIMPLE; LLVM's) and passes |
| C-- (1997-), QBE (2015-) | A portable assembly language as the target | an IR small enough to target |
| Small-C (1980), tcc (2001), c4 (2014), chibicc (2019) | A compiler one person reads, or writes | none, or a stack machine |
| `compiler/` (mini-cc) | Seeing what a C compiler does, on real programs | Plan 9's instructions, one generator, a record per machine |

## Part 1: code from expressions

- **FORTRAN I** (John Backus's team, IBM, 1957) proved that a compiler
  could produce code as good as a programmer's, with the first register
  allocation and expression analysis.
- **Ershov numbers** (Andrei Ershov, 1958) and **Sethi and Ullman**
  ("The Generation of Optimal Code for Arithmetic Expressions", 1970):
  how many registers an expression needs, and that computing the
  hungrier side first is optimal. 5c's `complex` field is this number,
  and mini-cc's code generator is built on it.

## Part 2: C's compilers on Unix

- **Ritchie's C compiler** (Dennis Ritchie, 1972-73, PDP-11): passes
  in separate programs (c0 parsed, c1 generated code from tables of
  patterns per operator, c2 was a peephole optimizer), in the memory of
  a PDP-11.
- **The Portable C Compiler** (Stephen Johnson, pcc, 1977-79; "A
  Portable Compiler: Theory and Practice", POPL 1978): a front end
  shared by all machines, and a second pass driven by a table of code
  templates per machine, matched against the trees with Sethi-Ullman
  ordering. It ported Unix to the Interdata and the VAX, and is the
  ancestor of the idea that the machine is a table.

## Part 3: Plan 9's compilers

- **Ken Thompson's compilers** ("Plan 9 C Compilers" and "A New C
  Compiler", 1990): one front end (`cc`) and a back end per machine
  (2c for the 68020, 8c for the 386, 5c for arm, vc for mips...), with
  the preprocessor built in, and objects of instructions for the
  linker, which chooses the encodings (notes_asm.md §3). Small and very
  fast; its optimizer is a registerizer and a peephole. The dialect
  added unnamed structure members, `#pragma varargck`, and the `u.h`
  types.
- **The Go toolchain** (2009) started as these compilers (6g, 8g, 5g),
  written in C; they were translated to Go in 2015, and got an SSA back
  end in 2016 (Keith Randall's), which is what Plan 9's design became
  when programs got large and speed mattered.
- **goken** (goken9cc) keeps both lineages, principia's (5c on `cc/`)
  and kencc's (5ck, 7c on `cck/`), with `-O0` to turn the optimizer
  off; mini-cc compares against both. **xix's occ** is the same
  design in OCaml, its front end complete and its code generator
  started.

## Part 4: retargetable compilers, and their IRs

- **lcc** (Christopher Fraser and David Hanson, 1991-95; *A
  Retargetable C Compiler: Design and Implementation*, 1995): ANSI C,
  written as a literate program, with an interface of some twenty
  functions between the front end and a back end, and code selection by
  tree grammars (lburg). The closest in spirit to mini-cc's
  record per machine, with a grammar where the record has functions.
- **GCC** (Richard Stallman, 1987) took RTL from Davidson and Fraser's
  peephole optimizer; **LLVM** (Chris Lattner, 2003) made the IR the
  product. Their cost is the price of every language and every
  optimization; their idea, an IR between the languages and the
  machines, is the one this plan declines.

## Part 5: the intermediate languages

- **C--** (Simon Peyton Jones, Norman Ramsey, Thomas Nordin, from
  1997; the Quick C-- compiler, qc--, from 2000): a portable assembly
  language for compilers of other languages, with a runtime interface
  for garbage collection and exceptions, and machine descriptions for
  the back end. The author's fork (`~/c--`) is the backend of a Tiger
  compiler. Plan 9's assembly language answers the same question for a
  C compiler, more cheaply, because its linker is the backend: that is
  plan_cc.md's decision 1.
- **QBE** (Quentin Carbonneaux, from 2015): an SSA IR and a backend of
  about 10,000 lines of C, for amd64, arm64 and riscv64, aiming at 70%
  of an optimizing compiler's speed in 10% of its code; **cproc**
  (Michael Forney) is a C11 front end for it. The best argument for the
  IR route at small size, and the model for the one-file variant's.
- **CompCert** (Xavier Leroy, from 2005): a C compiler proved correct
  in Coq, extracted to OCaml, through a chain of IRs (Clight, Cminor,
  RTL, LTL, Mach). The opposite end: every IR is there because a proof
  needs it.

## Part 6: the small compilers

- **Small-C** (Ron Cain, *Dr. Dobb's*, 1980): a subset of C for the
  8080, generating code for a stack machine with two registers; the
  compiler hobbyists read for a decade.
- **tcc** (Fabrice Bellard, mini-cc, 2001): a whole C99 compiler,
  assembler and linker in one program, one pass, fast enough to boot
  Linux from source (tccboot, 2004). Its common name, `mini-cc`, is also
  mini-cc's command's: the two are unrelated.
- **c4** (Robert Swierczek, 2014): C in four functions, compiling to a
  virtual machine that it also runs, and compiling itself.
- **8cc, 9cc, chibicc** (Rui Ueyama, 2012-2020): C compilers written in
  small steps, each commit a lesson, chibicc with a book; x86-64, and a
  stack-machine code generator.

## Part 7: the books

- **Aho, Sethi, Ullman, *Compilers: Principles, Techniques, and
  Tools*** (1986): the dragon book, and chapter 9's code generation
  from trees.
- **Andrew Appel, *Modern Compiler Implementation in ML*** (1998): the
  Tiger language, IR trees, instruction selection by tiling; the book
  behind the author's `fork-tiger`.
- **Niklaus Wirth, *Compiler Construction*** (1996): Oberon-0 in a
  hundred pages, one pass, for RISC.
- **Abdulaziz Ghuloum, "An Incremental Approach to Compiler
  Construction"** (2006): a compiler grown in tiny steps, each one
  running.
- **Nisan and Schocken, *The Elements of Computing Systems***
  (nand2tetris): the Jack compiler, to a stack machine, for teaching.
- **The Principia book `compilers/`**: 5c's C, literate, which
  mini-cc reads beside goken's.

## What mini-cc takes, and leaves

- **The language, at the real end**: the C that goken's libc and
  programs are written in, compiled to what 5c and 7c at `-O0` make,
  byte for byte, and running on both machines.
- **The implementation, at the legible end**: one front end, one code
  generator (Sethi-Ullman ordering, conditions as jumps, statements,
  switches by table, chain or search), and a record per machine;
  Plan 9's instructions as the target, the linker as the backend.

**The ceiling, stated now**: `-O0` (no registerization, no peephole);
C89 with Plan 9's types, without bitfields or `#if`; no debugger
output; two machines.

## Postscript: the numbers (to come)

Once built: mini-cc's lines per module against the plan's
targets, against goken's 16,700 lines (22,100 with the optimizers) and
xix's 5,553; the size of each machine's record, which is decision 1's
test; the corpus and the fuzzer against goken; and the programs of
milestone 2 running on both machines, compiled and linked by ix only.
