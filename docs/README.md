# docs/

The documents of ix, written with Claude Code: for each program, a
**plan** (`plans/`, what gets built and in what order, with its Status
log), a **tutorial** (`tutorials/`, how it works from scratch, for a
reader of the code), and a **related-work note** (`related-work/`,
where it sits among the real systems). `yoann_notes/` is the author's.

| program | plan | tutorial | related work | code |
|---|---|---|---|---|
| TinyMk, the build system | [plan_mk.md](plans/plan_mk.md) | [notes_mk.md](tutorials/notes_mk.md) | [notes_mk_related_work.md](related-work/notes_mk_related_work.md) | `builder/`, `builder/tiny/TinyBuildSystem.ml` |
| TinyRc, the shell | [plan_rc.md](plans/plan_rc.md) | [notes_rc.md](tutorials/notes_rc.md) | [notes_rc_related_work.md](related-work/notes_rc_related_work.md) | `shell/` (to come) |

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
   in a single `TinyXxx.ml` (TinyBuildSystem.ml: 261 lines of code
   against TinyMk's 1,398). Choosing its features is the hard part:
   fundamental enough to do real work, checked on a real input, and
   not too big.
10. **Honest, and counted**: lines per module against the twins in the
    Status, the ceiling stated up front, a target set before and
    compared after (TinyMk missed its 750 by a factor of 2.4), and
    dates and names from memory marked as such.
11. **Comments describe the code as it is**; new comments in existing
    code are tagged `claude:`.
