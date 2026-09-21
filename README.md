# ix

**xix, but tiny: a small but real computer, from ARM emulator to
kernel, in OCaml.**

ix is a series of *Tiny* programs that together make a whole computer
system: an emulator for a subset of ARM, an assembler, a linker, a C
compiler, a kernel, a shell and its utilities. Each program is small
enough to read in one sitting, but none of them is a toy. The
emulator runs real ARM binaries, and the kernel runs real Plan 9
programs.

Nothing is here yet: the project was started on 2026-09-21, and this
README describes the plan. See [docs/history.md](docs/history.md) for
how the project came to be and how it got its name.

## Tiny, not Toy

There is a good tradition of teaching whole computer systems:
Nand2Tetris (*The Elements of Computing Systems*), Nachos, Minix,
xv6. The Nand2Tetris route makes everything minimal: a made-up
machine, a made-up assembler, a made-up OS. ix makes the programs
tiny, not the things they deal with:

- **The machine is a subset of real ARM** (ARMv5, ARM state only, no
  Thumb, no coprocessors). The emulator stops with "undefined
  instruction" on anything outside the subset, so it also checks that
  a binary stays inside it.
- **The binaries are real.** xix's `5c`/`5l`, restricted to emit only
  the subset, produce them in Plan 9 a.out format. The same binary
  runs on the ix emulator, on qemu-arm and on a real ARM machine.
  Running it on both and comparing the results is the main test.
- **The syscalls are real.** User programs talk to the kernel through
  `SWI` with the Plan 9 syscall ABI (or a subset of it).

## The series (planned)

| ix | what it is | its full-size twin in xix |
|---|---|---|
| TinyEmulator | the ARM-subset machine: CPU, memory, devices | (none yet) |
| TinyAssembler | assembly to object files | `5a` |
| TinyLinker | object files to an a.out | `5l` |
| TinyCompiler | a C compiler | `5c` |
| TinyKernel | processes, memory, files, syscalls | the xix kernel |
| TinyShell ... | the shell and its utilities | `rc`, ... |

The list and the names are not final. Each program may also get a
two-letter command name, Unix style (see the history).

## Design

- **Everything is OCaml, the kernel included.** The kernel works like
  Nachos: it is ordinary OCaml running on the host, linked with the
  emulator. User programs run on the emulated CPU. A syscall, page
  fault or timer interrupt stops the CPU and calls a kernel handler,
  which reads and writes the emulated registers and memory, then
  resumes the CPU. Processes, address spaces, context switches and
  the syscall boundary are therefore real, while the kernel keeps
  OCaml's data types.

  ```
   user program (a.out)           runs on the emulated ARM CPU
   ----------------- SWI / trap / irq ------------------------
   TinyKernel (OCaml)             runs on the host
   TinyEmulator (OCaml): CPU, MMU, disk, timer, framebuffer, keyboard
  ```

- **The tools are terminal programs.** They read and write files, stdin
  and stdout, and depend on nothing graphical. They follow xix's
  capability style (`Cap.*`) for OS access.
- **Only the emulator's display uses a GUI library:**
  [ocaml-elm-playground](https://github.com/aryx/ocaml-elm-playground),
  through opam, draws the machine's framebuffer and feeds it the
  keyboard. The machine itself is a pure library, so it also runs in a
  terminal, and in a browser via js_of_ocaml.

## Relation to principia-softwarica and xix

- [Principia Softwarica](https://principia-softwarica.org/) is a series
  of literate-programming books explaining the Plan 9 system in C,
  program by program.
- [xix](https://aryx.github.io/xix/) ports those Plan 9 programs to
  OCaml, at full size.
- **ix** is xix made tiny: the same kind of system, the same language
  and the same taste, in far fewer lines.

There is also a difference in authorship. xix is mostly written by
Yoann Padioleau. ix is mostly written by Claude (Anthropic's AI), under
Yoann's direction: Yoann chooses the design and reviews the code, and
Claude writes most of the lines. Putting each Tiny program next to its
xix twin makes a fair comparison of the two ways of working.

## The name

IX is 9 in roman numerals (Plan 9), and ix is xix with a letter
removed: a smaller xix, as 9 is smaller than 19. It is also the "-ix"
of Unix, Minix and Linux with nothing in front. And it has two
letters, like `rc`, `mk`, `ed` and the other Unix and Plan 9 names,
and like "ai", which writes most of it. The full story is in
[docs/history.md](docs/history.md).

## License

LGPL 2.1 with the OCaml-style linking exception, like xix: see
[license.txt](license.txt) and [copyright.txt](copyright.txt).
