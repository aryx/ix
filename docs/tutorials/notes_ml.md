# An ML compiler, from scratch: a tutorial for `languages/ml/`

How an ML file becomes the instructions that mini-ld links, on arm and
arm64: a front end that reads ocaml-light's ML into a tree and resolves
its names, a type checker that infers every type and then is forgotten,
a translation into a small language where patterns are tests and
functions are closures, and a code generator that keeps every value
where a copying collector can find it. It is written for **a reader of
mini-ml's code, not a user of OCaml**, and explains the ideas in the
order the code needs them.

It is the specification of the program planned in
[`plan_ml.md`](../plans/plan_ml.md), written before the code, to be
checked against it, as the other tutorials were. The listings marked
"checked" are ocaml-light's (`ocamlopt -dlambda`, `ocamlopt -S`, for
arm, on 2026-09-26); those marked "planned" are what mini-ml is
designed to write, not yet written. Companions:
[`notes_ml_related_work.md`](../related-work/notes_ml_related_work.md),
[`notes_cc.md`](notes_cc.md) (the other compiler, whose objects and
linker this one shares), [`notes_asm.md`](notes_asm.md), and the twin,
ocaml-light, with its literate book (`~/ocaml-light/docs/literate/`).

## 0. Where the code is, and a reading order

The modules as planned (plan_ml.md, "How to be smaller"):

| module | what | section |
|---|---|---|
| `languages/ml/Ast` | the tree | §4 |
| `languages/ml/Lexer.mll`, `Parser.mly` | ML into a tree | §4 |
| `languages/ml/Scope` | modules, `.mli`s, constructors, labels, exceptions, `external`s | §5 |
| `languages/ml/Typing` | types inferred, declarations, the `.mli` checked | §6 |
| `languages/ml/Match` | patterns into tests | §7 |
| `languages/ml/Lambda` | the small language, and the translation into it | §8 |
| `languages/ml/Closure` | functions into closures, calls into direct or generic ones | §9 |
| `languages/ml/Gen` | the stack machine into instructions, the value stack | §10 |
| `languages/ml/Arm`, `Arm64` | what each machine decides | §10 |
| `languages/ml/runtime/` | allocation, the collector, the primitives, in C | §11 |
| `tiny/TinyML.ml` | all of it, smaller, in one file | §14 |

Read §1 and §3 first: the rest follows from how a value looks at run
time.

## 1. From a `.ml` to a running program

A function, and what ocaml-light makes of it (checked):

```
   let rec sum = function           (letrec
     | [] -> 0                        (sum/37
     | x :: l -> x + sum l              (function param/40
                                          (if param/40
                                            (let (x/38 (field 0 param/40)
                                                  l/39 (field 1 param/40))
                                              (+ x/38 (apply sum/37 l/39)))
                                            0)))
                                      (seq (setfield 0 (global Sum!) sum/37) 0a))
```

The first translation, `-dlambda`, already says most of this tutorial:
the pattern match became a test (`if param/40`: is the list a block,
or the integer that `[]` is?), the constructor's arguments became
fields of a block (`field 0`, `field 1`), the function a value stored
in the module (`setfield 0 (global Sum!)`). Then ocamlopt's code for arm
(checked; the frame table at the end of the file):

```
   Sum_sum_37:
       sub   sp, sp, #8           a frame: the link, and one slot
       str   lr, [sp, #4]
       cmp   r0, #1               [] is 1 (0, tagged)
       beq   .L101
       ldr   r5, [r0, #0]         x
       ldr   r0, [r0, #4]         l, the argument
       str   r5, [sp, #0]         x kept across the call, in the slot
   .L103:
       bl    Sum_sum_37
       ldr   r1, [sp, #0]
       ldr   lr, [sp, #4]
       add   r2, r1, r0           x + n on tagged integers:
       sub   r0, r2, #1           (2x+1) + (2n+1) - 1
       add   sp, sp, #8
       mov   pc, lr
   .L101: ...                     return 1

   Sum_frametable:
       .word  .L103 + 4           after this call's return address,
       .short 8                   in a frame of 8 bytes,
       .short 1                   1 slot holds a value:
       .short 0                   at offset 0 (x)
```

