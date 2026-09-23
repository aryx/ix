# An assembler and a linker, from scratch: a tutorial for `assembler/` and `linker/`

How a program written in assembly becomes a file Linux runs, on arm
and arm64, the Plan 9 way: an assembler that only parses, and a linker
that lays out the whole program, then chooses and encodes each
instruction, and writes the ELF file. It is written for **a reader of
TinyAsm's and TinyLd's code, not a user of an assembler**, and explains
the ideas in the order the code needs them.

It was the specification of the programs planned in
[`plan_asm.md`](../plans/plan_asm.md), written before the code, and it
is now checked against the code (2026-09-23): what the code does
differently from what was planned is said where it happens, and the
plan's Status tells why. The examples marked "checked" were run with
goken's 5a/5l and 7a/7l (the listings are `5l -a` and `7l -a`).
Companions:
[`notes_asm_related_work.md`](../related-work/notes_asm_related_work.md)
and the twins: the Principia books `assemblers/` and `linkers/`,
goken's 5a/5l and 7a/7l, and xix's `assembler/` and `linker/`.

## 0. Where the code is, and a reading order

| module | what | section |
|---|---|---|
| `assembler/Asm` | instructions and operands, the object file | §2, §4 |
| `assembler/Lexer`, `Parser` | Plan 9's assembly language, both targets | §2 |
| `linker/Link` | load, libraries, symbols, branches, `follow`, the data | §4, §5 |
| `linker/Arm` | arm: frames, classes and rules, pools, encoding | §6, §8 |
| `linker/Arm64` | arm64: the same | §7, §8 |
| `linker/Exe` | the file the kernel runs: ELF, a.out, Mach-O | §9 |
| `linker/CLI` | `tinyld`: the passes in order, per machine | §5 |
| `tiny/TinyAssembler` | the one-file variant, without separate compilation | §13 |

Read §1 for the whole trip, §2 for the language, §3 for the design,
§4-§5 for the linker, §6-§8 for the machines, §9 for the file, and
§10-§13 for how it compares, how it is tested, and what is left.

## 1. From a `.s` to a running program

The smallest program, goken's `tests/s/exit`, on arm:

```
   TEXT _start+0(SB), $20
           MOVW $42, R0          /* exit code */
           MOVW $1, R7           /* syscall number = exit */
           SWI $0                /* system call */
           RET
```

and the trip it takes (checked):

```
   5a        parses the text; writes the 5 instructions, as they are, to exit.5
   5l        reads exit.5; lays the function out at 0x80a0; adds a prologue
             and an epilogue for its frame of 20 bytes; encodes:
               000080a0  e52de018   MOVW.W  R14,-24(R13)    (prologue: push the return address)
               000080a4  e3a0002a   MOVW    $42,R0
               000080a8  e3a07001   MOVW    $1,R7
               000080ac  ef000000   SWI     $0
               000080b0  e49df018   MOVW.P  24(R13),R15     (RET: pop into the PC)
             writes an ELF32 file of 326 bytes: a header, three program
             headers, the code
   execve    maps the code at 0x80a0 and jumps there; exit(42)
```

Three things stand out already. The assembler did nothing to the
instructions: the numbers are the linker's. The linker wrote code that
was not in the source, a prologue and an epilogue, because only it
knows the frame. And the program is a function called `_start`, with
nothing before it: the ELF header's entry point is its address.

## 2. Plan 9's assembly language: one syntax for every machine

Plan 9 has one assembly language for all its machines, and the
compilers print it (`5c -S`):

```
   TEXT  strchr(SB), $8           a function, and the size of its frame
   MOVW  c+4(FP), R6              an argument: 4 bytes into the caller's frame
   MOVW  R0, s-4(SP)              a local: 4 bytes below this frame's top
   MOVW  $table(SB), R1           an address: table, from the static base
   CMP   $0, R6                   source first, then destination
   BNE   2(PC)                    a branch: two instructions on
   MOVW.EQ R1, R2                 a condition, as a suffix (arm)
   ADD   R1<<2, R2, R3            a shifted operand (arm)
   DATA  msg+0(SB)/8, $"Hello, w" 8 bytes of initialized data
   GLOBL msg(SB), $14             msg is 14 bytes
```

