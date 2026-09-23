# TinyAsm and TinyLd vs. the rest of the assemblers and linkers

Where a tiny assembler and linker sit among the real ones: the first
assemblers and loaders, Unix's as and ld and their formats, the GNU
and LLVM toolchains and the fast linkers, Plan 9's split and what Go
made of it, the toolchains in one program (Wirth's Oberon, tcc), the
two machines, and the books and tutorials. What they do that ix won't,
and which of their ideas fit in a program small enough to read.
Companions: [`notes_asm.md`](../tutorials/notes_asm.md) (how it works)
and [`plan_asm.md`](../plans/plan_asm.md) (what gets built). The
lineage files are `principia/assemblers/lineage.txt` and
`principia/linkers/lineage.txt`; the dates below are from memory unless
a source is named, and are to be checked before relying on them for
teaching.

## The one-line version

| | What it optimizes for | The split |
|---|---|---|
| EDSAC's initial orders (1949), SOAP, macro assemblers | Programming in mnemonics, loading in one go | assembling at load time |
| Unix as and ld (1970s), a.out, then ELF (System V R4, 1988-89) | Separate compilation, small memory | as encodes, ld relocates |
| GNU as and ld, BFD (from the late 1980s) | Every machine, every format | the same, generalized |
| gold (2008), lld (2016), mold (2021) | Linking big programs fast | the same, parallel |
| Plan 9's 2a/5a/8a and 2l/5l/8l (1990) | Small, fast, portable compilers | the linker selects and encodes |
| Go's toolchain (2009), liblink (2013), cmd/link (2015) | Plan 9's, then link speed at scale | encoding moved back to the assembler and compiler |
| Oberon (1987), tcc (2001) | A whole system, or a whole toolchain, in one program | none, or all in one |
| `assembler/`, `linker/` (TinyAsm, TinyLd) | Seeing what an assembler and a linker do, on real programs | Plan 9's |

## Part 1: the first assemblers and loaders

- **EDSAC's initial orders** (David Wheeler, Cambridge, 1949): a loader
  in the machine's first memory that read orders written with
  mnemonic letters and decimal addresses and stored them as binary --
  an assembler run at load time. Initial Orders 2 (1950) relocated
  subroutines from a library as they were loaded: the first linking
  loader, with the "Wheeler jump" for returns.
- **Symbolic assemblers** (SOAP for the IBM 650, 1955; SAP for the
  704) and **macro assemblers** (from the late 1950s) gave names to
  addresses and to sequences of instructions; the two-pass assembler,
  one pass to learn the labels and one to encode, is from then.

## Part 2: Unix, and the relocation model

- **Unix's as and ld** (Ken Thompson and Dennis Ritchie, from 1970 on
  the PDP-7 and PDP-11): as encodes each file and records, for every
  address it can't know, a relocation; ld concatenates the files,
  assigns the final addresses and patches every relocation. The
  **a.out** format, and later **ELF** (System V Release 4, Unix System
  Laboratories), carry the code, the data and the relocations.
- **GNU as and ld** (binutils, from the late 1980s; the BFD library of
  Cygnus, early 1990s, to read and write every object format): the same
  model, generalized to every machine and every format, with linker
  scripts.
- **The Amsterdam Compiler Kit** (Andrew Tanenbaum and others, from
  the late 1970s; its linker `led`, in the lineage file): compilers for
  several languages and machines with one back end and one object
  format, the other portable toolchain of the time, and MINIX's.
- **The fast linkers**: **gold** (Ian Lance Taylor, Google, 2008:
  ELF-only, written for speed), **lld** (LLVM; its ELF linker rewritten
  from 2015-16, Rui Ueyama among others), **mold** (Rui Ueyama, 2021:
  parallel throughout). What they optimize, the time to link a very
  large C++ program, is not ix's problem, but mold's design notes are
  the best recent description of what a linker does.

## Part 3: Plan 9's split, and Go's

- **Plan 9's compilers** (Ken Thompson, "Plan 9 C Compilers", 1990):
  one compiler per machine (2c, 5c, 8c, kc, qc, vc...), with a shared
  front end, and an assembler per machine that is only a parser. The
  **linker selects and encodes the instructions**: the objects are
  instruction lists, and the linker, seeing the whole program, lays it
  out, adds the prologues, builds the literal pools, and emits the
  words. Rob Pike's "A Manual for the Plan 9 assembler" describes the
  language the compilers print, the same for every machine. Principia
  documents 5a/5l and 8a/8l; goken carries them, and 7a/7l (arm64,
  Charles Forsyth), ia/il (riscv, Richard Miller), and the others.
