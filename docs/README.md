# docs/

The documents of ix, written with Claude Code: for each program, a
**plan** (`plans/`, what gets built and in what order, with its Status
log), a **tutorial** (`tutorials/`, how it works from scratch, for a
reader of the code), and a **related-work note** (`related-work/`,
where it sits among the real systems). `yoann_notes/` is the author's.

| program | plan | tutorial | related work | code |
|---|---|---|---|---|
| TinyMk, the build system | [plan_mk.md](plans/plan_mk.md) | [notes_mk.md](tutorials/notes_mk.md) | [notes_mk_related_work.md](related-work/notes_mk_related_work.md) | `builder/`, `tiny/TinyBuildSystem.ml` |
| TinyRc, the shell | [plan_rc.md](plans/plan_rc.md) | [notes_rc.md](tutorials/notes_rc.md) | [notes_rc_related_work.md](related-work/notes_rc_related_work.md) | `shell/`, `tiny/TinyShell.ml` |
| TinyEd, the editor | [plan_ed.md](plans/plan_ed.md) | [notes_ed.md](tutorials/notes_ed.md) | [notes_ed_related_work.md](related-work/notes_ed_related_work.md) | `editor/`, `tiny/TinyEditor.ml` |
| TinyAsm and TinyLd, the assembler and the linker | [plan_asm.md](plans/plan_asm.md) | [notes_asm.md](tutorials/notes_asm.md) | [notes_asm_related_work.md](related-work/notes_asm_related_work.md) | `assembler/`, `linker/`, `tiny/TinyAssembler.ml` |
| TinyCompiler, the C compiler | [plan_cc.md](plans/plan_cc.md) | [notes_cc.md](tutorials/notes_cc.md) | [notes_cc_related_work.md](related-work/notes_cc_related_work.md) | `compiler/`, `tiny/TinyC.ml` |
| TinyDb, the relational database | [plan_db.md](plans/plan_db.md) | [notes_db.md](tutorials/notes_db.md) | [notes_db_related_work.md](related-work/notes_db_related_work.md) | `database/`, `tiny/TinyDatabase.ml` (later) |

## The principles

They were first stated in [plan_mk.md](plans/plan_mk.md), the first
plan, which said they would move here when a second plan started; the
lessons of building TinyMk are folded in. They descend from the
Playground's (`~/playground/docs/claude_notes/README.md`), and a
plan restates only where it differs.

1. **Tiny, not toy: functionally equivalent on what real inputs use.**
   Every feature of the original is kept by default, and dropped only
   when that saves a lot of code or complexity; each drop is named in
   the plan, with how often real inputs use it (counted over
   principia's and xix's own files) and what it saves. Counts guide the
   choice; they don't make it -- it is a judgment.