**Four pseudo-registers** are not registers but reference points:
`SB`, the static base, for global names; `FP`, the frame pointer, for
arguments (`c+4(FP)`: the name is a comment, the number matters); `SP`,
for locals; `PC`, for branches counted in instructions. The linker
turns each into a real register and an offset, per machine.

**The same text, arm64** (checked, goken's exit program):

```
   TEXT _start(SB), $0
       MOV    $42, R0
       MOV    $93, R8           // the syscall number: exit, on arm64
       SVC    $0
```

What differs is the opcodes (`MOV` and `MOVW` for 64 and 32 bits,
`SVC` for `SWI`), the registers (`R0`-`R30`, `RSP`, `ZR`), and a few
operands (arm's shifts, arm's register lists). So TinyAsm has **one
parser and one instruction type** for both, and a table of register
names per machine; which instructions exist, and with which operands,
is the linker's business (§3).

## 3. Why the linker encodes: Plan 9's split

In a Unix toolchain the assembler encodes, and leaves holes: an address
not yet known becomes a relocation record, which the linker patches. In
Plan 9 the assembler only parses; the object file is the instruction
list, and the linker, which sees the whole program, encodes it. Four
consequences, and they are why ix keeps this design:

```
   Unix:    as:  text -> words + relocations      ld: relocations -> patched words
   Plan 9:  5a:  text -> instructions             5l: layout -> words (no holes)
```

- **No relocations**, in objects or in the linker: when the linker
  encodes `BL strchr(SB)`, it already knows where `strchr` is.
- **One encoder per machine**, shared by the assembler's path and the
  compiler's: 5c writes instructions straight into the object, as 5a
  does, and never prints assembly unless asked (`-S`).
- **Choices made with everything known**: how to reach an address
  (near, or through a literal pool), how to build a large constant,
  what a function's prologue is (§5).
- **The machine is in one place**: the assembler is nearly the same for
  both targets, and the linker's machine part is one module each.

The cost: an object is not machine code, so it can't be disassembled,
only listed; and the linker is the bigger program, and does the same
work again at every link. That last cost is why Go, which started from
this toolchain, moved the encoding back into the compiler and the
assembler in 2013: Google's programs are large, and linked often. For
ix, whose programs are small, the smaller design wins.

## 4. Objects, libraries, and symbols

An object is the marshalled instruction list of one `.s` file, with
its machine and name. A library is a list of objects and the symbols
each defines. Linking starts from the entry symbol, and takes the
objects that define what is still undefined, until nothing is:

```
   hello.5   defines main; uses print, exits
   libc.a    print.5 (defines print; uses vfprint...), exits.5, ...
   linked:   hello.5, print.5, vfprint.5, ..., exits.5 -- not all of libc
```

On arm there is one more: 5c writes `DIV` and `MOD` as instructions,
and arm has no divide instruction, so the linker turns them into calls
to libc's `_div`, `_divu`, `_mod` and `_modu`, and adds those symbols
to what is needed.

**Which objects, in which order**, decides the addresses, and so the
bytes (checked, by making ix's executables goken's):

- the entry is the first name needed, before any object is read;
- a library's index lists its objects last first (ar builds it by
  prepending), and a pass takes, in that order, each object defining a
  name still undefined, until a pass adds nothing;