The frame table is how ocaml-light's collector, stopped inside a
deeper call, knows that the word at `[sp, #0]` of this frame is a
value that must be kept (and updated, if the value moves), and the
word at `[sp, #4]` is not. mini-ml can't write it: it names the address
of an instruction, `.L103 + 4`, and in Plan 9's toolchain an
instruction has no address until the linker lays the program out. So
mini-ml keeps `x` elsewhere (planned):

```
   TEXT  Sum_sum(SB), $0          no frame of its own; the linker saves
                                  the link, since the function calls
       CMP   $1, R0
       BEQ   nil
       MOVW  0(R0), R1            x
       MOVW  R1, 0(R10)           x onto the value stack (R10), where
       ADD   $4, R10              the collector will find it
       MOVW  4(R0), R0            l
       BL    Sum_sum(SB)
       SUB   $4, R10              x back
       MOVW  0(R10), R1
       ADD   R1, R0
       SUB   $1, R0
       RET                        the linker's epilogue
   nil:
       MOVW  $1, R0
       RET
```

Nearly the same instructions; the difference is where `x` waits: on
the machine's stack, described by a table, or on a stack of values,
which the collector scans from its bottom to R10 without a table (§11).
And what mini-ml leaves to the linker, as mini-cc does: the prologue
and epilogue (from `TEXT` and `RET`), and, elsewhere, large constants,
literal pools and division.

From files to a program (planned commands):

```
   mini-ml -m 5 -I stdlib -o sum.5 sum.ml     an object: mini-asm's
   mini-ml -m 5 -I stdlib -o main.5 main.ml
   mini-ld -m 5 -H7 -o prog runtime.a stdlib.a sum.5 main.5 -lc
```

The runtime (C, compiled by mini-cc) and the stdlib (ocaml-light's own
`.ml`, compiled by mini-ml) are libraries, goken's libc under them;
`-H2` instead of `-H7` makes a Plan 9 a.out, for mini-9pi. The runtime's
`main` initializes the heap, then calls each module's initialization,
in the order of the command line, as ocaml-light's startup does.

## 2. The language: ocaml-light's, what mini-9pi uses

ocaml-light is OCaml 1.07 without objects and functors (its
`CLAUDE.md`). mini-ml takes what mini-9pi uses (plan_ml.md, "The
subset, counted"): `let`, `let rec`, `fun`, `function`, `match` with
guards and `as`, variants, records with mutable fields, tuples, lists,
arrays, mutable strings, exceptions, `for`, `while`, `external`, `open`,
and modules without functors (nested ones and aliases). Floats come
later; labels, polymorphic variants, `lazy` and functors never.

Two things of 1.07's ML that today's OCaml changed, which matter here:

- **Strings are mutable** (`String.set`, `String.create`: 13 uses in
  mini-9pi); there is no `Bytes`.
- **A record's label is found by scope**: `r.len` is the `len` of the
  last type declared with that label, whatever `r`'s type. So finding
  a field's position needs names, not types (§5).

## 3. Values at run time

Everything is a word: the uniform representation. The low bit tells
an integer from a pointer:

```
   42                 85                  2n+1: an integer, 31 bits on arm
   true, false        3, 1                constant constructors: integers
   []                 1                     numbered from 0 in the type
   x :: l             ptr --> +------+------+------+
                              | hdr  |  x   |  l   |    size 2, tag 0: the type's
                              +------+------+------+    first constructor with arguments
   (a, b)             ptr --> | hdr  |  a   |  b   |    size 2, tag 0
   "abc"              ptr --> | hdr  | a b c \0     |    size 1, tag String: the last
                                                        byte says how many are padding
   fun y -> x + y     ptr --> | hdr  | code | arity | x |   a closure (§9)
```

The header is a word: the block's size in words and its tag (and two
bits of color that ocaml-light's collector uses and mini-ml's doesn't).
A pointer is even, and points after the header, so that `field 0` is at
offset 0.

Integers are tagged, so arithmetic untags as little as it can:

```
   a + b     a + b - 1          (2x+1) + (2y+1) - 1 = 2(x+y)+1
   a - b     a - b + 1
   a * b     (a - 1) * (b >> 1) + 1
   a < b     a < b              tagging keeps the order
   a land b  a AND b            the low bits: 1 AND 1
   a lxor b  (a XOR b) OR 1
   a / b     untag, test b for 0 (Division_by_zero), divide, tag
```

Why one representation: polymorphism needs it. `List.length` works on
a list of anything because every element is a word; the compiler
never needs to know what a word holds, and neither does the collector,
beyond the low bit and the header. That is also why mini-ml can forget
types after checking them (plan_ml.md, decision 4); the price is that
a float is a block (boxed), which ocaml-light avoids in float arrays by
looking at types, and mini-ml doesn't.

## 4. The front end: characters, tokens, a tree

The lexer is ocamllex: ML's tokens are regular (identifiers, the
capitalized ones constructors and modules, integers, characters,
strings with escapes, nested comments, operators). The parser is
ocamlyacc (plan_ml.md, decision 7), and its grammar is mostly about
where an expression ends:

- `if a then b; c` is `(if a then b); c`: `;` is looser than `if`.
- a `match` inside a `match`'s case takes all the following cases:
  parentheses or `begin ... end` are needed, and the grammar reproduces
  that (`%prec`), rather than fixing it.
- `f x :: l` is `(f x) :: l`: application is the tightest.
- `C (a, b)`, where `type t = C of int * int`, is a constructor with two
  arguments (a block of two fields), not a pair: the parser sees a
  tuple, and the translation looks at the declaration (§5).
- `let x = e1 and y = e2 in e` binds at once; with `rec`, mutually.

The tree (`Ast`) is the subset's: expressions, patterns, type
expressions, type declarations, structure items (`let`, `type`,
`exception`, `external`, `open`, `module`), and signature items for
`.mli`s. Each node has its location, for the errors.

## 5. Names and modules

Without functors, a module is a name space known at compile time
(decision 3). `Scope` walks the tree with an environment and replaces
every name by what it denotes:

- a **value** by a local variable (a unique identifier) or a global
  symbol: `Machine.Phys.get8` becomes the symbol of `get8` in the
  module `Phys` nested in `Machine`, or, being an `external`, a call to
  the C function `phys_get8`;
- a **constructor** by its tag and its arity in its type's
  declaration: `[]` is the constant 0, `::` the block tag 0 of 2 fields;
- a **label** by its position in its record (the last declared with
  that label, §2);
- an **exception** by its global: an exception is a block allocated at
  the module's initialization, compared by address; `raise Not_found`
  raises a block whose field 0 is it.

Modules are flattened: `module Request = struct ... end` inside `P9`
defines `P9.Request.x` symbols; `module Phys = Machine.Phys` is an alias
in the environment, nothing at run time; `open M` adds `M`'s names.

Another file's names come from its `.mli`, read and resolved when first
used, the way C reads a header: its types (for tags and labels), its
exceptions, its `external`s, and its values' types (for §6). There is
no compiled interface file: reading a `.mli` is cheaper than a format.

## 6. Types

The type checker infers a type for every expression, and fails on a
program that could go wrong. It is Hindley-Milner's algorithm, as ML
has had it since 1978:

- **Unknowns and unification.** Each unknown type is a variable; using
  `x` as a function adds `'a = 'b -> 'c`; unifying two types makes them
  equal, recursively, or fails (`int` against `string`). Variables are
  mutable cells linked to what they became (union-find), so unifying
  is a walk, not a substitution.
