# A build system, from scratch: a tutorial for `builder/`

What a build system does, and how mk does it: a mkfile read line by
line, targets matched against patterns, a graph of dependencies built
from them, date stamps deciding what is out of date, and recipes run
by a shell, several at a time. It is written for **a reader of
TinyMk's code, not a user of mk**, and it explains the ideas in the
order the code needs them.

It is the specification of the program planned in
[`plan_mk.md`](../plans/plan_mk.md), written before the code, to be
checked against it and have its numbers measured. Companions:
[`notes_mk_related_work.md`](../related-work/notes_mk_related_work.md)
(Make, mk, redo, Ninja, Shake, Bazel, and where TinyMk stops). Its
full-size twins are the Principia book `builders/Make.nw` (the C
mk, explained chunk by chunk) and xix's `builder/` (omk). This
tutorial names both where TinyMk does something differently.

## 0. Where the code is, and a reading order

| module (`builder/`) | what | section |
|---|---|---|
| `Word` | quoting, `$v`, `${v:A%B=C%D}`, `` `{cmd} ``: a line to a list of words | §3 |
| `Pattern` | literal, `%`, `&`, `:R:`: does a name match, and with which stem | §4 |
| `Mkfile` | the mkfile read and evaluated in one pass: variables and rules | §2 |
| `Graph` | from a target to a DAG: which rules apply, NREP, ambiguity, cycles | §5 |
| `Outofdate` | date stamps, and the decision "must this be remade?" | §6, §7 |
| `Build` | the loop: ready jobs, `$NPROC` slots, re-stat after each | §9 |
| `Recipe` | a process per job: the shell, the environment, `:Q:`, `:D:` | §8 |
| `CLI` | flags, `var=value`, which mkfile, exit status | §11 |

Read §1 for the problem, §2-§4 for the language, §5-§7 for the
algorithm, §8-§9 for running things, §10 for how to know it is right,
and §11-§12 for how it compares with its twins and what is left as
exercises.

## 1. What a build system is for

A program is built from files by commands, and most of those commands
don't need to run again after a small change. The running example is
principia's own mk test, `SRC/cmd/mk/tests/hello.mk`:

```
OBJS=hello.5 world.5

hello: $OBJS
	5l -o hello $OBJS

%.5: %.c
	5c -c $stem.c
```

After editing `world.c`, the right answer is two commands, not
three: `5c -c world.c`, then `5l -o hello hello.5 world.5`. `hello.c`
is not recompiled. A build system is the program that finds that
answer, by knowing:

- **what depends on what** (the rules, and the graph they make, §5);
- **what changed** (date stamps, §6);
- **how to remake each thing** (recipes, §8);
- and, since machines have more than one core, **what can run at the
  same time** (§9).

The first one was Stuart Feldman's Make, at Bell Labs in 1976. The
story, told in *The Art of Unix Programming* (from memory, to check),
is that Steve Johnson had spent a morning debugging a correct program
whose executable had simply not been rebuilt.

## 2. The mkfile, read one line at a time

A mkfile is a sequence of lines, and `Mkfile` reads it in one pass:

```
   backslash-newline   deleted: long lines may be folded
   # to end of line    deleted, unless quoted
   <file               replaced by the file's lines
   <|cmd args          replaced by the command's output
   a line starting     a recipe line of the rule above it (kept raw:
     with a tab/space    the shell will read it, not mk)
   otherwise           an assignment or a rule, by whichever of = and :
                         comes first, unquoted
```

That last line is all the grammar there is: `CC=5c` is an
assignment, `hello: $OBJS` is a rule, and `x='a:b'` is an assignment
because the colon is quoted. Rules may carry attributes between two
colons (`clean:V:`, `%.5:Q: %.c`).

**Evaluated as read.** A variable used in a rule header takes the
value it has *at that line*. Checked on plan9port mk:

```
Y=early
late:V: $Y          <- late depends on "early", read here
Y=changed

