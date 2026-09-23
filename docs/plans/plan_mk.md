# Plan: TinyMk, a build system from scratch, for teaching (`builder/`)

Companions:
[`notes_mk.md`](../tutorials/notes_mk.md), the tutorial: what a
build system is for, the mkfile read line by line, patterns and stems,
the graph, date stamps, recipes, parallel jobs, and the laws a build
must obey. And
[`notes_mk_related_work.md`](../related-work/notes_mk_related_work.md):
Make, mk, redo, Ninja, tup, Shake, Bazel, dune, and the theory that
classifies them. The twins are the Principia book `builders/Make.nw`
(mk in C, 4,280 lines by the book's own count) and xix's `builder/`
(omk, mk in OCaml, 2,761 lines).

## Context

This is the first ix program, so it goes first for reasons beyond
itself:

- **It is standalone.** It needs `fork`, `exec`, `wait` and `stat`
  from the host, and nothing from the rest of ix. The emulator, the
  kernel and the toolchain all depend on decisions still open (the ARM
  subset, how an OCaml program runs on TinyKernel). mk doesn't.
- **Two references can be run today.** plan9port's mk is
  `/usr/lib/plan9/bin/mk` and xix's omk is in opam. So differential
  testing, the README's "run it on both and compare", works from the
  first commit, as it will later for the emulator against qemu-arm.
- **It builds the others.** Principia and xix are built with mk, and
  ix's programs will be too, eventually with TinyMk itself.
- **It sets the ix conventions on a small program**: the layout, the
  `Cap` style, Testo, how an `.mli` explains, how a plan logs. These
  documents are the first of their kind here, and they are meant to be
  checked for style before the next ones are written.

mk is Andrew Hume's successor to make (USENIX, 1987), later
Plan 9's build tool. Compared with make, it has no built-in rules,
virtual targets as an attribute, `%` metarules and regular-expression
rules, parallel recipes (`$NPROC`), and it gives the whole recipe to one
shell. It is a small, real language with a real algorithm under it.
That is why it is worth a Tiny version.

## Principles

ix inherits most of the Playground's rules
(`~/playground/docs/claude_notes/README.md`), but a whole computer
changes some of them. This is the first plan, so the full list is
here. It moves to `docs/README.md` when a second plan starts, and later
plans list only their differences.

1. **Tiny, not toy: functionally equivalent on what real inputs use.**
   Every feature of the original is kept by default. A feature is
   dropped only when that saves a lot of code or a lot of complexity.
   Each dropped feature is named in this plan, with how often real
   inputs use it and what dropping it saves in lines. For mk, the real
   inputs are the 472 mkfiles of xix, counted below.
2. **A different design, not a shorter copy.** principia's C and xix's
   OCaml are the specification and the inspiration, not the template.
   Each plan says where its design departs from both, and why that
   makes it smaller. Where the obvious design turns out to be wrong,
   the plan says so in its Status. (This one did: see "Groundwork
   decisions", 4.)
3. **Differential tests against the real thing.** The same input goes
   to the Tiny program and to the full-size one, and their outputs are
   compared. For mk, `mk -n` output and the files a build leaves are
   compared across TinyMk, plan9port mk and omk. Where the twins
   disagree, a test records who is right and why.
4. **Test against the field's own laws.** For a build system these are
   correctness, minimality and idempotence (Mokhov, Mitchell and Peyton
   Jones, 2018), and "parallel gives the same result as sequential".
   Worked examples catch typos; laws catch misunderstandings.
5. **The `.mli` explains, and the tests check its worked example.** It
   has an ASCII diagram, concrete numbers, and the paper or man page the
   idea comes from, with a year. The `.ml` starts with the license and
   `(* See Foo.mli *)`.
6. **Deterministic, therefore testable.** No wall clock or `stat` is
   buried in the logic. The algorithm gets the file system as a
   function (`name -> time option`), so most tests need no files and no
   `sleep 1`.
7. **OS access through capabilities** (`Cap.*`, xix style).
   `Graph` and `Outofdate` can't touch the disk: only `Recipe` and
   `CLI` receive capabilities.
8. **The simple version stays, beside the better one, switchable**, as
   in the Playground. Here that is the sequential build beside
   `$NPROC` jobs, and re-walking the graph beside a counter per node
   (see the tutorial, §9).
9. **Several files, and lex/yacc where they help.** This differs from
   the Playground, where a Tiny program is one file. An ix program is a
   small library of modules, one idea each, plus a `CLI` and a `Main`,
   the way xix is organized. ocamllex and menhir are allowed, and the
   choice is made per program by readability: they are worth it when
   the grammar nests. For mk it doesn't (see "Groundwork decisions",
   1).
10. **Honest, and counted.** The Status section records the lines of
    each module against the twins. The plan states the ceiling up front
    (Out of scope), and marks dates and names from memory as such.
11. **Comments describe the code as it is**, and new comments in
    existing code are tagged `claude:`.

## The interface: mk's, unchanged

No Evan-style API to invent here: the interface is the mkfile
language and `mk`'s command line, and it is kept. A mkfile that mk
builds, TinyMk builds the same way.

The decisions follow data rather than taste. Here is how many of
xix's 472 mkfiles use each feature (`grep -l`, 2026-09-23; principia's
389 give the same proportions):