- **Inferno** kept the toolchain, and **Go** (2009) started from it:
  6l, 8l, 5l were Plan 9's linkers, extended for ELF, Mach-O and PE.
  Then Go moved the other way: in 2013 (Russ Cox, "Go 1.3 Linker
  Overhaul", from memory) the instruction selection moved out of the
  linker into a library (liblink) called by the compiler and the
  assembler, which now write machine code with relocations, because
  linking a large program repeated work the compiler could do once per
  package; and in 2015 the linker was rewritten in Go (cmd/link). The
  argument is about link time at Google's scale: the opposite of ix's
  concern, and a good one to state in the tutorial.
- **xix** (Yoann Padioleau): Plan 9's assemblers and linkers in OCaml,
  for arm, arm64, amd64, mips and riscv, with typed syntax trees per
  machine and marshalled objects: the twin ix is measured against.

## Part 4: the whole toolchain in one program

- **Oberon** (Niklaus Wirth and Jürg Gutknecht, from 1987; Project
  Oberon, 2013 edition): the compiler emits object files that the
  system's module loader links at load time; there is no separate
  assembler or linker, and the whole system -- compiler, loader,
  editor, file system -- is small enough for a book.
- **tcc** (Fabrice Bellard, 2001-2002): a C compiler with its own
  assembler and linker, writing ELF directly, fast enough to use as an
  interpreter (`tcc -run`). It keeps separate compilation, but not
  separate programs.
- These are the one-file variant's neighbors (the plan's "Outside the
  toolchain"): an assembler that writes the executable, with no objects.

## Part 5: the two machines

- **arm** (Acorn: Sophie Wilson and Steve Furber, ARM1, 1985): a
  condition on every instruction, a barrel shifter on the second
  operand, the PC as register 15, 8-bit rotated immediates, load and
  store multiple -- the design Plan 9's 5c/5l targets, as ARMv4-ARMv7
  (A32). Its floating point went through FPA (the coprocessor 5c still
  emits), then VFP and NEON, which the Raspberry Pi has.
- **arm64** (AArch64, announced with ARMv8-A in 2011): a new encoding,
  not an extension -- 31 registers and a zero register, conditions only
  on branches and a few selects, logical immediates as bit patterns,
  PC-relative addressing by pages. Charles Forsyth's 7c/7a/7l brought
  it to the Plan 9 toolchain.

## Part 6: the books and tutorials

- **John R. Levine, *Linkers and Loaders*** (2000): the book on the
  subject, the formats (a.out, ELF, COFF, PE), relocation, libraries,
  dynamic linking.
- **Ian Lance Taylor's "Linkers" series** (twenty blog posts, 2007-08,
  written while making gold): the clearest account of what an ELF
  linker does, and why.
- **"A Whirlwind Tutorial on Creating Really Teensy ELF Executables
  for Linux"** (Brian Raiter, late 1990s): how little Linux needs to
  run a file, down to 45 bytes; the reason TinyLd's ELF writer can be
  some 120 lines.
- **Knuth's MIXAL and MMIXAL** (*The Art of Computer Programming*,
  1968, and the MMIX fascicle, 1999): assembly languages for imaginary
  machines designed for teaching, with their assemblers; the lineage
  file's entries for teaching assemblers.
- **Nisan and Schocken, *The Elements of Computing Systems*** (nand2tetris,
  2005): the assembler chapter, for a machine designed for teaching.
- **The Principia books** on 5a/5l and 8a/8l, the literate C sources
  TinyAsm and TinyLd read beside goken's.

## What TinyAsm and TinyLd take, and leave

- **The language, at the real end**: Plan 9's assembly, what 5c and 7c
  emit over goken's libraries, checked byte for byte against goken's
  5l and 7l, and running on the machines.
- **The implementation, at the legible end**: one parser and one
  instruction type for both machines, a linker that encodes after
  layout (no relocations), and per machine a classifier and a table of
  rules, with arm64's bitmask immediates computed.

**The ceiling, stated now**: static executables only; no dynamic
linking, no debugging information, no other format than ELF; no
floating point on arm (FPA can't run, VFP is an exercise); no kernel
instructions.

## Postscript: the numbers (to come)

Once built: TinyAsm's and TinyLd's lines per module against the plan's
targets, against xix's 5,542 lines of code for 5 and 7 and goken's
32,000 of C; the corpus and the fuzzer's counts against goken; and the
programs of milestone 2 running on both machines, then on a Raspberry
Pi.