early:V:
	echo early Y=$Y     prints "early Y=changed"
```

The recipe sees `changed`, because recipes are expanded later by the
shell, with the variables' final values in its environment. This is
why TinyMk has no AST (plan, decision 1). omk parses the whole file
into an AST and evaluates it afterwards, which is correct but does in
two passes what the semantics lets you do in one.

**Where a variable's value comes from**, lowest priority first: the
built-in defaults, mk's environment, the mkfile, and the command line.
The command line has one twist, and the man page and the program
disagree about it. mk(1) says `mk CC=z` "overrides the first (but not
any subsequent) assignment". But on plan9port mk, with `CC=a`,
`x:V: $CC`, `CC=b`, `y:V: $CC`, both `x` and `y` get `z`: every
assignment is overridden. omk agrees with the program. TinyMk follows
the program, and a test records the discrepancy.

## 3. Words, and lists of words

Every value in mk is a **list of words**. `OBJS=hello.5 world.5` is
two words, and `$OBJS` in a rule header gives two prerequisites.
`Word` turns the text of a line into such a list:

- **quoting** is rc's and sh's: `'a b'` is one word, and `''` inside
  quotes is a quote;
- **`$name` and `${name}`**, the braces being needed when a letter
  follows (`${name}s`);
- **`${name:A%B=C%D}`** rewrites each word that matches `A%B`. It is
  the most used trick in real mkfiles (94 of xix's 472), and
  `mkfiles/mkprog` is the example:

  ```
     SRC=Ast.ml Main.ml
     OBJS=${SRC:%.ml=%.cmo}      ->  Ast.cmo Main.cmo
                                     (A="", B=".ml", C="", D=".cmo")
  ```
- **`` `{cmd} ``** runs `cmd` in the shell, when the line is read, and
  its output, split into words, takes its place. `Word` doesn't run
  anything itself: it gets a callback, so its tests don't need a
  shell (plan, principle 7).

**Concatenation with a list is not distribution.** With `X=a b`,
`$X.o` gives the two words `a` and `b.o`, not `a.o b.o` (checked on
plan9port mk: "don't know how to make 'a'"). rc would distribute. mk
glues the text onto the list's last word. omk rejects this outright
("use of list variable 'X' in scalar context"). That is safer, but it
changes what an existing mkfile means, so TinyMk does what mk does,
and a differential test records the three answers.

**Unicode costs nothing.** Every byte of a UTF-8 multibyte character
is 0x80 or above, so a lexer that treats such bytes as word characters
handles UTF-8 names without a line of Unicode code (plan, decision 7).

## 4. Patterns and stems

A rule's target is a **pattern**, and one type covers all four kinds
(`Pattern`):

```
   pattern      name            stems           kind
   hello        hello           [||]            literal: a simple rule
   %.5          hello.5         [|"hello"|]     % : any string
   %.5          dir/hello.5     [|"dir/hello"|]
   &.5          dir/hello.5     no match        & : no '/' and no '.'
   (.*)\.5  :R: hello.5         [|"hello.5"; "hello"|]   regexp: $stem0..$stem9
```

The stem is what the recipe calls `$stem`. The prerequisites are
the rule's prerequisite patterns with the stem put back
(`Pattern.subst`), so `%.5: %.c` matched on `hello.5` wants
`hello.c`.

`%` generalizes make's **suffix rules** (`.c.o:`, Feldman 1976),
which could only say "a file with this extension comes from the file
with that one". mk's `%` can be anywhere: `lib%.a`, `%/mkfile`,
`test-%:V:`.

## 5. From a target to a graph

`Graph` answers, for one target: which rules apply, and recursively
for their prerequisites. hello.mk, from `hello`:

```
                 hello                 rule "hello: $OBJS" (a recipe)
                /     \
          hello.5     world.5          rule "%.5: %.c", stems hello, world
             |           |
          hello.c     world.c          no rule: they must exist as files
```