| feature | mkfiles | TinyMk |
|---|---:|---|
| `<file` include | 425 | kept |
| `:V:` virtual | 187 | kept |
| `%` metarules | 154 | kept |
| `$target` / `$prereq` / `$stem` | 114 / 93 / 56 | kept |
| `${v:A%B=C%D}` substitution | 94 | kept |
| `` `{cmd} `` backquote | 38 | kept |
| `:D:` delete on error | 25 | kept |
| `:Q:` quiet | 23 | kept |
| `$NPROC` | 10 | kept |
| `<\|cmd` pipe include | 4 | kept: about 5 lines once backquote exists |
| `&` metarules | 3 | kept: one more case in `Pattern` |
| `:N:`, `$newprereq`, `$newmember` | 2 each | kept |
| archives, `lib.a(foo.o)` | 2 | kept, late (phase 6): reads `ar` headers |
| `:R:` regexp rules | 1 | kept, late (phase 6): `Pattern` gains a case |
| `:P:` custom out-of-date test | 0 | kept: a function in `Outofdate` |
| `:E:`, `:n:`, `:U:`, `var=U=value` | 0 | kept: one flag each |
| missing intermediates (pretending) | (default in Plan 9's mk) | off, as in principia's mk; see decision 5 |

Command-line flags: `-f -n -e -a -k -t -w -s -i -u -d`, and
`var=value`. `-i` is accepted, and is already TinyMk's behaviour (see
decision 5).

omk drops `:R:`, `&`, `:P:`, archives, private variables, missing
intermediates, several `-f`s, dynamic assignments and patterns,
top-level backquotes and Unicode (`~/xix/builder/CLI.ml`, its
Prelude). TinyMk tries to keep them all, except the missing
intermediates.
The rest of this plan argues that a different design makes that
cheaper, not dearer.

**The command's name is open.** `mk` shadows the host's mk and xix's
`mk`/`omk`. The README's two-letter-name scheme (`ia`, `il`, `ic`...)
has no obvious slot for it. Until that is settled the binary is
`tinymk`.

## Target layout

```
builder/                 library ix_mk + the tinymk executable
  Word.ml(i)             words and lists of words: quoting, $v and ${v},
                         ${v:A%B=C%D}, `{cmd} (through a callback)
  Pattern.ml(i)          a target as a pattern: literal, %, &, :R: regexp;
                         match -> stems, and substitution
  Mkfile.ml(i)           reading: \-newline, #, <file, <|cmd, var=[U=]value,
                         rules and their attributes, recipes; evaluated as
                         read, no AST
  Graph.ml(i)            from a target to an immutable DAG: rule lookup,
                         NREP, vacuous arcs, ambiguous recipes, cycles
  Outofdate.ml(i)        date stamps and the decision; -a, -w, :P:,
                         $newprereq
  Build.ml(i)            the loop: which jobs are ready, $NPROC slots,
                         -n, -t, -k; re-stat after each job
  Recipe.ml(i)           processes: the environment exported, MKSHELL,
                         sh or rc quoting, printing (and :Q:), :D:
  Archive.ml(i)          (phase 6) member times of lib.a(foo.o)
  CLI.ml(i), Main.ml     flags, var=value, MKFLAGS, MKARGS, exit status
builder/tests/           Testo: the .mli examples, the laws, and the
                         differential corpus
builder/tests/corpus/    small mkfiles, each with the expected `mk -n`
                         output recorded from plan9port mk
```

