# A C compiler, from scratch: a tutorial for `compiler/`

How a C file becomes the instructions that TinyLd links, on arm and
arm64, the Plan 9 way: a front end that reads C into a typed tree, and
one code generator that walks the tree and writes Plan 9's
instructions, asking a record of the machine only what the machine
decides. It is written for **a reader of TinyCompiler's code, not a
user of a C compiler**, and explains the ideas in the order the code
needs them.

It is the specification of the program planned in
[`plan_cc.md`](../plans/plan_cc.md), written before the code, to be
checked against it, as the other tutorials were; it was checked on
2026-09-24, and where the two differed the text now says what the code
does. The listings marked "checked" are goken's `5c -O0 -S` and `7c
-O0 -S`, on 2026-09-23.
Companions:
[`notes_cc_related_work.md`](../related-work/notes_cc_related_work.md),
[`notes_asm.md`](notes_asm.md) (the toolchain's first half, which this
one writes for), and the twins: the Principia book `compilers/`,
goken's 5c and 7c, and xix's `compiler/`.

## 0. Where the code is, and a reading order

| module | what | section |
|---|---|---|
| `compiler/Tree` | the types, the tree, the symbols | §3, §4 |
| `compiler/Pre` | the preprocessor | §3 |
| `compiler/Lexer`, `Parser` (ocamlyacc) | C into a tree | §3 |
| `compiler/Declare` | declarations, scopes, frames, initializers | §3, §7 |
| `compiler/Check` | types, and the tree made explicit | §4 |
| `compiler/Gen` | code from the tree | §4, §5, §6, §7 |
| `compiler/Multiply` | a multiplication by a constant | §5 |
| `compiler/Arm`, `Arm64` | what each machine decides | §8 |
| `compiler/Emit`, `CLI` | the instructions, `-S`, the objects, `tinycc` | §9 |

Each module's `.mli` says what it does and where it departs from 5c
and 7c, with the papers it follows; read Tree's first, then in the
order of the table.

## 1. From a `.c` to a running program

A function, and what 5c makes of it at `-O0` (checked):

```
   int                             TEXT  sum+0(SB),0,$8        a frame of 8 bytes: i and s
   sum(int *a, int n)              MOVW  R0,a+0(FP)            the first argument came in R0
   {                               MOVW  $0,R2
       int i, s;                   MOVW  R2,s-8(SP)            s = 0
                                   MOVW  $0,R3
       s = 0;                      MOVW  R3,i-4(SP)            i = 0
       for(i = 0; i < n; i++)      B     6(PC)                 to the test
           s += a[i];              B     2(PC)                 (continue: to the increment)
       return s;                   B     17(PC)                (break: after the loop)
   }                               MOVW  i-4(SP),R4            i++
                                   ADD   $1,R4
                                   MOVW  R4,i-4(SP)
                                   MOVW  i-4(SP),R2            the test: i < n, or leave
                                   MOVW  n+4(FP),R4
                                   CMP   R4,R2
                                   BGE   -7(PC)
                                   MOVW  i-4(SP),R1            s += a[i]
                                   SLL   $2,R1
                                   MOVW  a+0(FP),R5
                                   ADD   R5,R1
                                   MOVW  0(R1),R1
                                   MOVW  s-8(SP),R3
                                   ADD   R1,R3
                                   MOVW  R3,s-8(SP)
                                   B     -17(PC)               again
                                   MOVW  s-8(SP),R0            the result in R0
                                   RET
