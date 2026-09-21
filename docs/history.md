# How ix came to be

ix started on 2026-09-21 as a conversation between Yoann Padioleau and
Claude (Opus 5, in Claude Code), in a session working on
[ocaml-elm-playground](https://github.com/aryx/ocaml-elm-playground).
This file records that conversation: what was decided, who proposed
what, and how the project got its name.

## The idea: a Tiny series for a whole computer

ocaml-elm-playground had grown a long series of *Tiny* programs:
TinyMario, TinyDoom and TinyOutRun among the games, and TinyVisiCalc
and TinyExcel among the apps. Each is one short, readable OCaml file
that explains the trick of its original.

Yoann proposed doing the same for a whole computer system, "a bit like
my principia and xix projects, but in this Tiny form factor, with a
Tiny emulator, tiny kernel, tiny linker, tiny compiler, etc."

- [Principia Softwarica](https://principia-softwarica.org/) explains
  the Plan 9 system in C, as literate-programming books.
- [xix](https://aryx.github.io/xix/) ports the Plan 9 programs to
  OCaml, at full size.

The first question was where the new series should live.

## Same repo or separate repo?

Claude first recommended keeping it in ocaml-elm-playground, under the
`os/` directory (Yoann had already created it, empty). The arguments
were:

- the Playground already provides a screen, a keyboard and a clock,
  which is what an emulator's display needs, with native and web
  builds for free;
- the golden frame tests could double as boot tests;
- dependency changes between the Playground and the emulator would be
  single commits instead of cross-repo releases.

To keep a later split cheap, the dependency would be one-way and
everything would stay under `os/`.

Yoann's counter-arguments moved the decision:

1. **A separate repo can still use the Playground, through opam.**
2. **The assembler, linker and other tools should not depend on
   graphics or audio at all.** They must be terminal programs working
   on files, stdin and stdout.
3. **Only the emulator depends on the Playground**, for displaying
   the machine.

dune could enforce point 2 inside one repo. What it could not fix is
installation: building the repo needs SDL, cairo, curl and
js_of_ocaml even for someone who only wants the assembler. The tools
also belong with xix's conventions (capabilities, `Cap.stdout`), which
ocaml-elm-playground doesn't use. So the decision became a separate
repository, with the emulator's display as its only Playground
dependency. The Playground side needs one addition for that: a public
way to draw a pixel buffer, since its `image` only takes a URL.

## Tiny, not Toy

Yoann set the key constraint: *The Elements of Computing Systems*
(Nand2Tetris) does something similar, but "goes to minimal with a
really toy arch, really toy assembler, toy OS. Here I want Tiny but not
Toy."

Yoann's proposal was a **subset of ARM**. The emulator implements only
the subset but runs real ARM binaries, produced by xix's linker once it
is changed to emit only that subset. Yoann noted that ARM's condition
codes and shifted operands are nice but complicate things.

Claude's additions:

- A concrete subset: data processing with rotated immediates and
  immediate shifts, word and byte loads and stores, `B`/`BL` with
  conditions only on `B`, `MUL`, `SWI`. No `LDM/STM`, halfwords,
  register-shifted registers, coprocessors, Thumb or floating point.
  The shifter can't go completely, because 5c compiles C's `<<` and
  `>>` into shifted operands.
- The emulator should stop with "undefined instruction" outside the
  subset, so it doubles as a checker.
- Restricting 5l is not enough: 5c's code generator and the
  hand-written assembly in libc (`memmove`, `_div`/`_mod`) also emit
  instructions outside the subset. A histogram of the instruction
  forms 5c actually emits would decide the subset from data instead of
  guesses.
- Test by running the same binary on the ix emulator and on qemu-arm or
  real hardware, then comparing the results.

## A kernel in OCaml

Yoann decided that all the Tiny programs, the kernel included, would be
written in OCaml, "as the goal is teaching and OCaml is a great
implementation language". xix already has a C compiler written in
OCaml. For the kernel, Yoann added, "that will be a bit challenging but
we can make it work."

Claude pointed out the consequence: an OCaml kernel can't run on the
emulated ARM CPU unless the Tiny compiler compiles OCaml. The natural
model is **Nachos**, Berkeley's teaching OS. The kernel is ordinary
OCaml on the host, linked with the emulator. User programs are real
ARM code running on the emulated CPU, and traps call back into the
kernel. Only user mode then has to be real ARM, with the Plan 9 syscall
ABI as the boundary, so the emulator never needs ARM's MMU formats,
exception vectors or processor modes.

## The name

### Taken: TinyOS

The obvious name was taken. TinyOS is Berkeley's well-known operating
system for sensor networks (nesC, since about 2000), and it would
dominate any search.

### tiny-xix

Yoann proposed **tiny-xix**, since "tiny-os is already taken". Claude
agreed it was a good name, because it states the twin relationship:
TinyAssembler and `5a`, TinyLinker and `5l`, TinyCompiler and `5c`,
TinyKernel and the xix kernel.

### The alternatives

Yoann asked for other possible names. Claude's list:

- tied to xix: `tiny-xix`, `minixix` (Minix plus xix), `xixlet`;
- tied to principia: `tiny-principia`, `principia-minima`;
- tied to Plan 9: `ix`, `plan0`;
- descriptive: `ocaml-tiny-computer`, `tiny-computer`.

### ix, proposed as a name to avoid

`ix` was in that list, but as a name **not** to use. Claude wrote:

> **`ix`**: nine in roman numerals, and it's inside "xix". Avoid it,
> though: I believe Nemo (Francisco Ballesteros) already used "ix" for
> a Plan 9 research system, and it's too short to search for.

Claude's final ranking left it out, recommending `tiny-xix`,
`principia-minima` or `ocaml-tiny-computer` instead.

Yoann picked it anyway: "I like a lot ix and that it's both a Plan 9
reference and a xix reference."

Claude then checked the objection and found it was wrong. Nemo never
made an OS called ix. What he had was the **IX file protocol**,
designed with the unpublished Creepy file system. His Plan 9
operating-system work is NIX, Plan B, Octopus and Clive. The opam name
`ix` was also free. The remaining downside is searchability, which a
clear tagline and the distinctive `TinyXxx` program names reduce.

So Claude found the name, and Yoann saw that it was good.

### What ix means

The meanings came up one by one:

- **IX is 9 in roman numerals**: Plan 9 (Claude).
- **ix is inside xix**: a xix reference (Claude, and the reason Yoann
  liked it).
- **ix is xix, but shorter**, just as the project is xix but tiny
  (Yoann).
- **In roman numerals, xix is 19 and ix is 9**: the smaller system is
  the smaller number (Claude).
- **"-ix" is the suffix of Unix, Minix, Xenix and Linux**, and ix is
  that suffix with nothing in front. Minix was "mini Unix", and ix goes
  one step further (Claude).
- **Two letters**, like `ls`, `rc`, `mk`, `ed` and the other names Unix
  and Plan 9 people loved, and like **ai**, which writes most of ix
  (Yoann).

The two-letter theme may carry into the commands. The source files
would keep their `TinyXxx` names, while the commands get two-letter
names that don't shadow the host's `as`, `ld` or `cc`, or xix's `5a`,
`5l`, `5c`. For example `ia`, `il`, `ic` and `ie` for the ix assembler,
linker, compiler and emulator. This isn't decided yet.

## Who writes ix

The last point is about authorship. As Yoann put it: "you found the
name, and the code in ix will be all yours mostly (with my direction),
while xix is mostly my code."

So the two projects are twins in a second way:

- **xix**: Plan 9 in OCaml, full-size, mostly written by Yoann;
- **ix**: its tiny twin, mostly written by Claude under Yoann's
  direction. Yoann chooses the design and reviews the code; Claude
  writes most of the lines.

Each Tiny program next to its xix twin is therefore also a comparison:
the same system, the same language and the same taste, once written by
hand at full size and once written tiny by an AI under direction.
