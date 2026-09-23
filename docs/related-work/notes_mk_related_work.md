# TinyMk vs. the rest of the build systems

Where a tiny mk sits among the build systems people actually use:
Make and its fifty years of descendants, Plan 9's mk, the
content-hashing systems of the big companies, the minimalist ones, and
the theory that finally put them all in one table. It covers what they
do that TinyMk won't, and which of their ideas fit in a few hundred
readable lines. Companions:
[`notes_mk.md`](../tutorials/notes_mk.md) (how it works) and
[`plan_mk.md`](../plans/plan_mk.md) (what gets built, in what order).
The author's own genealogy of the field, with dates, is
`principia/builders/lineage.txt`, and this note follows its families.

## The one-line version

| | What it optimizes for | What you write |
|---|---|---|
| Make (1976), GNU make, BSD make | Rebuilding a C program after an edit, on any Unix | Rules with tab-indented recipes, suffix or `%` rules, and a great deal of built-in knowledge |
| mk (1987), Plan 9 | The same, with fewer surprises | Rules, `%`/`&`/regexp metarules, attributes, whole recipes to one shell, `$NPROC` |
| Generators: imake, Autotools, CMake, Meson | Portability across compilers and systems | A description that *generates* Makefiles or Ninja files |
| Ninja (2012) | Speed on huge generated builds | Nothing by hand: a flat, explicit graph written by a generator |
| redo (2003/2010) | Minimalism, and exact dynamic dependencies | One shell script per target, declaring its inputs as it runs |
| tup (2009) | Correctness and speed on huge trees | Rules, and a file system monitor that checks what recipes really read |
| Shake (2012), Rake, SCons | Rules with a real programming language's abstraction | Build rules as code (Haskell, Ruby, Python), with dependencies discovered while building |
| Blaze/Bazel (2006/2015), Buck, Pants, Please | Monorepos, remote caches, reproducibility | Declarative targets in Starlark, hermetic actions, content hashes |
| Nix (2004) | Reproducible *deployment*, not just builds | Pure functions from inputs to store paths |
| Language tools: Cargo, go, dune | Zero configuration for one language | Almost nothing: the tool knows the language |
| `builder/` (TinyMk) | Seeing *why* a build system decides what it decides, on real mkfiles | A plain mkfile, run by 1,782 lines of OCaml with the algorithm in view |

## Part 1: where it came from

- **Make** (Stuart Feldman, Bell Labs, 1976; the paper in *Software:
  Practice and Experience*, 1979). The first dependency-driven
  rebuilder: targets, prerequisites, modification times, and
  **suffix rules** (`.c.o:`) for "any file with this extension".
  Feldman later said the notorious tab at the start of recipe lines
  stayed because he didn't want to break the dozen people already
  using it (from memory, to check). It shipped in PWB/UNIX and then
  everywhere, and has been the standard ever since.
- **The BSD branch**: **pmake** (Adam de Boor, for Berkeley's Sprite,
  1988), parallel and distributed from the start, became BSD make.
  FreeBSD's and NetBSD's `bmake` descend from it. **GNU make** (Richard
  Stallman and Roland McGrath, 1988) added `%` pattern rules, functions,
  `-j`, and eventually a Turing-complete macro language. (Dates from
  the lineage file; attributions from memory.)