- **Generalization.** After `let id = fun x -> x`, `id`'s type
  `'a -> 'a` is generalized: `'a` becomes a parameter, and each use of
  `id` gets fresh copies (instantiation). Which variables may be
  generalized: those not also in the enclosing environment's types.
  Scanning the environment is slow; **levels** make it cheap: each
  variable records the depth of the `let` that created it, unifying
  lowers levels, and at the end of a `let` exactly the variables
  deeper than it are generalized (Rémy's; OCaml's way, which
  Kiselyov's note explains).
- **The value restriction.** `let r = ref []` must not be generalized,
  or `r` could hold an `int` then be read as a `string`. Only values
  (functions, constants, constructors of values) are generalized; an
  application is not (Wright's rule, ocaml-light's `nonexpansive`).
- **Declarations**: a variant's constructors, a record's labels,
  abbreviations; recursive and mutually recursive types.
- **The `.mli`**: each `val` must be an instance of what the `.ml`
  inferred, and each type as declared.
- **Formats**: a string literal where a `format` is expected is typed
  by its conversions (`"%d %s"` is `int -> string -> 'a`), the one
  special case of ocaml-light's checker.

Nothing after this pass reads a type: the trees keep none. So the pass
can come second in the phasing (plan_ml.md, phase 4), and `-i` prints
what it inferred, which is how it is tested against ocaml-light.

## 7. Pattern matching

A `match` is compiled into tests on the value's parts: whether it is an
integer or a block, which constant, which tag, then the fields, in the
patterns' order. mini-ml's scheme is the simplest that works: the
clauses in order, each a sequence of tests; a test that fails jumps to
the next clause; the last one's failure raises `Match_failure`. A
`when` guard is one more test. So

```
   match l with
   | [] -> a
   | [x] -> b
   | x :: y :: _ -> c
```

tests `l` against `[]`, then (failing) `l` is a block and its field 1
is `[]`, then that `l`'s field 1 is a block. Some tests are repeated
(`l` is a block, twice): the cost of the simple scheme. Where the
clauses' first patterns are all constructors of one type, mini-ml
switches once on the tag instead (a jump table), which is what most of
mini-9pi's 182 `match`es are. Tests shared across clauses, without
repetition, are Le Fessant and Maranget's backtracking automata
(ocaml-light's `matching.ml`), and Maranget's decision trees; the
related work has both, as the better version.

## 8. From trees to a small language

`Lambda` is where ML's sugar is gone: variables, constants, `let`,
`letrec`, functions of several parameters, application, primitives
(`%addint`, `%field0`, a block's allocation, a C call), `if`, a switch
on integers and tags, `catch`/`exit` (a local jump, what matching's
"next clause" becomes), `try`/`raise`, sequences, `while`, `for`. A
module's toplevel is a function run at startup, which computes its
values and stores them in their globals.

Planned `-dlam` of `sum` (the same as ocaml-light's but for the names):

```
   (letrec (sum (fun (p)
                  (if (isint p) 1
                    (let (x (field 0 p) l (field 1 p))
                      (+ x (apply sum l))))))
     (setglobal Sum_sum sum))
```

## 9. Closures

A function that mentions variables of an enclosing function can't be
only code: its value is a **closure**, a block with the code's address,
its arity, and the values of its free variables. `Closure` makes this
explicit: each function becomes code at the toplevel with an extra
parameter, its closure, and each free variable a load from it.

Calls come in two kinds:

- **Known** calls: the function is a toplevel `let` or `let rec` of this
  module or another, and gets all its arguments. A direct `BL`, no
  closure needed (`sum`'s recursive call).
- **Unknown** calls: `f x y` with `f` a parameter. The callee's arity
  may be 1 (`f x` returns a function, applied to `y`), 2, or 3 (the
  result is a *partial application*, a closure waiting for the third).
  mini-ml uses eval/apply (Marlow and Peyton Jones): the caller calls
  a generic `apply2`, which reads the arity and does one of the three.
  The `applyN` functions are written by the compiler, in the startup
  object, as ocaml-light's `caml_applyN` and `caml_curryN` are.

`let rec f = ... and g = ...` allocates the closures first, then fills
their free variables, since each needs the others.

## 10. The code

`Gen` turns `Lambda`, closures made explicit, into instructions through
a stack machine, as TinyC does (`tiny/TinyC.ml`): an expression pushes
its value, an operator pops its operands. The machine's stack is kept
in registers (depth d in a register of the machine record's list), so a
push is a `MOVW` and `x + y` one `ADD`, as in Wirth's compilers.

**The value stack.** At a call or an allocation, the collector may run.
The rule: at those points, no value may be only in a register. So
before a call, `Gen` spills what the machine's stack holds below the
arguments, and every variable still needed after the call, to the
value stack, and reloads them after. Between calls, values live in
registers, and the collector can't run.

```
   machine stack (SP)               value stack (R10 while ML runs)
   +----------------+               +----------------+  base
   | return address |               | x   (sum's)    | ---> a block
   | C's frames     |               | ...            |
   | an exception   |               | x   (sum's)    |
   |   handler      |               +----------------+  <- R10
   +----------------+
   never a value                    only values: the collector's roots
```

**Calls between ML and C.** An `external` is called with 5c's
convention (the first argument in R0, the others on the stack), after
storing R10 in the runtime's global, so that C, and the collector
under it, see the value stack. C calls ML (the kernel's `trap`, a
`Callback`) by pushing the arguments on the value stack and calling the
closure's code. No assembly on either side.

**Tail calls.** `f x` as a function's last action jumps (`B`) instead of
calling, after the epilogue: a `let rec` loop runs in constant stack.
The value stack is popped before.

**Exceptions.** `try e with h` pushes a handler on the machine stack:
the previous handler, the value stack's pointer, the handler's code.
`raise v` puts `v` in R0, restores SP to the latest handler and R10 to
its saved pointer, pops it and jumps. So raising costs a few
instructions, whatever the depth.

**The machines.** One `Gen`, a record per machine, as mini-cc's
(plan_cc.md, decision 1): the registers (the result, the stack
machine's, the value stack's, the linker's temporary to avoid), the
word's size (4 or 8: an integer's range follows), the instructions that
differ (`MOVW` and `MOV`, `RET` and `RETURN`), division (a call on arm,
`SDIV` on arm64).

## 11. The runtime

In C, compiled by mini-cc (plan_ml.md, decision 5).

**Allocation** is a pointer bumped in a free region and compared with
its end; when it passes, the collector runs, then the allocation.

**The collector** is Cheney's (1970). The heap is two halves; the
program allocates in one. To collect, copy each root's block to the
other half, leaving in the old one a forwarding address; then walk the
copies, from the start, with a `scan` pointer, copying every block
their fields point to that isn't copied yet:

```
   from-space                         to-space
   +---+---+---+---+---+              +---+---+---+
   | A | b | C | d | E |              | A'| C'| E'|
   +---+---+---+---+---+              +---+---+---+
     ^ roots: A                         ^scan      ^free
     A -> C -> E, b and d dead          copying is the traversal: breadth
                                        first, no stack, no recursion
```

When `scan` reaches `free`, everything reachable is copied, and the
halves swap. The dead (b, d) cost nothing: the collector's work is
what lives. Blocks move, so a C function holding a value across an
allocation registers it as a root (`CAMLparam`) and reads it back.

**The roots**: the value stack from its base to its pointer (each
process's, in the kernel); the modules' globals, whose table the
compiler writes as data; the roots C registered.

**The primitives**: polymorphic `compare` (a walk of two values in
parallel: integers by value, blocks by tag then fields, strings by
bytes), `hash` (Hashtbl's: a bounded walk), strings and arrays
(creation, blit, bounds checks raising `Invalid_argument`), `format_int`
(Printf's, with libc's `sprint`), the channels (buffers over `read` and
`write`), `exit`.

**An uncaught exception** prints `Fatal error: uncaught exception
Not_found` and exits with 2; checked on ocaml-light for arm64, which,
a quirk to keep, doesn't flush `stdout` first (a `print_string "hi\n"`
before the `raise` is lost).

## 12. The kernel

mini-9pi is OCaml over a C shim (`kernel/lib`): the C starts the
machine, switches between processes' kernel stacks (`k_swtch`), and
calls OCaml on a trap, an interrupt, a fault (`caml_named_value`,
`callback`); the OCaml calls C through 81 `external`s. With ocaml-light
the switch saves five of the runtime's globals per process and the
collector walks the sleeping stacks through a hook
(`kernel/lib/runtime.c`'s header says how). With mini-ml, a process
owns a value stack; the switch saves its pointer and the exception
handler's, and the collector scans every process's value stack. The
kernel is then built by ix's tools alone (plan_ml.md, decision 8):
mini-ld's kernel image, the shim through mini-cc, the start in Plan
9's assembly. On the way, `mini-ml -gas` prints GNU assembly
(`languages/ml/Gas.ml`, one removable module), so that mini-ml's code runs in
the kernel while gcc still builds the rest.

## 13. Compared with ocaml-light, camlboot and MinCaml

| | ocaml-light's ocamlopt | camlboot's minicomp | MinCaml | mini-ml |
|---|---|---|---|---|
| input | OCaml 1.07, no objects or functors | MiniML, an OCaml subset | a tiny ML, no polymorphism or variants | ocaml-light's, what mini-9pi uses |
| types | inferred | none: the program is trusted | inferred, monomorphic | inferred, then forgotten |
| matching | backtracking automata | clauses compiled to tests | none (no variants) | clauses in order, a switch |
| back end | selection, liveness, coloring | to OCaml bytecode | register allocation, SPARC and PowerPC | a stack machine in registers |
| roots | frame tables | the bytecode interpreter's | no collector | a value stack |
| collector | generational, incremental | ocamlrun's | none | Cheney's |
| written in | OCaml | Scheme | OCaml | OCaml |

(camlboot's from its paper, 2022; MinCaml's from memory, to check.)

## 14. The one-file variant

`tiny/TinyML.ml` (plan_ml.md, "Outside the compiler"): the same design
for a smaller ML, no modules, records or arrays, in one file for
TinyAssembler, with a runtime compiled by tiny-c. Built first, to test
§10 and §11's design cheaply.

## 15. How it is tested

Each program through mini-ml and ocaml-light, run, the outputs compared
(the behavior is the contract: plan_ml.md, decision 2); the collector's
law (the output doesn't depend on the heap's size, and a tiny heap
collects everywhere); the type checker's `-i` against ocaml-light's; a
fuzzer of well-typed programs; and mini-9pi's sessions.

## 16. Exercises

1. Tagged arithmetic: derive `a * b` on tagged integers, and find why
   `(a - 1) * (b >> 1) + 1` is right for negative `b`.
2. Write the tests of §7's example with a decision tree instead, and
   count the tests saved.
3. Change the collector to Cheney's with a *depth-first* copy (a
   stack), and measure which one keeps a list's cells together.
4. Why must `let r = ref []` not be generalized? Write the program that
   would crash if it were.
5. Remove the spill of one variable before a call, and find the test
   of the collector's law that fails.
6. Keep one value across calls in a register the callee saves, and
   say what the collector must then know about frames.

## 17. In ix

mini-ml is the toolchain's second front end (after mini-cc), its
objects mini-asm's, linked by mini-ld; its runtime is compiled by
mini-cc; its first real program is mini-9pi, the kernel that runs
principia's programs, and then its own.

## Glossary

- **Block**: a heap value, a header then fields.
- **Boxed**: kept in a block, reached by a pointer (a float, here).
- **Closure**: a function's code with the values of its free variables.
- **Eval/apply**: calls where the caller checks the callee's arity.
- **Forwarding address**: where a copied block went, left in its old
  place.
- **Generalization**: turning a type's variables into parameters, at a
  `let`.
- **Level**: the `let` depth a type variable belongs to.
- **Root**: a value the collector starts from.
- **Tagged integer**: `2n+1`, an integer that can't be a pointer.
- **Value stack**: mini-ml's stack of the values live across calls.
- **Value restriction**: only syntactic values are generalized.

## References

Robin Milner, "A Theory of Type Polymorphism in Programming" (JCSS,
1978); Luis Damas and Robin Milner, "Principal type-schemes for
functional programs" (POPL 1982); Didier Rémy, "Extension of ML type
system with a sorted equational theory on types" (INRIA, 1992), the
levels; Oleg Kiselyov, "How OCaml type checker works" (2013); Andrew
Wright, "Simple imperative polymorphism" (1995); Lennart Augustsson,
"Compiling pattern matching" (1985); Fabrice Le Fessant and Luc
Maranget, "Optimizing pattern matching" (ICFP 2001); Luc Maranget,
"Compiling pattern matching to good decision trees" (ML Workshop 2008);
Simon Marlow and Simon Peyton Jones, "Making a fast curry" (ICFP 2004);
C. J. Cheney, "A nonrecursive list compacting algorithm" (CACM, 1970);
Fergus Henderson, "Accurate garbage collection in an uncooperative
environment" (ISMM 2002); Xavier Leroy, "The ZINC experiment" (INRIA,
1990); Nathanaëlle Courant, Julien Lepiller and Gabriel Scherer,
"Debootstrapping without Archeology: Stacked Implementations in
Camlboot" (Programming, 2022); Eijiro Sumii, "MinCaml: a simple and
efficient compiler for a minimal functional language" (FDPE 2005);
Niklaus Wirth, *Compiler Construction* (1996). Dates and venues from
memory but camlboot's (its paper, in `~/ocaml-light/docs/papers/`),
to be checked before quoting.