The lookup follows mk's policy, and this is the one place where
simple rules and metarules are treated differently:

1. **All the simple rules for the target are merged.** Their
   prerequisites are added up, and at most one of them may have a
   recipe. Two recipes with different prerequisites is mk's
   "ambiguous recipe" error. The same prerequisites means the second
   rule overrides the first.
2. **Metarules are tried only if no simple rule has a recipe.** Each
   matching metarule gives a candidate arc.
3. **A candidate is vacuous if its prerequisites can't be made**,
   that is, if they neither exist nor have a rule, recursively. Vacuous
   candidates are dropped. With both `%.5: %.c` and `%.5: %.s`, and
   only `hello.c` on disk, `hello.5` comes from the `.c`. If both
   `hello.c` and `hello.s` exist, that is ambiguous, and an error.
4. **NREP**: a metarule may be used at most `$NREP` times (default 1)
   on any path from the root. Without that limit, `%: %.gz` would look
   for `foo.gz`, then `foo.gz.gz`, forever.
5. **A cycle** (`a: b`, `b: a`) is an error, and TinyMk prints the
   whole path (`a -> b -> a`), as omk does. mk prints only the node
   where it noticed.

The result is an immutable value: nodes, arcs to prerequisite nodes,
shared when two targets need the same file (`mkfiles/mkcommon`'s
`.depend` makes that common). mk and omk store the build's progress in
the nodes themselves (flag bits in C, mutable fields in OCaml). TinyMk
keeps the graph fixed and the progress elsewhere (§9). Tests can then
build a graph from a fake file system, with no disk.

## 6. Out of date, or not

A target must be remade if it is older than any of its
prerequisites. That needs a **date stamp** for every node, and mk's
rules for it are subtler than "the file's mtime" (mk(1), `mk.c`'s
`update()`):

```
   a file that exists       its modification time
   a file that doesn't      0 before it is made; afterwards, re-stat it,
                              and if still missing: the newest of its
                              prerequisites' stamps
   a virtual target (:V:)   0 before; afterwards, the newest of its
                              prerequisites' stamps
```

and the test itself is `target <= prereq`: **equal times count as out
of date**. `mk.c` says why: "It's a race, and the safer option is to
do extra building rather than not enough." The three twins, on
`foo.o: foo.c` (checked on plan9port mk and omk, 2026-09-23):

```
   foo.c        foo.o          plan9port mk      omk              TinyMk
   10:00:00     10:00:00       rebuilds          up to date       rebuilds
   10:00:00.2   10:00:00.7     rebuilds          up to date       up to date
   10:00:00.7   10:00:00.2     rebuilds          rebuilds         rebuilds
```

mk has whole seconds, so it can't tell the second row from the first,
and recompiles a `.o` built in the same second as its source on every
run until the clock moves on. omk has sub-second times but uses `<`,
so a real tie counts as up to date. TinyMk uses sub-second times with
mk's `<=` (plan, decision 6).

Three flags change the question rather than the answer: `-a` (every
target is out of date), `-w file` (pretend `file` was just modified:
"what would a change here rebuild?"), and the `:P:cmd:` attribute
(ask `cmd target prereq` instead of comparing times; its exit status
decides). They are three ways of replacing one function, which is
why `Outofdate` is a module of its own.

**Re-stat after the recipe, and what that buys.** Once a recipe has
run, mk looks at the target's time again rather than assuming it
changed. So a recipe that decides *not* to touch its target stops the
rebuild there:

```
foo.o: config.h
	5c -c foo.c
config.h: config.in
	./gen config.in >config.h.new
	cmp -s config.h.new config.h || mv config.h.new config.h
```