- **mk** (Andrew Hume, Bell Labs, "Mk: a Successor to Make", USENIX
  1987) went the other way. **No built-in rules at all**: Plan 9's
  mkfiles include prototype files (`mkone`, `mkmany`, `mklib`: Bob
  Flandrena's "Plan 9 Mkfiles", 1995), which is why 425 of the 472
  mkfiles reachable from `~/xix` (principia's included) start with a
  `<`. Rules got **attributes** (`:V:` years
  before GNU make's `.PHONY` became idiomatic; `:Q:`, `:D:`, `:P:`),
  **regular-expression rules** (`:R:`), `&` beside `%`, parallelism
  through one variable (`$NPROC`), and the whole recipe given to one
  shell, so `cd` in a recipe works. It is make with its accidents
  removed, which is Plan 9's attitude in general.
- **mk after Plan 9**: Inferno's mk; **plan9port's** mk (Russ Cox,
  2000s), the one installed here and used as the reference; a mk in
  Go (Daniel Jones, 2013); and xix's **omk** (Yoann Padioleau, 2017),
  the OCaml twin of this program.
- **The complaint that shaped the next thirty years**: Peter Miller,
  **"Recursive Make Considered Harmful"** (AUUGN, 1998). One `make`
  per directory, each seeing only its part of the graph, gets
  dependencies across directories wrong and parallelizes badly.
  Miller's answer is a single graph for the whole tree. Plan 9's
  mkfiles, principia's and xix's are recursive too, so the article
  applies to TinyMk's milestone. That is worth knowing before
  measuring it.

## Part 2: the systems today

- **Generators**. Much of the world no longer writes Makefiles:
  **Autotools** (Autoconf 1991, Automake 1996), **CMake** (2000) and
  **Meson** (2013) generate them, or generate **Ninja** files. Ninja
  (Evan Martin, 2012, for Chrome) is the deliberate opposite of a
  language: no metarules, barely any variables, just edges and
  commands, because a generator writes it and speed is all that is
  left to want. It showed that the language and the engine can be
  separated, and TinyMk's `Graph`, which takes rules and not text,
  follows it.
- **Content hashes and hermeticity**: Google's **Blaze** (around
  2006; open-sourced as **Bazel**, 2015), Facebook's **Buck** (2013),
  Twitter's **Pants**. Every action declares all its inputs and runs
  sandboxed, and outputs are keyed by the hash of the inputs, so a
  result computed anywhere can be fetched from a **remote cache**
  instead of rebuilt. The price is declaring everything, a server
  process, and a build description that is its own discipline. None of
  it fits in a tiny program, and TinyMk's content-hash option (the
  plan's phase 7) keeps only the part that does: early cutoff when an
  output doesn't change.
- **Nix** (Eelco Dolstra, 2004; the thesis 2006) applies the same
  idea to whole packages. A build is a pure function from its inputs
  to a path in a store named by their hash. It is closer to a package
  manager than to mk, and it is the far end of the scale.
- **Language-integrated tools**, with Cargo (2014) as the model:
  `go build`, Cargo, dune, Swift PM. They know the language, so the
  user writes almost nothing. That is the most successful answer of
  the last decade, and the least instructive about build systems in
  general.

## Part 3: the minimalists, and the theory

The part of the field this note cares about most, because it is where
the *ideas* are small:

- **redo** (Daniel J. Bernstein's design notes, around 2003; Avery
  Pennarun's implementation, 2010). Each target `foo.o` has a script
  `foo.o.do` (or a fallback, `default.o.do`) that calls
  `redo-ifchange foo.c foo.h` as it runs. Dependencies are declared
  *during* the build, by the recipe that actually used them, so they
  can't be wrong, and there is no language to parse. apenwarr also
  wrote a "minimal do" in about 100 lines of shell. It is the tiniest
  real build system there is, and the tutorial's TinyRedo exercise
  (§12) is about exactly what TinyMk would have to change to become
  it.
- **tup** (Mike Shal, "Build System Rules and Algorithms", 2009) turns
  the walk upside down. Instead of starting at the target and asking
  "is this out of date?" all the way down, it starts from the list of
  changed files and walks *up*, which is proportional to the change
  rather than to the tree. It also checks, through a FUSE file system,
  that recipes read only what they declared. mk's `-w file` asks the
  same upward question by hand.
- **Shake** (Neil Mitchell, "Shake Before Building: Replacing Make
  with Haskell", ICFP 2012). Rules are Haskell code, and a rule may
  `need` more files after looking at others (a generated file's
  `#include`s), so dependencies are **monadic** where Make's are
  **applicative** (static). It is used for GHC's own build (Hadrian).
- **Build Systems à la Carte** (Andrey Mokhov, Neil Mitchell and
  Simon Peyton Jones, ICFP 2018; the extended version in JFP, 2020).
  The paper that made all of the above one table. A build system is a
  **scheduler** (topological, restarting, or suspending) combined with
  a **rebuilder** (dirty bit, modification times, verifying traces, or
  constructive traces), over static or dynamic dependencies. Make,
  Excel, Shake, Bazel, CloudBuild and Nix are each a few lines of
  Haskell in it. In their terms, **mk is a topological scheduler with
  a modification-time rebuilder and static dependencies**. TinyMk's
  modules follow that split (`Graph`, `Build`, `Outofdate`), and its
  tests are the paper's definitions of correctness and minimality.
  mk's re-stat after a recipe (the tutorial, §6) is a small twist the
  paper's model of Make leaves out: it gives mk early cutoff when a
  recipe is careful.

## Part 4: the teaching lineage

- **Kernighan and Pike, *The UNIX Programming Environment*** (1984),
  chapter 8, builds `hoc` with make, one version at a time. That is
  make taught as a working programmer's tool rather than as an
  algorithm.
- **"Contingent: A Fully Dynamic Build System"** (Brandon Rhodes and
  Daniel Rocco, in *500 Lines or Less*, 2016): a build system for a
  documentation project, in Python, in under 500 lines, with dynamic
  dependencies discovered by re-running tasks. It is the closest
  existing thing to this program in spirit: small, real, and written
  to be read. (To check: its exact size and chapter.)
- **Build Systems à la Carte**'s Haskell models, as above: the
  smallest correct models of each design, but models (no parser,
  no processes), not programs.
- **Principia Softwarica's `builders/Make.nw`**: the C mk in full,
  explained chunk by chunk, with its data structures drawn for
  `hello.mk`. It is the book this program is the tiny companion of.
- **Nand2Tetris** has no build system at all: its toolchain is small
  enough to run by hand. That is one of the ways ix, which aims at the
  full Principia system, differs from it.

## Part 5: in OCaml, and in Plan 9

- **OCaml's own build tools** are a history of the field in
  miniature. `make` with `.depend` files from `ocamldep` (xix's
  mkfiles still do this with mk); **OMake** (Jason Hickey and Aleksey
  Nogin, Caltech, mid-2000s), a make with content digests and a
  language of its own; **ocamlbuild** (Nicolas Pouillard and Berke
  Durak, 2007), with rules in OCaml and dynamic dependencies before
  Shake; Jane Street's **Jenga** (around 2013), then **jbuilder**
  (2016), renamed **dune** (2018), today's standard. Dune is
  memoized, content-hashed and language-aware, and it is the obvious
  way to build ix's OCaml until TinyMk can. (Dates from memory, to
  check.)
- **xix's omk** is the full-size OCaml mk, and TinyMk's twin. Its
  Prelude lists what it dropped from mk (regexp rules, archives,
  `:P:`, `&`, missing intermediates, Unicode...) and what it added: a
  strict mode that rejects undefined variables, and the `:I:`
  attribute for interactive recipes. TinyMk keeps most of what omk
  dropped (the plan's feature table), and not its additions, because
  they change what a mkfile means.
- **Plan 9 itself** is built by mk, from `/sys/src/mkfile` down,
  recursively (Part 1's warning applies). The prototype files are
  where its conventions live: `$objtype` (used by 624 of the 861 mkfiles
  in xix and principia together) selects the architecture, and `%.$O`
  rules compile with `$O`c. TinyMk has to read those files unchanged
  to reach its milestone.

## Where `builder/` actually sits

As in the Playground, there are two levels:

- **The engine, at the legible end**: `Graph` (static dependencies,
  computed once, immutable), `Outofdate` (a modification-time
  rebuilder with mk's `<=` and re-stat), and `Build` (a topological
  scheduler with `$NPROC` slots). That is one à la carte cell,
  implemented plainly, with the laws that define it as tests.
- **The interface, at the real end**: mk's language, read unchanged,
  checked by building all of xix, omk included, and by comparing `-n`
  with 9base's mk in every directory of xix and principia that has a
  mkfile.

**The ceiling, stated now**: modification times (content hashes only
as an option, `-H`, with one `.mkhash` per directory), static dependencies (`.depend` must come from a tool,
as with mk), no sandbox and no check that a recipe reads only what it
declares, no remote cache, no distributed builds, recursive mkfiles
with the problems Miller described, and none of dune's knowledge of
OCaml. The goal is that a reader can predict exactly which recipes
`mk` will run, and why, and can check that against the program.

## Postscript: the numbers (measured 2026-09-23)

- **Size**: TinyMk is 1,782 lines of `.ml` (1,398 without blanks and
  comments): `Mkfile` 371, `Build` 295, `CLI` 252, `Recipe` 213,
  `Word` 199, `Graph` 194, `Outofdate` 87, `Archive` 81, `Pattern` 77,
  `Main` 13. omk is 2,879 lines of `.ml`, `.mll` and `.mly`; the C mk
  5,980 (4,280 by the Principia book's count). The plan's target was
  750, and it was wrong by a factor of 2.4.
- **Agreement with 9base's mk**, `-n`, stdout and exit status compared
  exactly: 68 of xix's 73 directories, 277 of principia's 306. The
  others are all explained: 9base rejects omk's `:I:` attribute (26
  directories), or sees equal whole seconds where TinyMk sees
  sub-second times (8). On the corpus of 34 mkfiles, 31 identical, and
  3 differences on purpose. omk: 21 of xix's 73 directories.
- **Speed**: `-n` over xix's 73 directories in 1.94 s (9base's mk
  1.56 s, omk 11.35 s). Building all of xix from scratch: 346 recipes,
  32 s, nearly all of it `ocamlc`.
- **The milestone**: TinyMk builds all of xix, and the omk it builds
  rebuilds xix to the same 476 files.
- **Content hashes** (`-H`), after touching every source: 0 recipes
  in 1.1 s, against 363 in 32 s with times. After a comment added to
  `Common.ml`: 4 recipes against 9.

Sources: from memory unless a file is named, and to be checked before
relying on them for teaching. That applies particularly to the pmake,
Blaze, OMake and Jenga dates, Feldman's remark about the tab, and the
"minimal do" line count.
