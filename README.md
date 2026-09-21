# ix

**ix is like [xix](https://aryx.github.io/xix/), but tiny: the whole
Principia Softwarica system, from the
machine to the web browser, as small as possible, and as real programs
in OCaml.**

ix is a series of *Tiny* programs, one for each program explained in
the [Principia Softwarica](https://principia-softwarica.org/) books:
the machine, the kernel, the core libraries, the shell, the C
toolchain, the editor, mk, version control, the debugger and profiler,
the graphics stack, the windowing system, the GUI toolkit, the network
stack, the web browser and the command-line utilities. Together they
make a whole computer system that a programmer can use. Each program
is small enough to read in one sitting, but none of them is a toy. The
emulator runs real ARM binaries, and the kernel runs real Plan 9
programs.

Nothing is here yet: the project was started on 2026-09-21, and this
README describes the plan. See [docs/history.md](docs/history.md) for
how the project came to be and how it got its name.

## Tiny, not Toy

There is a good tradition of teaching whole computer systems:
Nand2Tetris (*The Elements of Computing Systems*), Minix.
The Nand2Tetris route makes everything minimal: a made-up
machine, a made-up assembler, a made-up OS.
ix aims for the full stack, like
TECS and Minix, but makes the programs tiny, not the things they deal
with:

- **The machine is a subset of real ARM** (ARMv5, ARM state only, no
  Thumb), plus enough of the CP15 coprocessor to support virtual
  memory (the MMU) and the supervisor/user mode split, so that a real
  kernel, not just user programs, can run on top of it. The emulator
  stops with "undefined instruction" on anything outside the subset,
  so it also checks that a binary stays inside it.
- **The binaries are real.** [xix](https://aryx.github.io/xix/)'s `o5c`/`o5l`, restricted to emit only
  the subset, produce them in Plan 9 a.out format. The same binary
  runs on the ix emulator, on qemu-arm and on a real ARM machine.
  Running it on both and comparing the results is the main test.
- **The syscalls are real.** User programs talk to the kernel through
  `SWI` with the Plan 9 syscall ABI (or a subset of it).

## The series (planned)

One Tiny program (or a few) per Principia Softwarica book. The Plan 9
programs in the right column are the full-size originals: the books
explain them in C, and [xix](https://aryx.github.io/xix/) ports them
to OCaml.

| Book | ix | Plan 9 original |
|---|---|---|
| Emulator | TinyRaspberryPi | `5i` |
| Kernel | TinyKernel | `9pi` |
| Core libraries | *(not settled — ix programs are all OCaml, so there may be no separate TinyLibc, just what OCaml's stdlib and runtime give us)* | `libc`, `libthread`, `libbio`, `libregexp`, ... |
| Shell | TinyShell | `rc` |
| C compiler | TinyCompiler | `5c` |
| Assembler | TinyAssembler | `5a` |
| Linker | TinyLinker | `5l` |
| Editor | TinyEditor | `ed` |
| Build system | TinyMk | `mk` |
| Version control | TinyGit, TinyDiff | `git9`, `diff`, `patch` |
| Debuggers | TinyDebugger | `db`, `acid` |
| Profilers | TinyProfiler | `prof`, `tprof`, ... |
| Graphics stack | TinyDraw | `libdraw`, `libmemdraw`, `devdraw`, ... |
| Windowing system | TinyRio | `rio` |
| GUI toolkit | TinyPanel | `libpanel` |
| Network stack | TinyNet | `devip`, `libip`, `lib9p` |
| Web browser | TinyBrowser | `mothra`, `webfs` |
| CLI utilities | TinyCat, TinyLs, TinyGrep, ... | `cat`, `ls`, `grep`, `sed`, `awk`, ... |

The list and the names are not final. Each program may also get a
two-letter command name, Unix style (see the history).

## Design

- **Everything is OCaml, the kernel included, and it runs as a real
  binary, not just on the host.** Unlike Nachos, where the "OS" is
  ordinary code running on the host and linked with the simulator,
  TinyKernel has to become an actual ARM binary: a thin layer of C and
  assembly boots the machine and gets a stripped-down OCaml runtime
  going, and the kernel itself is OCaml from there on. The same
  binary boots on TinyRaspberryPi (the emulator) and on a real
  Raspberry Pi. We'll try hard to keep that runtime and the kernel
  inside the ARM subset TinyRaspberryPi understands, so they stay
  checkable the same way user binaries are. Processes, address
  spaces, context switches, supervisor/user mode and the syscall
  boundary are therefore real, on real (or really emulated) hardware.

  ```
   user program (a.out)                          user mode
   ----------------- SWI / trap / irq -----------------------
   TinyKernel (OCaml + thin C/asm runtime shim)   supervisor mode
   ---------------------------------------------------------------
   ARM CPU + CP15 (MMU, modes): a real Raspberry Pi, or
   TinyRaspberryPi emulating one, with disk, timer, framebuffer,
   keyboard and mouse
  ```

- **Most tools are terminal programs.** They read and write files,
  stdin and stdout, and depend on nothing graphical. They follow
  [xix](https://aryx.github.io/xix/)'s capability style (`Cap.*`) for OS access.
- **Some are graphical, Rio (the windowing system) in particular.**
  It needs a framebuffer, a mouse and a raw keyboard, so TinyKernel
  exposes those through emulated Plan 9 `/dev/cons`-style device
  files, the same interface real Plan 9 programs use, and programs
  draw through TinyDraw rather than touching a device directly.
- **Only TinyRaspberryPi depends on a GUI library:**
  [ocaml-elm-playground](https://github.com/aryx/ocaml-elm-playground)
  (its top-level library and its `gui/` library), through opam, draws
  the machine's framebuffer and feeds it the keyboard and mouse. The
  machine itself is a pure library, so it also runs in a terminal, and
  in a browser via js_of_ocaml. The graphics stack, the windowing
  system and the web browser are ix programs themselves: they run on
  the machine and draw into its framebuffer through TinyDraw, so they
  don't depend on the Playground either.

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

LGPL 2.1 with the OCaml-style linking exception, like [xix](https://aryx.github.io/xix/): see
[license.txt](license.txt) and [copyright.txt](copyright.txt).
