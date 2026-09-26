# Plan: mini-ml, an ML compiler from scratch, for arm and arm64 (`languages/ml/`)

Companions:
[`notes_ml.md`](../tutorials/notes_ml.md), the tutorial: from a `.ml`
to a running program, values at run time, the front end, names and
modules, types, pattern matching, closures, the code, the runtime and
its collector, and the kernel. And
[`notes_ml_related_work.md`](../related-work/notes_ml_related_work.md):
from LCF's ML to Cardelli's compiler, SML/NJ, Caml, Caml Light and
OCaml, MLton, CakeML, the small ones (MinCaml, camlboot), and the
papers on types, matching, closures and collectors. The twin is
ocaml-light (`~/ocaml-light`, OCaml 1.07 without objects and functors),
its native compiler `ocamlopt` for arm and arm64.

An ix program, and the toolchain's second client after
mini-cc: it writes the objects that mini-ld links. Planned as the
others were; the principles are in [`../README.md`](../README.md). The
question that opened it (the author): "how hard would it be to create
a mini-ml, a mini compiler for ocaml(light)?", then, on the answer:
"compiling mini-9pi is indeed the great target. But as opposed to the
other, no need to match byte per byte the existing ocaml-light, even at
the -dlambda level. I agree we should skip the bytecode and try to
reuse some mini-cc backend maybe to reduce the code."

## Context

An ML compiler turns a `.ml` file into instructions, like a C
compiler, but three things C doesn't have change its shape:

- **Types are inferred, not declared.** The compiler finds the type of
  every expression (Hindley-Milner), so the programmer writes almost
  none, and a well-typed program cannot crash on a wrong value.
- **Functions are values.** A function can be built at run time,
  capture variables, be passed and returned: a *closure*, code and an
  environment, allocated.
- **Memory is managed.** Lists, tuples, variants, records and closures
  are allocated all the time and never freed by hand: a garbage
  collector must find, at any allocation, every value the program can
  still reach. That makes the runtime part of the compiler's design:
  the code must leave its values where the collector can find them.

ocaml-light's native compiler does all this in about 11,500 lines of
OCaml (normalized; below) and a runtime of about 5,900 lines of C, plus
440 of arm assembly. Its back end is a real optimizing one
(instruction selection, liveness, graph coloring, spilling), for eight
machines.

Why this program now:

- **Its toolchain is done.** mini-asm's instruction type is what the
  compiler writes, mini-ld encodes and links it, for arm and arm64, into
  ELF, Plan 9 a.out and Mach-O; mini-cc compiles the runtime's C. The
  compiler adds no format and no new machinery.
- **References run today** (checked, 2026-09-26): ocaml-light's
  cross-compilers, which `kernel/ocaml-light.sh` builds for the
  kernels, compile a test program for arm (run under `qemu-arm`) and
  for arm64 (run natively), and print the same result (and
  `max_int`: 1073741823 on arm, 4611686018427387903 on arm64).
- **The corpus is there, and it is ix's own**: mini-9pi (6,246 lines of
  OCaml in `kernel/9pi/` and `kernel/lib/`), the parts of ocaml-light's
  stdlib it uses, and ocaml-light's `test/` (41 files, 35 without a float
  or a functor).
- **The target is the best one ix has**: mini-9pi, today compiled by
  ocaml-light, compiled by mini-ml, booting principia's SD card to rc
  with the same console session. An OCaml kernel compiled by an OCaml
  compiler of ix's own, which then runs ML programs compiled by the same
  compiler.

## Principles

Those of [`../README.md`](../README.md), and five of its own:

- **The behavior is the contract, not the code** (the author,
  2026-09-26). Unlike mini-cc against 5c, nothing is compared byte for
  byte, not the instructions, not ocaml-light's `-dlambda`: a program
  compiled by mini-ml must print what it prints compiled by
  ocaml-light's `ocamlopt` (its output, its exit status, an uncaught
  exception's message), on arm and arm64; and mini-9pi compiled by
  mini-ml must give its recorded sessions (`kernel/9pi/tests/`). So
  every internal choice is free, and is made for size and clarity.
- **The input is the OCaml the corpus is written in**, counted (below):
  ocaml-light's dialect, what mini-9pi uses first. A construct outside
  it is an error, named.