```

and the trip:

```
   tinycc     preprocesses, parses, types the tree, makes it explicit,
              generates the instructions above, writes sum.5 (TinyAsm's object)
   tinyld     lays out and encodes (the frame's prologue, RET's epilogue,
              the branches), writes the executable
```

What stands out: every variable lives in its stack slot, and each
statement loads what it needs and stores what it made (this is `-O0`;
5c's registerizer would keep `i` and `s` in registers). The compiler
never computes an address or a frame: `s-8(SP)`, `n+4(FP)` and `6(PC)`
are for the linker. And the dead branches at the loop's top (`B
2(PC)`, `B 17(PC)`) are the targets that `continue` and `break` jump
to; the linker's `follow` removes what never runs.

## 2. Plan 9's C

The corpus is C89 with Plan 9's habits (the plan counts them):

- **`u.h`'s types**: `uchar`, `ushort`, `uint`, `ulong`, `vlong`
  (`long long`), `uvlong`, defined per machine; `nil` for a null
  pointer; `USED(x)` to say a variable is used.
- **Headers without guards**, included once by convention, `u.h` first,
  then `libc.h`.
- **No `#if`**: `#ifdef`, `#ifndef`, `#else`, `#endif` only; macros
  with arguments (152 of them), `#pragma varargck` for `print`'s
  formats (which TinyCompiler reads and ignores).
- **No bitfields, no designated initializers**; Plan 9's unnamed
  structure members, at most once.

## 3. The front end: characters, tokens, a tree

**The preprocessor** replaces `#include` by the file (from `-I` for
`<...>`, and the including file's directory for `"..."`), and a macro
by its body, its arguments substituted and the result rescanned.

**The lexer** needs one thing from the parser, C's famous one: whether
a name is a typedef. `T * x;` declares `x` when `T` is a type, and
multiplies otherwise; so the lexer looks the name up in the symbol
table, which the parser fills as it declares, and hands back a
type-name token for a typedef's.

**The parser** reads declarations with C's declarators, the part of C
where the syntax is inside out: `int (*f[4])(char*)` is an array of four
pointers to functions from `char*` to `int`, read from the name
outwards. It makes a tree whose nodes are 5c's: an operator (`OADD`,
`OIND` for `*p`, `ODOT`, `OFUNC` for a call...), a left and a right,
and a type.

## 4. Types, and the tree made explicit

**Typechecking** gives every node a type, and makes C's implicit rules
explicit nodes: the conversions (`char` to `int` in arithmetic, `int`
to `long`, a pointer and an integer), a pointer plus an integer scaled
by the pointee's size, an array into a pointer to its first element.
Constant expressions are folded.

**Two numbers per node**, which the code generator lives by (5c's
`sgen.c`):

- **addable**: how the node can be an operand as it is: a constant, a
  name (`x(SB)`), a stack slot (`x-8(SP)`), an address in a register
  plus an offset. A node that is addable needs no instruction to be
  used.
- **complex**: how many registers the node needs to be computed
  (Sethi and Ullman's number): 0 for addable, and for `a op b` the
  larger of the two sides', plus one when they are equal. The code
  generator computes the more complex side first, so that the other
  never holds a register while it waits.

**64-bit arithmetic on arm** is rewritten as the tree is labelled
(Gen's `xcom`, with 5c's `com64.c`): arm
has 32-bit registers, so a `vlong` sum is a call (checked):

```
   vlong add(vlong a, vlong b)      5c: TEXT add(SB),$20
   { return a + b; }                    MOVW R0,.ret+0(FP)     the result: through a pointer
                                        ... a and b copied to the outgoing slots
                                        BL   _addv(SB)         libc's vlrt.c
                                    7c: MOV  a+0(FP),R0
                                        MOV  b+8(FP),R4
                                        ADD  R4,R0             one instruction
```

## 5. Code from a tree

**`cgen(n, dest)`** generates code that leaves the value of `n` in
`dest` (a register or an addressable node), or nowhere for a statement.
Registers are taken with `regalloc` and given back with `regfree`, per
expression: at `-O0` nothing survives a statement in a register. The
shape, for `l op r`:

```
   if r is more complex than l:      r into a register first, then l
   if r is a constant or addable:    l into dest, then  op r, dest
   else:                             l into dest, r into a register, op reg, dest
```

**Conditions** (`boolgen`) generate jumps, not values: `a < b && c`
branches away on the first false part, and `if` and `while` use the
jumps directly; a condition's value is made only when it is stored.

**Structures** are copied by `sugen`: on arm with `MOVM` (a load and a
store multiple), on arm64 word by word (checked, `mid` in §8). A
function that returns a structure gets a hidden pointer, in R0, where
it writes the result (`.ret+0(FP)`).

## 6. Statements, and switches

**`gen(stmt)`** (5c's `pgen.c`): a statement is code with a place to
go on `break` and `continue`, the loop's layout being §1's. `goto` and
labels are the same branches, patched when the label is seen.

**A switch** (5c's `swt.c`) is one of three shapes, by its cases
(checked):

- at least 3 cases whose range is less than twice their number: **a
  table**, `CASE` and one `BCASE` per value, bounds checked first (on
  arm `CASE.LS`, conditional; on arm64 `BHI` to the default, then
  `CASE`);
- fewer than 5 cases: **a chain** of comparisons;
- otherwise **a binary search**, halving the sorted cases.

## 7. Calls and frames

The first argument is passed in R0 (the callee stores it in its slot,
`MOVW R0,a+0(FP)`), the others on the stack, where the caller writes
them into its outgoing area (`MOVW R1,8(R13)`), and the result comes
back in R0. The frame (`TEXT f(SB),$8`) is the locals' size: the
compiler adds up the locals and the largest outgoing area, and the
linker writes the prologue and the epilogue from it (notes_asm.md
§5).

## 8. The two machines: one generator, two records

The same functions from 7c (checked), against §1's and §4's:

```
   sum (7c)                          what the record said
   MOV   R0,a+0(FP)                  a pointer is 8 bytes: MOV, and n is at +8
   MOVW  $0,s-8(SP)                  a zero is stored from the zero register
   ...
   MOVW  i-4(SP),R4
   SXTW  R4,R4                       an int index widened to a pointer's size
   LSL   $2,R4
   MOV   a+0(FP),R5
   ADDW  R4,R3,R4                    32-bit arithmetic is the W form
   RETURN                            7l's pseudo-return

   mid (a structure returned)
   5c:  MOVM.U 0(R5),[R1,R2]         7c:  MOVW 0(R1),R2
        MOVM.U [R1,R2],0(R3)              MOVW 4(R1),R3
                                          MOVW R2,0(R4)
                                          MOVW R3,4(R4)
```

What the record holds, then (goken's `txt.c` and `gc.h` per machine):

- the sizes of the types, and the pointer's; the alignment;
- the registers: which may hold a value, which is the result's (R0),
  the zero register if any;
- **the instruction for an operator on a type** (5c's `gopcode`: `ADD`
  on arm; `ADD` or `ADDW` on arm64, by width) and **for a move between
  two types** (`gmove`: the widenings and narrowings, `SXTW`, `MOVBU`,
  the float conversions);
- how a structure is copied, and how a switch's table is entered;
- what is a call rather than an instruction: `vlong` arithmetic on
  arm.

The code generator has none of these decisions, and that is the claim
the second machine checks (plan_cc.md, decision 1).

## 9. The objects

The compiler writes TinyAsm's objects (`Asm.obj`): the instructions,
the `TEXT`s, and the data as `DATA` and `GLOBL` (a string literal is a
static `.string<>` symbol, 8 bytes per `DATA`, as §1's listings show).
`-S` prints the same instructions in Plan 9's syntax, which TinyAsm
reads back into the same object. So TinyLd links a compiled file and
an assembled one alike, and a `.s` written by hand (libc's `rt0.s`)
sits beside the compiled ones.

## 10. Compared with goken and xix

| | goken (C) | xix (OCaml) | TinyCompiler |
|---|---|---|---|
| front end | yacc, 7,900 lines | ocamlyacc, typechecker complete | ocamlyacc; the preprocessor and lexer by hand |
| back ends | one per machine, 3,600 to 3,900 lines each, plus 2,700 of optimizer | one, arm, mostly unwritten | one, with a record per machine |
| objects | Plan 9's | xix's | TinyAsm's |
| optimizer | registers, peephole | none | none (`-O0`) |
| lines | about 22,000 (16,700 without the optimizers) | 5,553 | 5,328 (the target was 3,500) |

## 11. How it is tested

- **The listings**, function by function against `5c -O0 -S` and `7c
  -O0 -S`, over the corpus.
- **The executables**: goken's libc and programs, compiled and linked
  by ix only, against goken's, byte for byte, and run.
- **A fuzzer**: random C of the subset through both compilers.

## 12. Exercises

- **Registers**: 5c's `reg.c`, variables into registers by a dataflow
  analysis, at last `-O2`; and its peephole.
- **Bitfields**, and `#if`.
- **A third machine** (riscv64): a third record, and TinyLd's third
  module.
- **An intermediate language**, the other answer to the plan's
  question: the one-file variant's.

## 13. In ix

TinyCompiler finishes ix's toolchain: C to objects, objects to
executables, all in OCaml, byte for byte with goken's. The kernel and
the emulator come next; the compiler builds their C parts.

## Glossary

- **addable, complex**: a node's two numbers (§4).
- **Sethi-Ullman number**: registers needed to compute an expression
  (§4).
- **boolgen**: generating a condition as jumps (§5).
- **the record**: what a machine decides for the code generator (§8).

## References

- Ken Thompson, "Plan 9 C Compilers", 1990; and "A New C Compiler",
  1990.
- Brian Kernighan and Dennis Ritchie, *The C Programming Language*,
  2nd edition, 1988.
- Ravi Sethi and Jeffrey Ullman, "The Generation of Optimal Code for
  Arithmetic Expressions", *JACM*, 1970.
- Christopher Fraser and David Hanson, *A Retargetable C Compiler:
  Design and Implementation* (lcc), 1995.
- The Principia Softwarica book `compilers/` (5c).