- a text name defined by two objects is indexed for the first only
  (libc has two `strtod`: fmt's is the one);
- `_div` and the others are asked for only once all the loading is
  done, so they come last;
- `n+4(FP)` and `x-8(SP)` name no symbol: the name is a comment.

## 5. The linker's passes

```
   load       objects and libraries, as in §4                     Link
   prepare    per machine: B.NE is BNE, frames rounded, float     Arm, Arm64
              constants into the data, ADD of a negative is SUB
   resolve    branches to their targets, chains of B followed     Link
   data       an offset for every datum: small ones first, in     Link
              the linker's hash order, then the rest, then bss
   follow     the code in the order its flow goes (below)         Link
   rewrite    per machine: prologues, RET, DIV and MOD            Arm, Arm64
   layout     an address for every instruction, literal pools     Arm, Arm64
   encode     per machine: instructions to words                  Arm, Arm64
   write      the file                                            Exe
```

**follow** (5l's and 7l's `xfol`, which the plan had left out, and
which every program with a loop needs to match goken) walks the code
from the first function in the order it runs: a branch to code already
placed becomes a copy of it, when that code is short and ends the flow
(a `B` or a `RET` within four instructions), else a `B` to it; a
conditional branch whose target comes next is inverted; and what the
flow never reaches, code after a `RET`, is dropped. It builds the new
order in the instructions' own links, so once an instruction is placed
its next is what was placed after it, not what followed it in the
source.

**The frame.** `TEXT f(SB), $20` says that `f`'s locals take 20 bytes.
The linker makes the frame, on arm with one instruction: the prologue
pushes the return address (R14) and makes room for the locals at once
(`MOVW.W R14, -24(R13)`: 20 bytes and 4 for R14), and `RET` becomes the
pop into the PC (`MOVW.P 24(R13), R15`) -- both checked in §1, where the
function calls nothing and still gets them, because it has locals. Only
a leaf function (no `BL`) with no locals (`$0`, or `$-4`) keeps R14
where it is, and returns with `B (R14)` (5l's `noops`); so does any
function that says `$-4`, even one that calls. `FP` and `SP` are then
offsets from R13. On arm64 (7l's `noops`) the frame is rounded to 16
bytes, with R30 at its bottom, pushed by a pre-indexed store of at most
240 bytes (`MOV R30, -x(RSP)!`, after a `SUB` for the rest), and
`RETURN` undoes it.

**Layout.** Code starts at 0x80a0 on arm and 0x4000f0 on arm64 (5l's
and 7l's choice: an address, plus the ELF header's size). Every
instruction is 4 bytes, so addresses follow from the order, but for
what the linker adds: literal pools (§6) and constants that take more
than one instruction (§7). Data goes after the code, rounded to a page
(4096), initialized data first, then the zeroed part (bss), which the
file does not contain.

## 6. Encoding arm

Every arm instruction is one 32-bit word, and most start the same way:

```
   31    28 27                                                     0
   | cond  |              the rest, by kind of instruction            |
     1110 = always (AL), 0000 = EQ, 0001 = NE, ...
```

which is why a condition on any instruction costs nothing. Three kinds
cover most of the subset (the counts are in the plan):

```
   data processing   cond 00 I opcode S Rn Rd operand2       MOVW $42,R0 = e3a0002a
   load / store      cond 01 I P U B W L Rn Rd offset12      MOVW 24(R13),R15 ...
   branch            cond 101 L offset24                     B, BL
```

`e3a0002a`, decoded (checked): `1110` always, `00`, `I=1` (an
immediate), `1101` (MOV), `S=0`, `Rn=0`, `Rd=0`, and `0x02a`: 42.

**Immediates are 8 bits, rotated.** An operand2 immediate is an 8-bit
value rotated right by twice a 4-bit amount: 42 and 0xff000000 fit,
0x101 doesn't. For a constant that doesn't, the linker puts it in a
**literal pool**, a word after the function, and loads it relative to
the PC; so does an address (`MOVW $table(SB), R1`), and so does data
out of reach. Data in reach is loaded relative to R12, which the
start-up code sets to the data segment plus 4,092 (5l's `setR12` and
`BIG`): a load or store with a 12-bit offset reaches 4 KB either side.

**Choosing the encoding** is 5l's `oplook`: each operand gets a class
(a register; a constant that rotates, whose complement does, or
neither; an offset of 12 bits, or 8 for halves, or more...), and the
first of the rules for the opcode whose classes take the operands' is
the one. The rules are sorted as 5l sorts its optab, so the first is
5l's first. goken computes `immrot` in a 64-bit `ulong`, where the
rotation never wraps: only 0 to 255 rotate there, and `$0x400` goes to
a pool. TinyLd does the same (checked), with a flag for the real rule.

**Literal pools** go after an unconditional branch or a return, when
the pool's first use is getting far (5l's `checkpool`), or at the end,
behind a `B` to itself; one word serves every use of the same operand.

**What the subset keeps**, and 5l's optab has 204 rows for: the data
processing instructions with a register, a shifted register or an
immediate; loads and stores of words, bytes and halves, with an offset
or an index, pre- or post-indexed; load and store multiple (`MOVM`);
branches; `SWI`; multiply; and FPA's floating point. That last one was
planned out, since no machine at hand runs FPA; but libc's `print`
links `fltfmt` and `strtod`, so every program with a `print` has float
code, even where it never runs, and the encoding is needed to link it.

## 7. Encoding arm64

Also one 32-bit word, and there the resemblance ends:

```
   MOV $42, R0  = d2800540   MOVZ: sf=1 opc=10 100101 hw=00 imm16=42 Rd=0   (checked)
   SVC $0       = d4000001
```

- **31 registers, and number 31 is two**: the zero register in most
  instructions, the stack pointer in some (loads, `ADD` with an
  immediate). The encoder knows which.
- **Few conditions**: `B.cond`, `CSEL` and a few others; no
  condition field in general.
- **Constants**: 16 bits at a time, `MOVZ` then `MOVK` for each other
  non-zero 16-bit piece (up to four), or `MOVN` for mostly-ones; or a
  literal pool (7l does both; checked, `MOV $12, R0` in the exit
  program became a pool load, `58000060`).
- **Bitmask immediates**: `AND`, `ORR`, `EOR` take a constant that is
  a repeated element (2, 4, ..., 64 bits) made of a rotated run of
  ones. 7l keeps a table of them, 5,334 entries in `bits.c`; TinyLd
  makes the same table by enumerating the element sizes, the runs and
  the rotations, in 15 lines. 7l's encoding leaves out the element's
  size below 64 bits (a known 7l bug), and so, to match it, does TinyLd.
- **The literal pool** is one, at the end of the program, with 8-byte
  words for `MOV`; and there are no float immediates in 7l: every
  `FMOVD $c` loads from a symbol in the data.
- **Addresses**: PC-relative, `ADR` (±1 MB) or `ADRP` and `ADD` (a
  page, then the offset in it), or a pool.

The subset is what 7c emits (69 opcodes), floating point included.

## 8. The two machines, and what is general

What the two encoders share is their shape, not their code: a
classifier from operands to classes, a table from (opcode, classes) to
a rule, sorted, the first match, and the encoding by rule. Each is one
module, of about 590 lines. What the second machine moved into `Link`
is what turned out to be the same in 5l and 7l: `follow`, given what
ends the flow and how to invert a branch; the float constants made
data; and the data's layout and the hash that orders it, with a case
per machine where 5l and 7l differ (7l hashes in 32 bits and aligns
to 8 and 16). The general part never looks inside an instruction.

## 9. The ELF file

What Linux needs to run a static program is little (checked on the
exit programs: 326 bytes for ELF32, 486 for ELF64):

```
   ELF header         magic, class (32 or 64), machine (ARM or AArch64),
                      entry address, where the program headers are
   program headers    one PT_LOAD for the code (read, execute), one for the
                      data (read, write; its memory size includes bss),
                      and 5l and 7l's third, for the Plan 9 symbols
   the code, the data
```

arm needs one more thing: `e_flags` must say EABI version 5
(`0x5000200`), or the kernel refuses the file. No section headers are
needed to run. 5l writes three anyway, at HEADR+text+data, which is
inside the data's page: when the data is large the table overwrites its
end, a goken bug that breaks its own `dirread` (checked: patched with
ix's bytes, it passes). TinyLd puts the table after the data.

**Plan 9's a.out** is simpler still: 32 bytes, eight big-endian words
-- the magic (`0x647` on arm), the sizes of the text, the data, the bss
and the symbols, the entry, and two more sizes -- then the text and the
data (checked on goken's `hello_plan9_arm.exe`, which goken's 5i runs
here).

**Mach-O on arm64** (for macOS) is the most demanding, and every
demand is enforced by a silent kill at exec (goken's
`notes_exec_macho.txt`):

```
   header          magic, CPU arm64, flags: PIE and "dyld links me"
   load commands   __PAGEZERO (4 GB of nothing), __TEXT (at 0x100000000,
                   the header included), __DATA, __LINKEDIT (last), the
                   rebase stream for dyld, LC_MAIN (the entry, as a file
                   offset), dyld's path, libSystem's name, empty symbol
                   tables, and room for the signature
```

The program must be position independent, because the kernel loads it
at a random slide: an address is built at run time with `ADRP` and
`ADD`, never taken from a pool; and a pointer in initialized data is
listed, for dyld to add the slide. Pages are 16 KB. And the file must
be signed: `codesign -s -`, on the Mac, adds an ad-hoc signature at the
end of `__LINKEDIT`. The program names dyld and libSystem only because
the kernel insists; it makes its system calls itself (number in R16,
`SVC $0x80`).

## 10. Compared with goken and xix

| | goken (C) | xix (OCaml) | TinyAsm and TinyLd |
|---|---|---|---|
| assembler | a grammar per machine (yacc) | a grammar and a typed AST per machine | one parser, one instruction type |
| objects | Plan 9's format | marshalled | marshalled |
| encoding | optab and asmout per machine | pattern matching, all forms | pattern matching, the subset |
| arm64 bitmask immediates | a table (5,334 entries) | 64-bit patterns only | generated |
| `follow` | yes | no | yes (in `Link`, for both) |
| formats | ELF, Mach-O, PE, a.out | ELF, a.out | ELF, Mach-O (arm64), a.out |
| lines of code, 5 and 7 | about 32,000 | 5,542 | 2,301 (the plan's target was 2,090) |

## 11. How it is tested

- **The recorded bytes** (`linker/tests/golden.sh`, in `make test`):
  62 small `.s` programs, goken's and xix's, for arm, arm64, Mach-O and
  a.out, each with the digest of the executable goken made.
- **A fuzzer** (`linker/tests/fuzz.py`): random programs of the
  subset through goken and through ix; the executables must be the
  same. It found two bugs the corpus hadn't: the rounding of a
  negative frame, and which literal pool words are shared.
- **Real programs** (`linker/tests/libc.sh 5|7`): goken's libc through
  `5c -S` or `7c -S` and TinyAsm, and goken's 17 `hello_libc` programs
  linked with it, byte for byte against goken's, and run.
  `fixtures.sh` compares any `.s` against goken, and `elfcmp.py`
  compares two executables but for goken's misplaced section table.

## 12. Exercises

- **VFP**, for floating point on arm: the Raspberry Pi has it, and 5c
  doesn't emit it.
- **Another machine**: riscv64, or mips, as a third module next to
  `Arm` and `Arm64`, and what that shows in the general part.
- **The rest of arm64**: CSEL, TBZ, the atomics and the barriers, which
  7c doesn't emit; and 7l's correct bitmask encoding, as an option.
- **The real immrot**, `Arm.rotate`, made the default once goken is
  fixed, and the section table's place fixed in goken.

## 13. In ix

TinyAsm and TinyLd are the first half of ix's toolchain; the C compiler
comes next, and writes their objects directly.

The one-file variant, `tiny/TinyAssembler.ml`, asks what is left
without separate compilation: an assembler for arm64 that reads all of
a program's assembly, its own and libc's, and writes the executable.
Dropping the byte identity with 7l lets it choose forms whose sizes
never depend on an address: a constant built by `MOVZ` and `MOVK`, an
address by `ADRP` and `ADD`, a logical immediate in a register. So
there is no literal pool and no bitmask encoder, and it takes three
plain passes: expand, lay out, encode. The expansion makes each
instruction a list of closures from their own pc to a word, run once
the addresses are known. A library becomes the functions reachable from
the entry. It is 410 lines of code, against about 1,580 for the same
arm64 path through TinyAsm and TinyLd, and it runs goken's 17
`hello_libc` programs with all of libc, including the two that goken's
own executables get wrong.

## Glossary

- **SB, FP, SP, PC**: Plan 9's pseudo-registers (§2).
- **Frame**: a function's locals, and the saved return address (§5).
- **Literal pool**: constants after a function, loaded PC-relative (§6).
- **Leaf function**: one that calls no other (§5).
- **Bitmask immediate**: arm64's repeated-pattern constants (§7).

## References

- Rob Pike, "A Manual for the Plan 9 assembler".
- Ken Thompson, "Plan 9 C Compilers", 1990.
- John R. Levine, *Linkers and Loaders*, 2000.
- ARM Architecture Reference Manual (ARMv7-A: A32), and for A-profile
  (A64).
- System V ABI, and its ARM and AArch64 ELF supplements.