- **Types are checked, then forgotten.** One representation for every
  value (a word: a tagged integer or a pointer to a block), so the code
  generator never needs a type (decision 4). The type checker is a pass
  whose output nothing after it reads: it can be built second, and
  switched off.
- **The toolchain's second client.** mini-ml writes mini-asm's objects
  and leaves to mini-ld what it does for mini-cc: frames, literal pools,
  large constants, branches, division on arm, the executable's format
  (decision 6).
- **No assembly in the runtime.** The runtime is C, compiled by mini-cc
  (or gcc, for the kernel until decision 8's route is done); what
  ocaml-light writes in assembly (the calls between C and OCaml, the
  exceptions, the collector's entry) is generated code or C, which the
  value stack makes possible (decision 5).

## The subset, counted

Counted with `languages/ml/tests/count_ml.py` over mini-9pi (`kernel/9pi`,
`kernel/lib`: 61 files, 6,246 lines, the `.mli`s included), and for
comparison over ocaml-light's stdlib (79 files, 10,074 lines) and its
`test/` (46 files, 7,287 lines). Tokens with the comments and strings
removed, not a parse: the counts are close, not exact (`|` counts a
match's cases and a type's constructors).

| construct | mini-9pi | kept |
|---|---:|---|
| `let` (`let rec` 55), `in`, `fun` 194, `function` 11 | 1,149 | yes |
| `match` 182, `|` 670, `when` 21, `as` 2 | | yes |
| `if`/`then`/`else`, `begin`/`end`, sequences | 501 | yes |
| `raise` 222, `try` 74, `exception` 2 | | yes |
| records `{` 166, `mutable` 144, `<-` 193 | | yes |
| `ref` 67, `!` 173, `:=` 67 | | yes (the stdlib's, a record) |
| arrays `.(` 126, strings `.[` 52 (strings mutable, 1.07's) | | yes |
| `land lor lxor lsl lsr asr lnot` | 389 | yes |
| `for` 19, `while` 4 | | yes |
| `type` 74, `of` 66, `and` 101 | | yes |
| `external` (C primitives) | 81 | yes |
| `open` 38; `module` 8 (3 `struct`s, 2 aliases); `sig` 3 | | yes, as static names (decision 3) |
| float literals and operators | 0 | later (phase 7): 5 of `test/`'s 41 files use them |
| functors, first-class modules, objects, classes | 0 | no (ocaml-light has none: 2 uses in `test/`, `sets.ml`'s `Set.Make`) |
| labeled and optional arguments, polymorphic variants | 0 | no |
| `lazy`, `assert` | 0 | no |

The stdlib it calls (`Printf.sprintf` 26, `String.*` 267, `List.*` 112,
`Buffer.*` 70, `Char.*` 47, `Array.*` 27, `Hashtbl.*` 14, `Callback.
register` 4, `Printexc.to_string` 1, `Random.int` 1) is ocaml-light's
own `.ml`, compiled by mini-ml: pervasives, list, string, char, array,
buffer, printf, hashtbl, callback, printexc, random, obj, 2,105 lines.
Their `external`s name 56 of the compiler's primitives (`%addint`,
`%field0`...) and 62 C functions, of which the 23 on floats wait for
phase 7. `Printf`'s formats: `%d %s %x %c`, with widths and `0`
(`%02x`, `%-6s`, `%11d`); ocaml-light's printf reads the format at run
time, so it needs the type checker only to be safe, not to run.

So: ocaml-light's core language and its modules without functors, no
floats at first. What ocaml-light has beyond it and mini-ml leaves
out: floats until phase 7 (and flat float arrays, ever: decision 4),
the toplevel, the bytecode compiler and its interpreter, the debugger,
marshalling (`output_value`), `Lexing` and `Parsing`'s runtime,
threads, signals, `Sys` beyond `exit` and the arguments.

## Groundwork decisions

### 1. Native code, through ix's toolchain; no bytecode

(The author, 2026-09-26.) Bytecode is Caml Light's road and ocamlc's:
a small compiler, but an interpreter to write too (ocaml-light's
`interp.c` and its runtime), and a program that ix's linker never sees.
Native code makes mini-ml the toolchain's second front end: its objects
are mini-asm's, linked by mini-ld with the runtime and a libc.

### 2. The contract: the program's behavior

Against ocaml-light's `ocamlopt`, the same program's output, exit
status and uncaught exception, on arm (`/tmp/ix-ocaml-light-arm`,
31-bit integers, run under `qemu-arm`) and arm64 (63-bit, natively).
No listing is compared, not even ocaml-light's intermediate language
(`-dlambda`): the author's choice, and the right one, because a twin of
an OCaml program written in OCaml, matching it byte for byte, could
only be a copy of it. Freed from that, mini-ml can take the smaller
road at each step: sequential pattern matching instead of
`matching.ml`'s scheme, a stack machine instead of a register
allocator, a copying collector instead of an incremental one.

For the type checker the contract is what it accepts: the corpus's
programs accepted, with the types ocaml-light's `-i` prints (up to the
names of type variables), and ill-typed variants of them rejected.
Error messages are not compared.

### 3. The dialect: ocaml-light's, modules as static names

The table above: ocaml-light 1.07's core language, `.mli` files, and
modules without functors. Without functors or first-class modules a
module is only a name space, known at compile time: `Machine.Phys.get8`
is a global symbol, not a field of a structure found at run time (as
ocaml-light makes it). So mini-ml flattens modules, nested (`module
Request = struct ... end`) and aliased (`module Phys = Machine.Phys`)
ones included, into names.

And **no compiled interfaces**: to compile `A.ml` that uses `B`,
mini-ml reads `b.mli` itself (or `b.ml` when there is no `.mli`), as a C
compiler reads a header. ocaml-light writes a `.cmi` (a marshalled
environment) to save that reading; mini-ml saves the format instead,
and a whole program's `.mli`s parse in a moment. What an importer needs
from `b.mli`: its types' constructors (their tags), its records' labels
(their positions), its exceptions, its `external`s (a call to C), and,
with the type checker, its values' types.

### 4. One representation; types forgotten after checking

Every value is one word, OCaml's representation: an integer `n` is
`2n+1` (so 31 bits on arm, 63 on arm64, as ocaml-light), anything else a
pointer to a block with a header (its size and a tag), a constant
constructor an integer, a constructor with arguments a block tagged by
its number. Floats, when they come, are boxed, always: ocaml-light
unboxes the floats of a float array and of an all-float record, and
that is the one place where its code depends on types (`Pfloatarray`,
`Record_float`). Without it, the passes after the type checker never
look at a type.

Consequence (camlboot's observation, related work): OCaml's meaning
doesn't depend on its types, so a correct program can be compiled
without checking it. mini-ml's back end is built first, on programs
ocaml-light has checked; the type checker comes after (phase 4), as a
pass nothing downstream reads, and `-unsafe-types` skips it.

### 5. The runtime: a value stack, a copying collector, C

The collector must find every live value. ocaml-light's way is
**frame tables**: for every call, the return address, the frame's
size, and which of its slots hold values (checked, `ocamlopt -S` of a
three-line `sum` on arm: `.word .L103 + 4`, `.short 8`, `.short 1`,
`.short 0`), and assembly that finds the frames from the registers.
mini-asm's objects can't write that table: a datum can hold a symbol's
address, not an instruction's, since instructions have no address
until mini-ld lays them out (the design: no relocations).

So mini-ml keeps its values on a **stack of its own**: the machine's
stack holds return addresses and C's frames, and never a value; a
second stack, whose pointer is a register while ML runs and a global
while C runs, holds every value live across a call or an allocation.
The collector's roots are that stack, from its base to its pointer,
the modules' globals (a table the compiler writes as data), and the
values C registers. This is Henderson's "accurate garbage collection
in an uncooperative environment" (2002): a shadow stack, for a
compiler that can't describe its frames.

What it buys beyond the table:

- **No assembly.** Calling C is a call with 5c's convention, the value
  stack's pointer stored in its global first; C calling ML (a callback,
  the kernel's `trap`) pushes the arguments on the value stack from C;
  raising unwinds by restoring two stack pointers, in generated code.
  ocaml-light's `arm.S` (440 lines: `caml_call_gc`, `caml_c_call`,
  `caml_start_program`, `caml_raise_exception`, `caml_callback`...)
  has no counterpart.
- **Processes are two pointers.** mini-9pi switches between kernel
  stacks, and today saves five of ocaml-light's globals per process
  (`caml_bottom_of_stack`, `caml_last_return_address`, `caml_gc_regs`,
  `caml_exception_pointer`, `local_roots`: `kernel/lib/runtime.c`) and
  walks the other stacks through the runtime's hook. With mini-ml, a
  process has a value stack; switching saves its pointer and the
  exception handler's; the collector scans each process's value stack.

Its cost: a store and a load per value live across a call, which a
register allocator would have kept in a register or a frame slot. The
code is slower; the kernel doesn't mind (its sessions wait on the
console).

The collector: **Cheney's copying collector** (1970), two halves, the
allocation a pointer bumped and compared, about 150 lines of C, where
ocaml-light's generational and incremental one is 1,683 (normalized:
minor and major heaps, free lists, compaction). A copying collector
moves values, so C code keeps its values in registered roots (the
kernel's C does, in three places: `CAMLparam`). A generational
collector is the better version, beside it, switchable, if the kernel
or the tests ask for it.

The runtime, in C: allocation and the collector, polymorphic compare
and hash (Hashtbl's), strings and arrays, the primitives the stdlib
names, the channels over libc's `read` and `write`, startup and the
uncaught exception. ocaml-light's `mlvalues.h`'s names (`Val_long`,
`Long_val`, `String_val`, `Field`, `alloc_string`, `callback`,
`caml_named_value`...) are kept, so that the kernel's C changes little.

### 6. Reusing mini-cc's back end: its objects, its linker, its records

What of mini-cc can be reused was read (`languages/c/Emit.mli`,
`Gen.mli`, `assembler/Asm.mli`, `linker/Link.mli`). mini-cc's `Gen` and
`Emit` work on C's typed trees (`Tree.expr`: `regalloc`, `naddr`,
`gopcode` take C nodes), and can't be called from ML's. What is reused
is the half of a code generator that mini-cc doesn't write either,
Plan 9's split:

- **mini-asm's objects** (`Ix_asm.Asm.obj`: `Text`, `Data`, `Globl`,
  `Ins`) as the output, and `Asm.show_item` for `-S`; the law of
  mini-cc: `mini-ml -S f.ml | mini-asm` makes `mini-ml f.ml`'s object.
- **mini-ld**, unchanged: a function's prologue and epilogue from its
  `TEXT` and `RET` (the link register saved if it calls), large
  constants (a pool on arm, `MOVZ`/`MOVK` on arm64), branches' reach,
  `DIV` and `MOD` on arm as calls to libc's `_div`..., ELF, a.out and
  Mach-O.
- **mini-cc's decision 1**: one code generator, a record per machine
  (registers, widths, the conventions), `Arm` and `Arm64`.
- **mini-cc itself**, for the runtime's C, and goken's libc.
- **TinyC's code generator's design** (`tiny/TinyC.ml`): a stack
  machine as the intermediate language, its stack kept in registers,
  as Wirth's compilers do. Here the machine's stack, spilled at a call
  or an allocation, goes to the value stack: decision 5's rule falls
  out of the stack machine.

One thing is added to mini-ld's use: a tail call (a `B` to another
function after the epilogue), which ML needs (a `let rec` loop must
not grow the stack). mini-ld writes epilogues at `RET`; the compiler
will write a tail call's epilogue itself, from the same frame size, or
mini-ld will learn a jump that is a `RET` elsewhere (5 lines in
`linker/Arm.ml`'s rewrite; phase 3 chooses).

### 7. The parser: ocamllex and ocamlyacc

ML's grammar is what yacc does well and a parser by hand does badly:
a long precedence table, `;` inside `match` inside `if`, a
constructor applied to a tuple, `let ... and ...`. ocaml-light's own
`parser.mly` is yacc (1,081 lines, for the whole language); mini-ml's
grammar is the subset's, with `%prec` for `if` without `else` and
match's cases, as OCaml's. The lexer is ocamllex: ML's tokens are
regular, with no preprocessor stacking inputs (C's reason for a lexer
by hand). The one-file variant can't include a `.mly` and parses by
precedence climbing.

### 8. The kernel's route: through ix's toolchain (decided)

mini-9pi is linked today by GNU ld: ocaml-light's `.o` files (ELF,
relocatable), its runtime and the kernel's C (by gcc), `start.s` (GNU
syntax). mini-ml's objects are mini-asm's, which GNU ld can't read,
and mini-ld reads no ELF. Two roads:

- **(A) The whole kernel through ix's toolchain (recommended).**
  mini-ld learns a kernel image (5l's `-H6 -T -R`: raw, at an address,
  as principia's own 9pi is linked: `kernel/conf/arm/mkfile`); the
  kernel's C (`runtime.c`, `libc.c`, `usb.c`, the board's `machine.c`:
  948 lines, 12 of them gcc's `asm` or attributes) compiled by
  mini-cc, the inline assembly moved to the start file; `start.s`
  (296 lines) rewritten in Plan 9's assembly, with principia's own
  (`~/principia/kernel/*/arm/*.s`, 1,498 lines) as the model; the
  runtime mini-ml's. Then mini-9pi is built without gcc and without
  ocaml-light, entirely by ix.
- **(B) A second printer**: mini-ml's instructions printed as GNU
  assembly and linked by GNU ld, the rest unchanged. Smaller (about 250
  lines), but it redoes mini-ld's work (prologues, pools, constants,
  division) for another assembler, and leaves the kernel gcc's.

**Decided (the author, 2026-09-26): (A), with (B) as a fallback**
("definitely A! and yes give option to generate B, as a fallback. we
can always remove the code for B later, and hopefully it will be
isolated from the rest"). (A) is ix's direction and principia's (9pi is
5c's and 5l's); it costs a phase of its own (phase 6) and touches
mini-ld and the kernel's shim.