When `config.in` changes but the generated header doesn't, `config.h`
keeps its old time, and `foo.o` is not recompiled (checked on
plan9port mk). This is **early cutoff**, which Bazel and Shake get
from content hashes (related work, Part 2). Here it falls out of the
order of two lines in `update()`. It also constrains the design. The
build can't be planned in advance and then executed, because what is
out of date depends on what the recipes actually did. That is why
TinyMk's `Build` asks the question again after every job (§9; the
plan's decision 4 records the design this ruled out).

## 7. Missing intermediates: what mk does, and TinyMk doesn't

Plan 9's mk has one more rule, on by default. Suppose `foo.o` is
missing, but `foo` is newer than `foo.c`. Then mk *pretends* `foo.o`
exists, with the stamp of `foo.c`, and builds nothing: the executable
is up to date with the source, so why compile an object file only to
link it into the same thing? This is make's `.SECONDARY`, made
automatic.

It takes nearly half of `mk.c`'s `work()` (a node may pretend,
be caught pretending by a parent that is out of date for another
reason, and be "unpretended" and built after all). It also misfires
in practice: principia's mk turned it off by default, after compiling
`libc/` skipped directories because another directory had already
made `libc.a` (`globals.c`, the comment on `iflag`). TinyMk always
builds a missing intermediate, which is what `mk -i` does. The plan's
phase 6 decides whether to add pretending back, with its lines
counted.

## 8. Running a recipe

A job is a node to remake, its rule's recipe, and the values that go
with it. `Recipe` runs it:

- **The whole recipe goes to one shell**, on its standard input, with
  `-e`, so the first failing command stops it. This is the biggest
  practical difference with make, which runs each line in a shell of
  its own:

  ```
  install:V:
  	cd sub
  	cp prog /bin      mk: copies sub/prog.  make: copies ./prog
  ```

- **The shell** is `$MKSHELL`: `sh` by default on a Unix host, rc if
  the mkfile says so. mk reads it when the mkfile is *read*, so one
  mkfile can use both, and each included file starts with `sh` again
  (mk(1)). TinyShell, when it exists, is one more value.
- **The environment**: every variable of the mkfile is exported
  (except those assigned with `var=U=value`), plus the job's own:

  ```
     for hello.5, from %.5: %.c
     target=hello.5  prereq=hello.c  stem=hello
     newprereq=...   the prerequisites newer than the target
     alltarget=...   every target of the rule (a b: c makes both)
     nproc=0..NPROC-1  which slot runs it     pid=...
  ```

  A list is exported with its words separated by spaces for `sh`. rc
  wants real lists, which Plan 9 passes through `/env` (the exact
  convention is plan9port's `Posix.c` against principia's `Plan9.c`,
  to be checked when `Recipe` is written).