2. **A different design, not a shorter copy.** principia's C and xix's
   OCaml are the specification and the inspiration, not the template.
   Each plan says where its design departs from both and why that is
   smaller -- and keeps the design that turned out wrong in its Status
   (TinyMk's first one did).
3. **Differential tests against a runnable reference.** The same input
   through the Tiny program and the real one, outputs compared exactly.
   The reference is a binary that runs today (for TinyMk, 9base's mk,
   `/usr/lib/plan9/bin/mk`), and **the program is the specification,
   the man page a hint**: where they disagree, the program wins (mk(1)
   was wrong about command-line assignments). Quirks the reference
   has are kept, each with a corpus case; the few differences made on
   purpose are documented, each with an expected output of its own
   (`case.tiny.out` beside the reference's `case.out`).
4. **Test against the field's own laws**, where it has them (for a
   build system: correct, minimal, idempotent, parallel = sequential).
5. **The `.mli` explains, and the tests check its worked example**: an
   ASCII diagram, concrete numbers, a reference with its year. Check a
   worked example on the reference before writing it down.
6. **Deterministic, therefore testable**: no wall clock or file system
   buried in the logic; the outside world is a record of functions, so
   tests can fake it.
7. **OS access through capabilities** (`Cap.*`, the `caps` package from
   opam, xix's).
8. **The simple version stays, beside the better one, switchable.**
9. **Several files for the faithful program, lex/yacc where the grammar
   nests; then a free variant in one file.** Once the faithful program
   is done, a second one drops compatibility and keeps only the idea,
   in a single `TinyXxx.ml` under the top-level `tiny/`, beside its
   siblings (`tiny/TinyBuildSystem.ml`: 261 lines of code
   against TinyMk's 1,398), so the one-file programs read as a set. Choosing its features is the hard part:
   fundamental enough to do real work, checked on a real input, and
   not too big.
   Code that several programs really share may go into an intermediate
   library: the top-level `lib_core/` for the programs (now whole
   files, children and pipes, and the console, through the
   capabilities), or a `tiny/TinyLibXxx.ml` for the one-file
   variants, which are then one file plus the libraries they name.
   Factor what is duplicated in fact, not in advance.
10. **Honest, and counted**: lines per module against the twins in the
    Status, the ceiling stated up front, a target set before and
    compared after (TinyMk missed its 750 by a factor of 2.4), and
    dates and names from memory marked as such.
11. **Comments describe the code as it is**; new comments in existing
    code are tagged `claude:`.
12. **The data are OCaml variants, checked by the compiler.** A closed
    set -- operators, kinds, classes, storage, a statement's forms, a
    node's addressability -- is a variant, never a string, an integer
    code or a bit set: a misspelled `"<="` or a case forgotten is then
    a compile error, not a wrong output. Concretely:
    - **Split a type until every match is exhaustive** without a
      catch-all or an `assert false` (TinyC's `binop = A of arith | R
      of rel`: the machine matches arithmetic and relations apart).
    - **Trees are ADTs** (an expression's kind with its attributes;
      statements, declarators, initializers each a type of their own),
      not one node with an op, a left and a right; **passes are
      functions from a tree to a tree**, not rewrites in place.
    - **Desugar to fewer forms** where the output allows it (TinyC's
      `&&`, `||`, `!` as `?:`, `while` as `for`): fewer constructors,
      fewer cases in every match.
    - **The output is the contract, the representation is free**: a
      twin matches its reference byte for byte (compiler/'s listings
      are 5c's and 7c's), yet keeps the C original's shape only where
      the output depends on it (allocation order, sort ties, number
      formats); `-x`'s dump became the ADT's own.
    - **An `(* old: ... *)` note** on the new type says, in two or
      three lines, what it replaced and what that allowed (a crash, a
      catch-all, a sentinel): the software engineering lesson, kept
      short (the history is in git), and marked, since other comments
      describe the code as it is (principle 11).
    - Clarity first, fewer lines second: the rewrite of compiler/'s
      trees removed 134 uses of `Tree.l n`, 80 tests of `.op` and two
      thirds of the assignments to fields, for 75 lines fewer.

## Bugs found in the references

What the differential tests and the ports found in the programs ix is
tested against, for their authors to decide:
[`plan_bugs_goken.md`](plan_bugs_goken.md) (goken's toolchain and
sources, principia's C, 9base and plan9port) and
[`plan_bugs_xix.md`](plan_bugs_xix.md) (xix's omk and orc, and what
its toolchain doesn't do yet that goken's output depends on). TinyDb's found some in chidb
([`plan_bugs_chidb.md`](plan_bugs_chidb.md)), and its fuzzer one in
OCaml's arm64 native code generator
([`plan_bugs_ocaml.md`](plan_bugs_ocaml.md)).

## References in the code

The classic papers and books behind an idea are cited next to the
code that implements it, as in the Playground's `.mli` files
(`~/playground/physics/3d/Collide3d.mli`): a `References:` paragraph
at the end of the module's header comment, in the `.mli` when there
is one (the `.ml` otherwise, as for the one-file programs of
`tiny/`). Each reference says what the paper did (its problem, its
machine), which function or idea of the module uses it, and where
this code differs or took the other road: Feldman's "Make" (1979) in
`builder/Graph.mli`, Thompson's regular expression search (1968) in
`editor/Regex.mli`, Szymanski's span-dependent instructions (1978)
in `linker/Arm.mli`, as the road not taken. They are checked, not
quoted from memory: a quote is from the paper itself (principia has
the Plan 9 ones, under `builders/docs/`, `shells/docs/`,
`assemblers/docs/` and `compilers/docs/`), and a detail that could
not be checked -- a page, an issue, a chapter -- is left out. The
related-work notes (`related-work/`) have the longer story, and the
works that are not tied to one module.