(B) is one module, `languages/ml/Gas.ml`, behind one flag (`mini-ml -gas`, GNU
assembly out instead of an object), and nothing else in mini-ml knows
it exists: it reads the same instruction list `-S` prints, after `Gen`,
and does the little of mini-ld's work GNU's assembler doesn't (the
prologue and epilogue from `TEXT` and `RET`, `SB`-relative addresses as
`ldr =sym`, `DIV` as a call; the literal pools and branches `as` does
itself). Removing it is deleting the file and the flag. Until then it
has a use besides the fallback: in phase 6 it runs mini-9pi on
mini-ml's code with the kernel's gcc build unchanged, so mini-ml's
code and runtime in the kernel are tested apart from (A)'s pieces
(mini-ld's image, the shim by mini-cc, the start in Plan 9's
assembly), which then replace gcc's one at a time, each checked by the
same sessions.

### 9. Where the code goes, and the names

`languages/ml/`, beside mini-cc's `languages/c/` (the author,
2026-09-26: one directory per language, as the Playground's
`libs/languages/`, room for more later). The command is `mini-ml` (the
target a flag, `-m 5` or `-m 7`, as mini-cc; `-S`, `-I`, `-o`, `-dlam`
to print the intermediate language, `-i` to print the types), its
runtime in `languages/ml/runtime/`. The one-file variant is
`tiny/TinyML.ml`, the command `tiny-ml`.

