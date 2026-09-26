# mini-ml vs. the rest of the ML compilers

Where a tiny ML compiler sits among the real ones: the first MLs,
Standard ML's compilers, the Caml line that ocaml-light comes from,
the whole-program and verified ones, the small ones (MinCaml,
camlboot), and the papers behind each of mini-ml's passes: types,
pattern matching, closures, collectors. What they do that ix won't,
and which of their ideas fit in a program small enough to read.
Companions: [`notes_ml.md`](../tutorials/notes_ml.md) (how it works)
and [`plan_ml.md`](../plans/plan_ml.md) (what gets built). The dates
below are from memory unless a source is named, and are to be checked
before relying on them for teaching; camlboot's are from its paper
(`~/ocaml-light/docs/papers/camlboot-paper.pdf`).

## The one-line version

| | What it optimizes for | Between the types and the machine |
|---|---|---|
| LCF's ML (Milner, 1973-78) | A language to write proofs' tactics | an interpreter, in Lisp |
| Cardelli's ML (1980-84) | ML compiled, on a VAX | an abstract machine (FAM), then native code |
| SML/NJ (Appel, MacQueen, 1986-) | Standard ML, fast, one implementation for research | continuation-passing style; frames on the heap |
| Caml (1987), Caml Light (1990) | A small, portable ML | the CAM, then the ZINC bytecode and its interpreter |
| Moscow ML (1994-) | Standard ML on Caml Light's runtime | ZINC bytecode |
| Caml Special Light (1995), OCaml (1996-) | Native code, modules, then objects | Lambda, Cmm, a classic register allocating back end |
| MLton (1997-) | The fastest code, whole programs | defunctorized, monomorphized, no uniform representation |
| CakeML (2014-) | A compiler proved correct | a dozen intermediate languages, each with its proof |
| MinCaml (2005) | A compiler for a course, efficient code | K-normal form, closures, register allocation |
| camlboot (2022) | Building OCaml without a bootstrap binary | an untyped subset compiled to OCaml's bytecode |
| `ml/` (mini-ml) | Seeing what an ML compiler does, on a real kernel | types forgotten; a stack machine; a value stack |

## Part 1: the first MLs

- **LCF's ML** (Robin Milner's group, Edinburgh, 1973-78): the
  metalanguage of a theorem prover, where type inference was invented
  so that a tactic could only build theorems the rules allow. Its
  implementation translated ML to Lisp.
- **Cardelli's ML** (Luca Cardelli, Edinburgh, 1980-84; "Compiling a
  Functional Language", LFP 1984): the first compiler of ML to native
  code, through an abstract machine of his (the FAM). Cardelli also
  wrote "Basic Polymorphic Typechecking" (1987), the type checker
  explained with its code, the best first reading for mini-ml's
  `Typing`.

## Part 2: Standard ML's compilers