Nine modules, where omk has nineteen (`Globals`, `Flags`, `Ast`,
`Lexer`, `Parser`, `Parse`, `Env`, `Eval`, `Rules`, `Percent`,
`Shellenv`, `Shell`, `File`, `Graph`, `Job`, `Scheduler`, `Outofdate`,
`CLI`, `Main`). Where each of theirs went:

| TinyMk | omk (xix) | mk (principia C) |
|---|---|---|
| `Word` | `Lexer.mll` (the word part), `Eval.eval_word`, `Env` | `lex.c`, `word.c`, `var.c`, `varsub.c`, `rc.c` (part) |
| `Pattern` | `Percent` | `match.c`, `rule.c` (regexps) |
| `Mkfile` | `Lexer.mll`, `Parser.mly`, `Parse`, `Ast`, `Eval`, `Rules` | `parse.c`, `lex.c`, `rule.c`, `symtab.c` |
| `Graph` | `Graph`, `File` | `graph.c`, `file.c` |
| `Outofdate` | `Outofdate` (part) | `mk.c` (`outofdate`, `update`) |
| `Build` | `Outofdate` (`work`), `Scheduler`, `Job` | `mk.c` (`work`), `recipe.c`, `run.c` (part) |
| `Recipe` | `Shell`, `Shellenv`, `Scheduler` (part) | `run.c`, `env.c`, `shprint.c`, `rc.c`, `Posix.c`/`Plan9.c` |
| `CLI`, `Main` | `CLI`, `Main`, `Flags`, `Globals` | `main.c`, `globals.c` |

**The size target**: about 750 lines of `.ml`. That would be a quarter
of omk and a sixth of mk, with more of mk's features than omk has. It
is a target, not a promise, and the Status section will record the
real number module by module. By module: `Word` 110, `Pattern` 60,
`Mkfile` 150, `Graph` 100, `Outofdate` 50, `Build` 90, `Recipe` 90,
`CLI` 80, and `Archive` 60 later.

## Groundwork decisions

### 1. The mkfile is read and evaluated in one pass: no AST, no yacc

mk's semantics already require it. A rule header's variables take the
value they have **when the line is read** (checked on plan9port mk:
`Y=early`, `late:V: $Y`, `Y=changed` makes `late` depend on `early`).
Recipes, by contrast, are expanded later, by the shell. So a parsed
AST is only a stopover between two halves of the same pass, and
omk's `Ast` + `Parser.mly` + `Parse` + `Eval` (539 lines) are what
this decision removes.

Yacc isn't needed because nothing nests. A mkfile is a sequence of
lines, and each line is classified by its first character (`<`, a
tab), or by whether its first unquoted `:` or `=` comes first. The
only structure inside a line is a word: quotes, `$v`, `${v:...}`,
`` `{...} ``. omk's `Lexer.mll` needs lexer states to switch between
rule headers and raw recipe lines. A hand-written reader gets the same
split for free, because recipe lines are never tokenized at all.

**The alternative, kept open until phase 1 is measured**: ocamllex for
`Word` alone, if the hand-written word lexer comes out longer than
about 80 lines or harder to read than the `.mll` would be. This choice
is taken by readability, not dogma (principle 9).

### 2. One kind of rule: the target is a pattern

omk and mk keep simple rules and metarules in separate lists and
handle them by separate code. TinyMk has a single `Pattern.t`:

```ocaml
type t = Literal of string | Percent of string * string   (* A%B *)
       | Amp of string * string | Regexp of Re.re          (* :R: *)