## How to be smaller than ocaml-light

ocaml-light's code for the same (normalized: comments, the literate
chunks' markers and blank lines removed), counted 2026-09-26: the
parser 1,464 lines, the type checker 3,095, the translation to its
intermediate language and the matching compiler 1,389, the native back
end 4,702 plus 845 for arm (and 378 for Cmm), about **11,500** lines
of OCaml for one machine; the runtime 5,894 lines of C (the files the
kernel links) and 440 of assembly.

| ocaml-light | lines | mini-ml | why |
|---|---:|---|---|
| back end: selection, liveness, coloring, spilling, scheduling, linearization | ~3,500 | a stack machine in registers | decision 6, TinyC's |
| arm's emitter, literal pools, constants | 845 | the Arm record; pools and constants mini-ld's | decision 6 |
| `.cmi` files, their persistence, `Env`'s | ~600 | `.mli` read as source | decision 3 |
| modules as structures, `translmod`, `includemod` | ~600 | static names; the `.mli` checked against the `.ml` | decision 3 |
| the matching compiler (`matching.ml`, `parmatch.ml`) | ~700 | clauses in order, a switch on tags | decision 2 |
| frame tables, `arm.S`, the stack's globals | 440 + | the value stack; C | decision 5 |
| generational incremental collector, compaction | 1,683 | Cheney's, ~150 | decision 5 |
| marshalling, `Lexing`, `Parsing`, the debugger's hooks | ~1,300 | none | the subset |
| floats' unboxing | | none | decision 4 |