- **The Definition of Standard ML** (Milner, Tofte, Harper, 1990;
  revised with MacQueen, 1997): a language defined by its formal
  semantics, with modules, signatures and functors (MacQueen's).
- **SML/NJ** (Andrew Appel and David MacQueen, 1986-; Appel's
  *Compiling with Continuations*, 1992): every function translated to
  continuation-passing style, closures analyzed, and no stack: frames
  are heap blocks, collected by a generational collector. The opposite
  of mini-ml's choice on where values wait during a call; it shows that
  the collector can be the only memory manager.
- **Poly/ML** (David Matthews, 1980s-), **Moscow ML** (Sergei Romanenko
  and Peter Sestoft, 1994-, on Caml Light's runtime and bytecode),
  **HaMLet** (Andreas Rossberg, the Definition as an interpreter).
- **MLton** (Stephen Weeks and others, 1997-): whole-program
  compilation; functors expanded away (defunctorization), polymorphic
  functions copied per type (monomorphization), so values need no
  uniform representation and floats are never boxed. The road not
  taken: it needs the whole program and many passes.
- **CakeML** (Ramana Kumar, Magnus Myreen, Michael Norrish, Scott
  Owens, POPL 2014-): an ML compiler proved correct in HOL4, down to
  machine code, including its collector. What "correct" costs.

## Part 3: the Caml line, ocaml-light's

- **The CAM** (Guy Cousineau, Pierre-Louis Curien, Michel Mauny,
  1985-87): the categorical abstract machine, the first Caml's target
  (1987, on Le_Lisp).
- **Caml Light and the ZINC** (Xavier Leroy, "The ZINC experiment: an
  economical implementation of the ML language", INRIA, 1990; Damien
  Doligez's collector): an ML small enough for a PC, compiled to the
  bytecode of an interpreter in C, with arguments passed on a stack and
  functions applied to several at once (the idea eval/apply
  generalized). Its report is in `~/ocaml-light/docs/reports/`, a scan.
- **Caml Special Light** (1995) and **Objective Caml** (1996-): native
  code, the module system with functors, then objects. The compiler
  ocaml-light is: parsing, typing, Lambda (`bytecomp/`), then either
  bytecode or Cmm and a classic back end (`asmcomp/`: instruction
  selection, liveness, graph coloring, spilling, scheduling), the
  collector generational and incremental (Doligez and Leroy, "A
  concurrent, generational garbage collector for a multithreaded
  implementation of ML", POPL 1993).
- **ocaml-light** (`~/ocaml-light`): OCaml 1.07 without objects and
  functors, for teaching, with a literate book; ported to Plan 9 (its
  bytecode runtime compiled by principia's toolchain), and the compiler
  of ix's kernels. mini-ml's reference, and, where they differ, its
  specification (the program wins, README principle 3).

## Part 4: the small ones

- **MinCaml** (Eijiro Sumii, FDPE 2005): a compiler of a minimal ML (no
  polymorphism, no variants, no collector) in about 2,000 lines of
  OCaml, for a course at Tokyo, with a real back end (K-normal form,
  closure conversion, register allocation) and code close to
  ocamlopt's on its benchmarks. The closest in size; mini-ml keeps what
  MinCaml drops (polymorphism, variants, a collector), and drops what it
  keeps (register allocation).
- **camlboot** (Nathanaëlle Courant, Julien Lepiller, Gabriel Scherer,
  "Debootstrapping without Archeology: Stacked Implementations in
  Camlboot", Programming 2022; checked): to build OCaml 4.07 without a
  bootstrap binary, an interpreter of OCaml (`interp`, 3,000 lines,
  "about four human-weeks") written in a subset, MiniML, compiled to
  OCaml's bytecode by a compiler in Scheme (`minicomp`, a comparable
  effort). Two of its observations shaped the plan. The first,
  OCaml's "type-erasure property": its runtime semantics "can be
  defined independently of its typing derivation", which "lets you
  implement an interpreter without type-checking the programs first" (decision 4: mini-ml's back end
  first, untyped). The second, a warning: "moving from shallow patterns
  to full pattern-matching compilation was probably the most
  time-consuming and invasive addition", a redesign "from one-pass ...
  to a two-pass compiler" (mini-ml has its `Lambda` from the start).
  And functors were added to use the stdlib's `Set` and `Map`, which
  mini-9pi, written for ocaml-light, doesn't use.
- **Abdulaziz Ghuloum**, "An Incremental Approach to Compiler
  Construction" (Scheme Workshop 2006): a compiler of Scheme to x86
  grown in small steps, each a working compiler (integers, then
  primitives, locals, conditionals, heap, procedures, closures, tail
  calls). The order tiny-ml's tutorial can follow.

## Part 5: the papers behind the passes

- **Types**: Roger Hindley (1969) and Robin Milner ("A Theory of Type
  Polymorphism in Programming", 1978), the principal type and
  algorithm W; Luis Damas and Milner ("Principal type-schemes for
  functional programs", POPL 1982), its completeness; Didier Rémy
  (1992), generalization by levels, OCaml's, explained by Oleg
  Kiselyov's "How OCaml type checker works" (2013); Andrew Wright,
  "Simple imperative polymorphism" (1995), the value restriction;
  Benjamin Pierce, *Types and Programming Languages* (2002), chapter
  22.
- **Pattern matching**: Lennart Augustsson, "Compiling pattern
  matching" (1985), and Philip Wadler's chapter in Peyton Jones's book
  (1987), the column-by-column scheme; Fabrice Le Fessant and Luc
  Maranget, "Optimizing pattern matching" (ICFP 2001), backtracking
  automata, ocaml-light's; Luc Maranget, "Warnings for pattern
  matching" (JFP 2007), exhaustiveness and useless clauses, and
  "Compiling pattern matching to good decision trees" (ML Workshop
  2008). mini-ml starts with clauses in order, the scheme these papers
  improve on.
- **Closures and calls**: Peter Landin's SECD machine (1964); Andrew
  Appel and Trevor Jim, "Continuation-passing, closure-passing style"
  (POPL 1989); Zhong Shao and Appel, "Space-efficient closure
  representations" (1994); Simon Marlow and Simon Peyton Jones, "Making
  a fast curry: push/enter vs. eval/apply for higher-order languages"
  (ICFP 2004), which found eval/apply simpler and no slower, and which
  OCaml's `caml_applyN` is an instance of.
- **Collectors and roots**: John McCarthy (1960), mark and sweep, with
  Lisp; Robert Fenichel and Jerome Yochelson (1969), two semispaces;
  C. J. Cheney, "A nonrecursive list compacting algorithm" (CACM
  1970), the breadth-first copy mini-ml's runtime is; David Ungar,
  "Generation scavenging" (1984), and Andrew Appel, "Simple
  generational garbage collection and fast allocation" (1989), the
  better version; Hans Boehm and Mark Weiser (1988), a conservative
  collector for C, which needs no help from the compiler and moves
  nothing, the other road for roots; Amer Diwan, Eliot Moss and Richard
  Hudson, "Compiler support for garbage collection in a statically
  typed language" (PLDI 1992), frame tables, ocaml-light's road;
  Fergus Henderson, "Accurate garbage collection in an uncooperative
  environment" (ISMM 2002), the shadow stack for a compiler that can't
  describe its frames (Henderson's emitted C), mini-ml's value stack;
  Richard Jones, Antony Hosking, Eliot Moss, *The Garbage Collection
  Handbook* (2011).
- **Testing compilers**: Michał Pałka, Koen Claessen, Alejandro Russo,
  John Hughes, "Testing an optimising compiler by generating random
  lambda terms" (2011), well-typed random programs for GHC; Xuejun
  Yang and others, "Finding and understanding bugs in C compilers"
  (Csmith, PLDI 2011).

## Part 6: the books

- Andrew Appel, *Modern Compiler Implementation in ML* (1998): a
  compiler in ML (for Tiger, not ML), with its chapters on closures,
  collectors and polymorphism.
- Simon Peyton Jones, *The Implementation of Functional Programming
  Languages* (1987): type checking and pattern matching compiled, for a
  lazy language.
- Emmanuel Chailloux, Pascal Manoury, Bruno Pagano, *Developing
  Applications with Objective Caml* (2000): its chapters on the
  collector and on interfacing with C are ocaml-light's runtime as a
  user sees it (in `~/ocaml-light/docs/books/`).
- Niklaus Wirth, *Compiler Construction* (1996): the stack of
  registers TinyC's and mini-ml's code generators use.

## What mini-ml takes, and leaves

Takes: Hindley-Milner with levels and the value restriction
(ocaml-light's checker's design); the uniform representation and
ocaml-light's names for it (`Val_long`, `Field`...); Lambda as the
point where the language is gone; eval/apply; Cheney's collector;
Henderson's shadow stack; camlboot's lesson that the back end needs no
types; TinyC's stack machine and mini-cc's records and linker.

Leaves: functors and objects (ocaml-light has none); the register
allocator and the frame tables (ocaml-light's); CPS (SML/NJ's);
whole-program monomorphization (MLton's); proofs (CakeML's); decision
trees and exhaustiveness, for a later phase; unboxed floats.

## Postscript: the numbers (to come)

mini-ml's lines against the target and ocaml-light's, and what the
value stack costs in speed against ocamlopt, on `test/`'s programs,
once built.