val match_ : t -> string -> stems option    (* Literal: Some [||] *)
```

A simple rule is then a rule whose pattern is `Literal`. Rule lookup
is a single filter over one list. What still separates the two kinds
is mk's lookup policy (simple rules first, their prereqs merged;
metarules only when no simple rule has a recipe), and that policy
lives in `Graph`, stated once.

`:R:` needs a regexp engine. Plan 9's syntax is egrep's, not `Str`'s.
The `re` library's `Re.Posix` reads it as is. Later, ix's TinyGrep will
need a regexp engine of its own, and `Pattern` can switch to it then.
That is a nice cross-program dependency to have in ix.

### 3. The graph is an immutable value, and the build state is two maps

mk's `Node` has five flag bits (`VIRTUAL`, `PROBABLE`, `BEINGMADE`,
`MADE`, `NORECIPE`, plus the pretending ones), and omk's has five
mutable fields. They mix two things: what the graph *is* (known once
it is built) and how far the build *has got* (changing every job).

TinyMk separates them:

```ocaml
(* Graph: built once, never changed *)
type node = { name : string; virtual_ : bool; arcs : arc list }
and arc = { rule : Mkfile.rule; prereq : node option; stems : string array }

(* Build: the only mutable state *)
type state = { times : (string, float) Hashtbl.t;           (* stat, cached *)
               status : (string, [`Running | `Made | `Failed]) Hashtbl.t }
```

`Graph` is then a pure function (rules, and "does this file exist?",
to a node, or an error with the full path of a cycle). Its tests need
no disk.

### 4. The build is mk's loop, re-walked from the root: not plan-then-run

**The first design sketched was wrong, and it is kept here on
purpose.** The tempting tiny design has two phases: walk the graph
once, compute the list of jobs to run (pure, and `-n` is just printing
it), then execute that list with `$NPROC` slots. It would be
smaller than mk's scheduler, and it is *not equivalent*.

mk's `update()` **re-stats a target after its recipe runs**. A recipe
may leave its target untouched. The classic case is
`cmp -s new old || mv new old`, a generated header that is regenerated
but not changed. Then everything that depends on it is still up to
date, and mk does not rebuild it. Checked on plan9port mk: `config.h`
is regenerated identically, and `foo.o` is not recompiled. That is
early cutoff, the property Bazel and Shake get from content hashes,
obtained here from mtimes by accident of the algorithm. A precomputed
plan loses it. (omk goes further: it rejects the same mkfile with
"recipe did not update config.h", which a differential test will
record.)

So `Build` keeps mk's shape. It asks "which out-of-date nodes have all
their prereqs made and aren't running?", starts as many as there are
free slots, waits for one job, re-stats its targets, and asks again.
The question is a pure function of the graph and the two maps. Only
the loop around it does I/O, through `Recipe`. The modes become
parameters of the loop rather than `if`s scattered through
`work`/`dorecipe`/`run`: `-n` prints and marks the target made, `-t`
touches, `-k` keeps going past a failure (blocking only its
ancestors), `-a` makes everything out of date. Re-walking from the
root costs O(nodes) per job, as it does in mk. The optimization (a
pending-prereq count per node, Kahn's 1962 algorithm) comes only if a
measurement asks for it, and then beside the simple version
(principle 8).

### 5. Missing intermediates: off, as in principia's mk

By default, Plan 9's mk *pretends*. Suppose `foo.o` is missing but
`foo` is newer than `foo.c`. mk then gives `foo.o` the time of
`foo.c` and doesn't rebuild. This is mk's most intricate code
(`CANPRETEND`, `PRETENDING`, `unpretend` and a second recursive call:
nearly half of `work()`). The author had already turned it off in
principia, with the reason in the source (`globals.c`, `iflag`):
compiling `principia/libc/` skipped directories because another
directory had already created `libc.a`. omk doesn't have it either.

So TinyMk always builds missing intermediates, which is what
`mk -i` does and what principia's mk does by default. This is the one
feature this plan defers. Phase 6 revisits it if a real mkfile needs
it, with its cost measured (an estimated 40 lines in `Outofdate`), and
the example from Hume's `mk.ms` as its test.

### 6. Times: sub-second, compared the way mk does

Checked on plan9port mk: it compares whole seconds, and treats equal
times as out of date (`mk.c`: "It's a race, and the safer option is
to do extra building"). So a `.o` compiled in the same second as its
`.c` is recompiled on every run until the clock moves on. omk compares
sub-second times with `<`, so equal times count as up to date. TinyMk
takes each side's good half: sub-second times (`Unix.stat`'s float),
compared with mk's `<=`. The differential corpus therefore uses mtimes
whole seconds apart, where all three must agree. The same-second cases
get tests of their own, recording the three answers.

### 7. Unicode: free, at the byte level

In xix, dropping Unicode was a simplification. Here it costs nothing
to keep. In UTF-8, every byte of a multibyte character is 0x80 or
above, so treating all such bytes as word characters makes UTF-8 file
names, quotes, `%` stems and `&` (which stops at `/` and `.`) correct
with no code at all. The one thing that stays byte-level is `:R:`,
where `.` matches a byte, not a character. The `Pattern.mli` says so.

### 8. Which shell runs a recipe

`MKSHELL`, consulted when the mkfile is read, as mk(1) says. It
defaults to `sh` on the host, the way plan9port does, and uses rc's
quoting rules when its first word ends in `rc`. The whole recipe goes
to the shell's standard input, with `-e`, as in mk. Later, when
TinyShell exists, it is one more value of `MKSHELL`, and the first
program to run inside TinyMk's recipes on real work.

### 9. Where `Cap` comes from

This question belongs to all of ix, and it is answered here because
this is the first program to need it: either a dependency on xix's
`caps` library (through opam, if it is published separately) or a copy
under `lib_core/`. The recommendation is the dependency, because
diverging capability types between the twins would make every
comparison noisier. To settle with the author before phase 1.

## Outside mk: other ways to be a tiny build system

The goal is a *Tiny build system*. mk is the natural one to
build, because it is the Principia book's, but it isn't the only
candidate, and some of the others are tinier. What each would give,
and what TinyMk takes from it:

- **redo** (Daniel J. Bernstein's design, around 2003; apenwarr's
  implementation, 2010). No language at all: each target `foo.o` has a
  shell script `foo.o.do`, or a fallback `default.o.do`. A script
  declares its dependencies *while it runs* (`redo-ifchange foo.c`),
  so dependencies are dynamic and always exact. A minimal redo is
  famously about 100 lines of shell. It is the tiniest real build
  system there is, but it can't build the 472 mkfiles, and it is not
  the book's tool. *Taken*: nothing in the code, but a comparison in
  the tutorial (§12), and a good exercise, "TinyRedo in 100 lines of
  OCaml on top of `Build`".
- **Build Systems à la Carte** (Mokhov, Mitchell and Peyton Jones,
  ICFP 2018). A build system is a *scheduler* (topological,
  restarting, suspending) times a *rebuilder* (dirty bit, mtimes,
  verifying traces, constructive traces). Make, Excel, Shake and Bazel
  each come out as about a dozen lines of Haskell. In their terms mk is
  a topological scheduler with a modification-time rebuilder and
  static dependencies. *Taken*: the decomposition itself, as the module
  boundary (`Graph` computes the dependencies, `Build` is the
  scheduler, `Outofdate` is the rebuilder), and the laws of principle
  4.
- **Content hashes instead of mtimes** (Bazel, Shake, dune, Nix).
  They give no same-second races, early cutoff whenever an output
  doesn't change (not just when a recipe is careful), and survive
  `git checkout` changing mtimes. They cost a store of hashes on disk,
  and a hash of every input on every run. *Taken*: an option, not a
  default, since mtimes are mk's semantics. `Outofdate` is the only
  module that changes: a `-H` flag keeps a `.mkhash` file beside the
  mkfile, and the same laws must hold. Phase 7, and a direct measurement of what hashing buys on
  xix's build.
- **Ninja** (Evan Martin, 2012). A deliberately dumb language,
  generated by another tool. No variables to speak of and no
  metarules, just explicit edges, which makes it fast. *Taken*: the
  lesson that the language and the engine can be separated. `Graph`
  takes rules, not text, so a Ninja reader would be one more front end
  of about 100 lines (exercise).
- **tup** (Mike Shal, 2009) watches the files a recipe actually opens,
  and walks from the changed files upward instead of from the target
  downward. Correct by construction, and fast on huge trees. It needs
  a FUSE file system or `ptrace`: not tiny. *Taken*: the upward walk
  as an explanation in the tutorial, and a `-w file` argument, which
  is that idea asked by hand.
- **A build system as an OCaml library** (Shake's approach, in
  Haskell, 2012): rules are code, with the host language's
  abstraction for free, and no mkfile language to read. It would be
  smaller still, but a Tiny mk that can't read an mkfile isn't mk.
  *Not taken.*

The recommendation, then: **mk's language and semantics as the
interface, because "Tiny, not toy" means building the real mkfiles;
à la carte's decomposition as the architecture, because that is what
makes the code smaller; and content hashing as the one feature from
outside mk, optional and switchable.**

## The modules, with their references

The ideas, with their diagrams and numbers, are in
[`notes_mk.md`](../tutorials/notes_mk.md). This is the map from
module to source (from memory where not linked, to be checked when
each `.mli` is written):

- **Word** (§3): mk(1)'s "Environment" section; Tom Duff's rc (1990)
  for quoting and `` `{...} ``; Hume's `mk.ms` for
  `${v:A%B=C%D}`.
- **Pattern** (§4): Stuart Feldman's suffix rules in Make (1976/1979),
  which `%` generalizes; mk(1) for `&` and `:R:`.
- **Mkfile** (§2): mk(1), "The mkfile"; Bob Flandrena, "Plan 9
  Mkfiles" (1995) for how real mkfiles include `mkone`/`mkmany`
  prototypes. That is why `<file` is in 425 of 472 files.
- **Graph** (§5): `graph.c` for NREP, vacuous arcs and ambiguity;
  topological order from Kahn (1962).
- **Outofdate** (§6): `mk.c`'s `outofdate()` and `update()`, including
  the `<=` and the date stamp of a virtual target.
- **Build** (§9): `mk.c`'s `work()` and `run.c`; Mokhov et al. 2018
  for the scheduler and rebuilder split and the laws.
- **Recipe** (§8): `run.c`, `env.c`, `Posix.c`; the POSIX `sh` and
  rc's `/env` conventions for exporting lists.
- **Archive** (phase 6): `archive.c`; the `ar` format (`!<arch>\n`,
  60-byte member headers).

## Tests (what the program is for)

The Playground has games that show what a library is for. For ix
programs the equivalent is real inputs:

- **The corpus**, in `builder/tests/corpus/`: principia's own mk tests
  (`SRC/cmd/mk/tests/`: `hello.mk`, `hello.c`, `world.c`), plus one
  small mkfile per feature in the table above. Each has its `mk -n`
  output recorded from plan9port mk and checked into git, so the tests
  don't need plan9port installed.
- **Live differential runs**, when the references are present
  (`make test-differential`): the same corpus, plus xix's 472
  mkfiles under `-n`, through TinyMk, plan9port mk and omk. The
  number that matters is how many agree, and every disagreement is
  explained.
- **The milestone: TinyMk builds its own twin.** `cd ~/xix/builder &&
  tinymk` builds omk from xix's real `mkfile` (which includes
  `mkconfig`, `mkfiles/mkprog`, `mkcommon`, `mkparser` and a
  generated `.depend`), and the resulting omk passes xix's tests. Then
  all of xix. A Tiny mk that builds the full-size one is the plainest
  way to say "not a toy".
- **Later: ix builds itself.** Once ix's programs have mkfiles, TinyMk
  is how they are built, and the first real user of TinyShell as
  `MKSHELL`.

## Phasing

0. **Groundwork**: the dune layout, `Cap` (decision 9), Testo, the
   corpus recorded from plan9port mk, and `make test-differential`
   running the references alone (as a check that the harness works).
1. **Word and Mkfile**: reading, evaluated as read; `-d p` dumps the
   variables and rules. Tests: each worked example in the two `.mli`s;
   the rules and variables of every corpus mkfile. Measure the word
   lexer against the ocamllex option (decision 1).
2. **Pattern and Graph**: `%`, `&`, NREP, vacuous arcs, ambiguous
   recipes, cycles (with the path printed). Tests: pure, with a fake
   file system; `-d g` dumps the graph as dot.
3. **Outofdate and Build, sequential**: date stamps, `-n -e -a -t
   -w -k`, re-stat after a recipe. `Recipe` with the environment
   exported. Tests: every corpus mkfile's `-n` output equals mk's; the
   early-cutoff mkfile; the laws on generated DAGs.
4. **Parallel**: `$NPROC` slots, `$nproc`, output not interleaved within
   a line. Tests: "parallel = sequential" in files built and contents,
   for NPROC 1-8, on the corpus and on random DAGs from a seed.
5. **The milestone**: omk built by TinyMk from xix's mkfile; then xix;
   the differential numbers over the 472 mkfiles; the LOC count
   against the twins.
6. **The long tail**: `:R:` (with `re`), archives (`Archive`, `:N:`,
   `$newmember`), `-u`; and a decision, by measured lines, on
   pretending (decision 5).
7. **Outside mk**: `-H`, content hashes in `Outofdate`, with the same
   laws, and xix's rebuild times with and without it.
8. **Docs**: `notes_mk.md` checked against the code, its numbers
   measured, and the related-work note's postscript filled in.

## Status

- **2026-09-23, mk chosen as the first ix program** (proposed by
  Claude among mk, rc and 5l, for the reasons in Context). The author's
  directions, as given: use principia's mk and xix's omk as
  inspiration, "but ideally you can come up with a different design
  that leads to even more tiny code (while still being functionally
  equivalent)"; sacrifice features "like I did in xix" only "if the
  simplicity benefit is really big (and also the reduction in LOC)";
  Unicode may go "unless you find a way to have as compact code with
  unicode support too" (decision 7 found one); several files, lex and
  yacc allowed "unless ... handmade parser is more readable"
  (decision 1); and "think outside the box and outside mk" (the
  section of that name).
- **2026-09-23, the measurements behind the feature table**: `grep -l`
  over xix's 472 mkfiles (and principia's 389), one feature at a time.
  These are counts of files, not uses, and some patterns are crude
  (`&` in a rule header, `%` anywhere). To be redone with TinyMk's own
  reader once phase 1 exists, as a check on both.
- **2026-09-23, checked on plan9port mk before writing it down**:
  rule headers are expanded when read; `$X.o` with `X=a b` gives the
  two words `a b.o`, not `a.o b.o` (omk rejects it: "use of list
  variable 'X' in scalar context"); equal and same-second times
  rebuild; a recipe that leaves its target untouched stops the
  rebuild of what depends on it (omk: "recipe did not update"). The
  last one sank the first design (decision 4). And one place where mk(1)
  is wrong about mk: a command-line `CC=z` overrides every assignment
  to `CC`, not only "the first (but not any subsequent)" one. omk
  agrees with the program. The rule for TinyMk: **the program is the
  specification, and the man page is a hint**.
- **The twins, for the LOC comparison to come**: mk (C) 5,980 lines in
  `principia/SRC/cmd/mk/*.[ch]`, 4,280 by the book's own table
  (Make.nw); omk 2,761 lines in `xix/builder/*.ml*`, including 468 of
  `Lexer.mll` and `Parser.mly`.

## Verification

- `make test`: the `.mli` examples, the laws (on generated DAGs, from
  a seed), the corpus against its recorded `mk -n` outputs.
- `make test-differential`, when plan9port mk and omk are installed:
  the agreement count over xix's 472 mkfiles.
- By hand, and then scripted: omk built by TinyMk, passing xix's
  tests.
- Numbers, in this document: lines per module against the twins;
  agreement counts; the time `tinymk -n` takes on all of xix against
  mk's and omk's.

## Out of scope

- Content hashes as the default, remote caches, sandboxing, or
  discovering dependencies by watching the files a recipe opens: what
  Bazel and tup do. They are explained in the related-work note, and
  one of them is phase 7's option.
- A new mkfile syntax, or improvements that change what an existing
  mkfile means. omk's strict mode (errors on redefined or undefined
  variables) is a good idea, but a different language. It could be a
  flag later, never the default.
- Running on TinyKernel. That depends on how ix runs OCaml programs,
  which the README leaves open.

## Related work

In [`notes_mk_related_work.md`](../related-work/notes_mk_related_work.md):
Make's history, mk and its descendants, the modern systems, the
teaching lineage, what OCaml has, and TinyMk's ceiling.