**The target**, by module:

| module | lines | what |
|---|---:|---|
| `languages/ml/Lexer.mll`, `Parser.mly`, `Ast.ml` | 1,100 | the subset into a tree |
| `languages/ml/Scope.ml` | 400 | names: modules flattened, `.mli`s read, constructors, labels, exceptions, `external`s |
| `languages/ml/Typing.ml` | 1,100 | Hindley-Milner with levels, type declarations, the value restriction, the `.mli` against the `.ml` |
| `languages/ml/Match.ml` | 300 | patterns into tests and switches |
| `languages/ml/Lambda.ml` | 600 | the intermediate language, and the translation from the tree |
| `languages/ml/Closure.ml` | 350 | free variables, closures, known calls, currying (eval/apply) |
| `languages/ml/Gen.ml` | 700 | the stack machine into instructions, the value stack, tail calls, exceptions |
| `languages/ml/Arm.ml`, `languages/ml/Arm64.ml` | 400 | the records |
| `languages/ml/CLI.ml`, `Main.ml` | 150 | the command, `-S`, the objects |
| `languages/ml/Gas.ml` | 250 | decision 8's fallback, GNU assembly (removable) |
| **compiler** | **about 5,350** | less than half of ocaml-light's for one machine |
| `languages/ml/runtime/*.c` | 1,300 | allocation and the collector 300, compare and hash 250, strings, arrays and primitives 350, channels 200, startup, callbacks, exceptions 200 |

mini-cc missed its target by half (3,500 planned, 5,253 built), and
mini-mk by 2.4; this one is stated before, compared after.

## Outside the compiler: the one-file variant, first

(The order the author approved, 2026-09-26: the variant before the
faithful program, the reverse of ix's usual order.) `tiny/TinyML.ml`,
`tiny-ml`: a smaller ML (integers, booleans, strings, tuples, lists,
variants, `match`, `let rec`, closures, references, exceptions;
Hindley-Milner; no modules, records or arrays), to arm64 assembly for
TinyAssembler, through TinyC's kind of stack machine, with a runtime in
C (the collector, 150 lines) compiled by tiny-c. Target: 1,500 lines of
code. It is first because it settles, in a file one can read in an
evening, the two questions the big one depends on: whether the value
stack and a copying collector are as small as decision 5 says, and how
much the stack machine costs in code quality. Its test: the programs of
`languages/ml/tests/tiny/` and random ones, the same output as ocaml-light's
arm64 `ocamlopt`.

## The modules, with their references

- **Lexer, Parser, Ast**: ocaml-light's `parsing/lexer.mll`,
  `parser.mly`; the OCaml manual's grammar (chapter "The OCaml
  language").
- **Scope**: ocaml-light's `typing/env.ml`, `typemod.ml` (what
  flattening replaces).
- **Typing**: Milner, "A Theory of Type Polymorphism in Programming"
  (1978); Damas and Milner, "Principal type-schemes for functional
  programs" (1982); Rémy's levels (1992) and Kiselyov's "How OCaml type
  checker works" (2013); Wright, "Simple imperative polymorphism"
  (1995), the value restriction; ocaml-light's `typecore.ml`,
  `ctype.ml`.
- **Match**: Augustsson, "Compiling pattern matching" (1985); Wadler's
  chapter in Peyton Jones's book (1987); Le Fessant and Maranget,
  "Optimizing pattern matching" (2001), ocaml-light's, as the road not
  taken; Maranget, "Compiling pattern matching to good decision trees"
  (2008), as the better version.
- **Lambda, Closure**: ocaml-light's `lambda.ml`, `translcore.ml`,
  `closure.ml`; Appel and Jim, "Continuation-passing, closure-passing
  style" (1989); Marlow and Peyton Jones, "Making a fast curry"
  (2004), eval/apply.
- **Gen, Arm, Arm64**: TinyC's back end; mini-cc's `Emit` and records;
  Wirth, *Compiler Construction* (1996).