- **Printing**: the recipe is printed before it runs, unless the rule
  is `:Q:`. mk(1)'s bugs section warns that the printed version
  expands variables "sometimes erroneously" ("Don't trust what's
  printed"). TinyMk prints the recipe unexpanded, which is at least
  never wrong. That output differs from mk's, so the differential
  tests compare the commands run rather than the lines printed.
- **Failure**: mk stops (or, with `-k`, goes on with whatever doesn't
  depend on the failed target). With `:D:` the target is deleted, so
  a half-written file doesn't look up to date next time. `:E:` makes
  a failure not count.

## 9. The loop, and several jobs at once

`Build` is the whole algorithm, and it fits in a picture:

```
   loop:
     ready = the out-of-date nodes whose prerequisites are all made,
             not running, not failed          (walk from the root, §5-§6)
     start ready jobs while fewer than $NPROC run
     if nothing runs: done (or: "don't know how to make ...")
     wait for one job; re-stat its targets (§6); mark them made or failed
```

The only mutable state is two tables: the date stamps seen so far,
and each node's progress (`Running`, `Made`, `Failed`). The walk that
computes `ready` is a pure function of the graph and those tables.
Only the loop does I/O, through `Recipe`. The modes are what "start a
job" means: `-n` prints the recipe and marks its targets made as of
now, `-t` touches the targets instead, and otherwise it forks the
shell.

With `NPROC=2`, hello.mk from scratch:

```
   time ->
   slot 0:  [ 5c -c hello.c ]            [ 5l -o hello hello.5 world.5 ]
   slot 1:  [ 5c -c world.c ]
                            ^ both .5 made: hello becomes ready
```

`NPROC=1` must print exactly what `mk -n` prints, in the same order.
That order is a depth-first walk from the target, prerequisites in
mkfile order, and it is the first differential test.

**The simple version, and the faster one.** Re-walking the whole
graph after every job costs O(nodes) per job, O(n²) in all. mk does
the same, and for xix's biggest directories (hundreds of files, not
millions) it is to be measured before it is changed. The faster
version keeps, for each node, the count of prerequisites not yet
made, and puts a node in the ready queue when its count reaches zero
(Kahn's topological sort, 1962). If it is ever needed, it is written
beside the re-walk and switched by a flag, and the "parallel =
sequential" law of §10 checks that the two agree (plan, principle 8).

## 10. How to know it is right: the laws

A build system can be wrong in only a few ways, and Mokhov, Mitchell
and Peyton Jones named them (*Build Systems à la Carte*, 2018). Each
is a test here, run on the corpus and on random DAGs generated from a
seed:

```
   correct      after a build, every target is what a clean build
                  would have made               (compare the files)
   minimal      a recipe runs only if something it depends on
                  changed            (touch one leaf, count the jobs)
   idempotent   a second build runs nothing  ("'x' is up to date")
   parallel     NPROC=4 makes the same files as NPROC=1, and never
                  starts a job before its prerequisites are made
```

Minimality has an exact version on a DAG: touching one file must
remake exactly the targets that depend on it and have a recipe,
directly or through other targets, and nothing else. §6's early
cutoff is the allowed exception. Its test checks that the cutoff
happens when the recipe leaves the file alone, and only then.

And the differential tests (plan, "Tests"): the same mkfiles under
`-n`, through TinyMk, plan9port mk and omk, where every disagreement
is either a bug or an entry in §6's or §3's tables.

## 11. Compared with mk and omk

The same language and nearly the same semantics, reached by a
different route:

| | mk (C, principia) | omk (OCaml, xix) | TinyMk |
|---|---|---|---|
| reading | hand-written, evaluated as read | ocamllex + menhir, an AST, then `Eval` | hand-written, evaluated as read, no AST |
| rules | two lists: rules and metarules | two lists | one list, the target a `Pattern.t` |
| graph | nodes with flag bits | nodes with mutable fields | an immutable value; progress in two tables |
| `-n`, `-t`, `-k` | tests inside `work`, `dorecipe`, `run` | the same | what "start a job" means |
| times | seconds, `<=` | sub-second, `<` | sub-second, `<=` |
| `:R:`, `&`, `:P:`, archives | yes | no | yes (`:R:` and archives late) |
| missing intermediates | pretend by default (Plan 9); off in principia | no | no (phase 6 decides) |
| lines | 5,980 (4,280 by the book's count) | 2,761 | about 750 (target) |

The last row is the claim this program exists to test.

## 12. What's missing, and exercises

Beyond the plan's later phases (`:R:`, archives, pretending,
content hashes), in rough order of difficulty:

- **`-d g`, the graph as dot**, with out-of-date nodes in red: the
  best way to see §5 on a real directory (`Graph`);
- **why-rebuilt output for `-e`**, one line per job naming the
  prerequisite that was newer, and by how much (`Outofdate`);
- **the pending counts** of §9, beside the re-walk, and a measurement
  on all of xix of whether they matter (`Build`);
- **output grouped per job** under `NPROC>1`, printed when the job
  ends rather than interleaved, as omk's Prelude wishes it did
  (`Recipe`);
- **a Ninja reader**: `Graph` takes rules, not text, so a `build.ninja`
  front end of about 100 lines gives a second language on the same
  engine (`Mkfile`'s sibling);
- **TinyRedo**: `foo.o.do` scripts that call `redo-ifchange` while
  they run. The dependencies are discovered during the build, so the
  graph can't be built first, and `Build`'s loop has to change shape.
  That is the most instructive exercise here, because it shows which
  of TinyMk's decisions came from mk's static graph;
- **content hashes** (`-H`): a `.mkhash` file, and early cutoff for
  every recipe instead of the careful ones (§6) (`Outofdate`, the
  plan's phase 7);
- **tup's direction**: given the changed files, walk *up* to what
  depends on them, instead of down from the target. It needs the
  reverse graph, which is one `Hashtbl` away (`Graph`).

## 13. In ix

TinyMk is a terminal program and depends on nothing graphical. It runs
on the host first, building xix's mkfiles. Its milestone is building
omk, its own full-size twin (the plan's phase 5). Later it builds
ix's own programs, with TinyShell as its `MKSHELL`. When ix runs OCaml
programs on TinyKernel (not settled yet), it is also the first test of
`fork`, `exec` and `wait` in the ix kernel: the kernel book's syscalls,
exercised by the build system book's program.

## Glossary

- **mkfile**: the file of rules and variables (§2); **prototype**
  mkfile: an included file of generic rules (`mkfiles/mkprog`).
- **Target**, **prerequisite**, **recipe**, **rule**: what to make,
  from what, and how.
- **Metarule**: a rule whose target has `%` or `&`, or is a regexp
  (`:R:`); **stem**: what the pattern matched (§4).
- **Attribute**: a letter between colons: `V` virtual, `Q` quiet, `D`
  delete on error, `E` continue on error, `N` no recipe needed, `P`
  custom out-of-date test, `R` regexp.
- **Virtual target**: a name that is not a file (`clean`, `all`).
- **Vacuous** arc: a metarule candidate whose prerequisites can't be
  made; **ambiguous** recipes: two that could both make a target;
  **NREP**: how often a metarule may repeat on one path (§5).
- **Date stamp**: a node's time for the out-of-date test (§6);
  **early cutoff**: stopping a rebuild when an output didn't change.
- **Missing intermediate**, **pretending**: §7.
- **Job**, **slot**, `$NPROC`: §9.
- **Correct**, **minimal**, **idempotent**: the laws (§10).
- **Differential test**: the same input through two implementations,
  their outputs compared.

## References

- Stuart I. Feldman, "Make -- A Program for Maintaining Computer
  Programs", Software: Practice and Experience 9(4):255-265, 1979
  (the program itself: 1976).
- Arthur B. Kahn, "Topological Sorting of Large Networks",
  Communications of the ACM 5(11):558-562, 1962.
- Andrew G. Hume, "Mk: a Successor to Make", USENIX Summer
  Conference, 1987; and Andrew G. Hume, Bob Flandrena, "Maintaining
  Files on Plan 9 with Mk" (`principia/builders/docs/mk.ms`).
- Bob Flandrena, "Plan 9 Mkfiles", Plan 9 Programmer's Manual, 1995.
- Tom Duff, "Rc -- The Plan 9 Shell", 1990 (quoting, `` `{} ``, lists).
- mk(1), plan9port (`/usr/share/man/man1/mk.1plan9.gz`): the language
  as specified, and its bugs section.
- Peter Miller, "Recursive Make Considered Harmful", AUUGN 19(1), 1998.
- Andrey Mokhov, Neil Mitchell, Simon Peyton Jones, "Build Systems à
  la Carte", ICFP 2018; extended as "Build Systems à la Carte: Theory
  and Practice", Journal of Functional Programming, 2020.
- Yoann Padioleau, *Principia Softwarica: The Plan 9 Build System mk*
  (`principia/builders/Make.nw`), and omk (`xix/builder/`).

(Dates and venues from memory unless a file is named: to check before
this note is called finished.)