- **runtime**: Cheney, "A nonrecursive list compacting algorithm"
  (1970); Henderson, "Accurate garbage collection in an uncooperative
  environment" (2002); Jones, Hosking and Moss, *The Garbage Collection
  Handbook* (2011); ocaml-light's `byterun/`.

## Tests (what the program is for)

- **The programs**: each through mini-ml and ocaml-light's `ocamlopt`,
  run, output and exit status compared; on arm (under `qemu-arm`, as
  mini-cc's) and arm64. The corpus: ocaml-light's `test/` without
  floats (35 files: fib, takc, taku, sieve, quicksort, soli, bdd,
  boyer, alloc, KB's Knuth-Bendix, Lex's lexer generator, Moretest's),
  and `languages/ml/tests/` by construct (patterns, closures and partial
  application, exceptions through C, deep recursion, tail calls in
  loops of a million).
- **The objects' law**: `mini-ml -S | mini-asm` against `mini-ml`.
- **The collector's law**: the output doesn't depend on the heap's
  size. Every test again with a heap so small that it collects at
  almost every allocation (`ML_HEAP=` the smallest that runs), which
  is what finds a value left outside the value stack.
- **The type checker**: the corpus accepted, `mini-ml -i` against
  `ocamlopt -i` with type variables renamed in order; mutations (an
  argument swapped, a constructor's argument dropped, a `ref` made
  polymorphic) rejected where ocaml-light rejects them.
- **A fuzzer**: random well-typed programs (generated by type, as
  Pałka et al. did for GHC, 2011) over the subset, through both
  compilers, the outputs compared. It found what the corpus missed in
  the editor, the linker and TinyC; it is expected to here.
- **The milestones**: (1) `test/`'s programs, on arm; (2) the stdlib's
  modules and the programs that use them; (3) mini-9pi, its sessions
  (`make check`: stages B, C and D1) under mini-qemu and QEMU, the same
  console, then on a Pi1 (the author); (4) an ML program compiled by
  mini-ml, as a Plan 9 a.out, run on mini-9pi compiled by mini-ml.

## Phasing

0. **Groundwork**: the counts (`languages/ml/tests/count_ml.py`, done); the
   references (done: ocaml-light for arm and arm64 run a program here);
   the tutorial's listings from `ocamlopt -S` and `-dlambda` (done);
   the conventions checked: which registers 5c and 7c never allocate
   (for the value stack's pointer), how mini-ld treats a `TEXT` whose
   function only tail-calls.
1. **tiny-ml** (`tiny/TinyML.ml`), with its runtime and tests.
2. **Front end**: Lexer, Parser, Ast, Scope, over the whole corpus
   (mini-9pi, the stdlib's modules, `test/`): every file parsed and its
   names resolved, a `-dast` by hand on samples.
3. **The back end, untyped, arm**: Lambda, Match, Closure, Gen, the
   Arm record, the runtime by mini-cc, linked by mini-ld with goken's
   libc (`-H7`); milestone 1, the collector's law, the fuzzer.
4. **Typing**: the type checker and the `.mli` check; its tests;
   milestone 2 with it on.
5. **arm64**: the second record; the tests on both.
6. **The kernel** (decision 8): first the kernel's C on mini-ml's
   runtime (the stacks' switch, the roots, the callbacks) and `-gas`
   (route B, `languages/ml/Gas.ml`), mini-9pi's sessions passing with gcc's
   build; then route A, one piece at a time: mini-ld's kernel image,
   the kernel's C by mini-cc, its start in Plan 9's assembly, until
   neither gcc nor ocaml-light is left; milestone 3, then 4.
7. **Later**: floats (boxed; on arm64 first: on arm mini-ld encodes 5c's
   FPA, not the Pi's VFP), exhaustiveness warnings (Maranget 2007),
   decision trees, a generational collector, keeping values in
   registers across calls; each beside the simple version, switchable.
8. **Docs**: `notes_ml.md` checked against the code, the numbers.

## Status

- **2026-09-26, decision 8 decided**: route A, with B as an isolated,
  removable fallback (`languages/ml/Gas.ml`, `-gas`), which phase 6 also uses as
  its first step.
- **2026-09-26, the plan written, for review.** Checked for it:
  - ocaml-light's `ocamlopt` for arm and arm64
    (`/tmp/ix-ocaml-light-{arm,arm64}`, from `kernel/ocaml-light.sh`)
    compile and run a test program (`fib 20` and `max_int`), arm under
    `qemu-arm`;
  - the corpus's OCaml, with `languages/ml/tests/count_ml.py` (the appendix); the
    stdlib functions mini-9pi calls, and the primitives their modules
    name (56 of the compiler's, 62 in C);
  - which of `test/`'s files use floats, functors or objects (5
    floats, 1 functor, no object);
  - ocaml-light's sizes, normalized, by part; the runtime files the
    kernel links (`kernel/lib/kernel.mk`'s `RUNTIME`) and the runtime
    API the kernel's C uses (`Long_val` 67, `Val_unit` 38, `Val_long`
    22..., `callback` 5, `caml_named_value` 4; 81 `external`s);
  - the frame table `ocamlopt -S` writes for a call on arm (decision 5),
    and that mini-asm's `Data` holds a symbol's address and no
    instruction's (`Asm.operand`);
  - mini-cc's back end's interfaces (decision 6);
  - that principia's 9pi is linked by `5l -H6 -R4096 -T$loadaddr`
    (`~/principia/kernel/conf/arm/mkfile`), and its arm assembly's size;
  - camlboot's paper (`~/ocaml-light/docs/papers/camlboot-paper.pdf`),
    for the related work and decision 4.

## Verification

`make test` will run tiny-ml's and mini-ml's programs against recorded
outputs, and the collector's law; `make test-ocaml` the live
comparisons with ocaml-light and the fuzzer; `kernel/9pi`'s `make
check`, with `ML=mini-ml`, the kernel.

## Out of scope

Self-hosting: mini-ml is written in today's OCaml (dune, `Fpath`, the
capabilities, mini-asm's modules), which it doesn't compile; compiling
itself would mean writing it in ocaml-light's dialect first, a project
of its own. Also functors, objects, labels, polymorphic variants,
`lazy`; the toplevel, bytecode, the debugger, marshalling; ocaml-light's
optimizations (inlining, unboxing, register allocation), beyond what
phase 7 lists; other machines.

## Related work

[`notes_ml_related_work.md`](../related-work/notes_ml_related_work.md).

## Appendix: the counts

The evidence, from `languages/ml/tests/count_ml.py` (2026-09-26).

### mini-9pi (`count_ml.py kernel/9pi kernel/lib`)

```
61 files, 6246 lines, in kernel/9pi, kernel/lib

  let                                1149
  |                                   670
  in                                  528
  if                                  501
  then                                501
  land lor lxor lsl lsr asr lnot      389
  with                                280
  else                                279
  raise                               222
  val                                 205
  fun                                 194
  <- (field or array set)             193
  match                               182
  !                                   173
  { (record)                          166
  mutable                             144
  end                                 132
  begin                               126
  .( (array)                          126
  and                                 101
  external                             81
  try                                  74
  type                                 74
  ::                                   67
  ref                                  67
  :=                                   67
  of                                   66
  let rec                              55
  rec                                  55
  .[ (string)                          52
  open                                 38
  do                                   23
  done                                 23
  when                                 21
  for                                  19
  to                                   16
  function                             11
  module                                8
  while                                 4
  downto                                3
  struct                                3
  sig                                   3
  as                                    2
  exception                             2
```

No float literal or operator, no `functor`, `lazy`, `assert`, `object`,
`class`, labeled or optional argument, or polymorphic variant: the
script counts them, and found none.

### ocaml-light's `test/`, by program

```
test/alloc.ml      50  floats=0       KB/*.ml       611  floats=0
test/bdd.ml       211  floats=0       Lex/*.ml      741  floats=0
test/boyer.ml     903  floats=0       Moretest/arrays.ml    86  floats=15
test/fft.ml       187  floats=58      Moretest/intext.ml   289  floats=25
test/fib.ml        23  floats=0       Moretest/sets.ml      38  functor
test/nucleic.ml  3231  floats=6726    Moretest/testrandom.ml 13  floats=1
test/quicksort.ml  91  floats=0       Moretest/ (15 others) floats=0
test/sieve.ml      55  floats=0
test/soli.ml      110  floats=0
test/takc.ml       22  floats=0
test/taku.ml       21  floats=0
```
