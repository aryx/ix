# ix

**ix is like [xix](https://aryx.github.io/xix/), but tiny: the whole
Principia Softwarica system, from the
machine to the web browser, as small as possible, and as real programs
in OCaml.**

ix is a series of small programs, one for each program explained in
the [Principia Softwarica](https://principia-softwarica.org/) books:
the machine, the kernel, the core libraries, the shell, the C
toolchain, the editor, mk, version control, the debugger and profiler,
the graphics stack, the windowing system, the GUI toolkit, the network
stack, the web browser and the command-line utilities. Together they
make a whole computer system that a programmer can use. Each program
is small enough to read in one sitting, but none of them is a toy. The
emulator runs real ARM binaries, and the kernel runs real Plan 9
programs.

Each program comes in two sizes. The **mini** one (mini-mk, mini-rc,
...) is the Plan 9 program reduced but faithful: its output is the
original's, byte for byte, and it is named after the original. The
**tiny** one (tiny-build, tiny-shell, ...) is a free variant in a
single file under [`tiny/`](tiny/), named after what it does: it
keeps the idea of the original and redesigns the rest. Together the
first make **m-ix** (a nod to Knuth's MIX) and the second **t-ix**.
`dune install` installs both kinds of executables.

The project was started on 2026-09-21, and this README describes the
plan. Written so far (`make`, then `make test`; the executables are then
in `bin/`, e.g. `./bin/mini-mk`), each with its tiny variants:

- **mini-mk**, the build system ([`builder/`](builder/)), which builds
  all of xix from its mkfiles; tiny-build.
- **mini-rc**, the shell ([`shell/`](shell/)); tiny-shell.
- **mini-ed**, the editor ([`editor/`](editor/)); tiny-editor.
- **mini-asm and mini-ld**, the assembler and the linker for arm and
  arm64 ([`assembler/`](assembler/), [`linker/`](linker/)), whose
  executables are goken's byte for byte; tiny-assembler, the two in
  one.
- **mini-cc**, the C compiler for arm and arm64
  ([`compiler/`](compiler/)), whose listings are goken's `5c -O0` and
  `7c -O0`'s instruction for instruction; tiny-c.
- **mini-chidb**, the database ([`database/`](database/)); tiny-db.
- **mini-git, mini-diff and mini-merge3**, version control
  ([`version_control/`](version_control/)); tiny-vcs.
- **mini-5i**, the ARM emulator for user programs, arm32 and arm64,
  with Linux's or Plan 9's system calls ([`machine/`](machine/));
  tiny-arm, and tiny-cpu, a CPU of our own design (see below).
- **mini-qemu**, a Raspberry Pi 1 that boots xv6 and Plan 9's 9pi as
  QEMU does ([`raspberry/`](raspberry/), run by `./mini-pi`); the Pi 4
  is next; tiny-machine, TinyCPU's CPU with a timer, traps and a
  page of kernel (`./tiny-machine` assembles, links and runs it), and
  tiny-pi, planned.

Their plans, tutorials and related-work notes are
indexed in [docs/README.md](docs/README.md).
`make build-docker` builds and tests ix in a fresh Ubuntu (the
`Dockerfile`, which GitHub Actions runs with OCaml 4.14.2 and 5.1.1).
See [docs/history.md](docs/history.md) for how the project came to be
and how it got its name.

## Tiny, not Toy

There is a good tradition of teaching whole computer systems:
Nand2Tetris (*The Elements of Computing Systems*), Minix.
The Nand2Tetris route makes everything minimal: a made-up
machine, a made-up assembler, a made-up OS.
ix aims for the full stack, like
TECS and Minix, but makes the programs tiny, not the things they deal
with:

- **The machine is real ARM**, arm32 and arm64. mini-5i runs user
  programs, with Linux's system calls or Plan 9's (5i's). mini-qemu
  is a Raspberry Pi, with the processor's modes, the coprocessor and
  the MMU, so that real kernels, not just user programs, run on top
  of it: xv6 and Plan 9's 9pi. The emulator stops with "unimplemented
  instruction" on what it does not know, so it also checks that a
  binary stays inside what ix handles.
- **The binaries are real.** ix's mini-cc, mini-asm and mini-ld make
  them, as Plan 9's `5c`/`5l` and `7c`/`7l` do (goken builds those on
  Linux): the same instructions, and the linker's executables byte for
  byte. The same binary runs on the ix emulator, on
  QEMU and on a real ARM machine. Running it on several and comparing
  the results is the main test.
- **The syscalls are real.** User programs talk to the kernel through
  `SVC` (once `SWI`) with the Plan 9 syscall ABI (or a subset of it).

One pair of tiny programs takes the other road on purpose. TinyCPU
(and TinyMachine: the same CPU with a privileged mode, traps and
devices, and a page of kernel) is a made-up machine with its assembler, as Knuth's MIX
and MMIX and Nand2Tetris's Hack are, because what it teaches is the
design of an instruction set: the choices a real one made for
history's reasons, made again with hindsight. It stands next to
TinyArm and TinyPi, the same two programs for real ARM, so that the
two roads can be compared; no other program of ix targets it.

## The series (planned)

One mini program (or a few) per Principia Softwarica book, and its
tiny variant. The Plan 9 programs in the right column are the
full-size originals: the books explain them in C, and
[xix](https://aryx.github.io/xix/) ports them to OCaml. Names in
italics are planned.

| Book | mini (m-ix) | tiny (t-ix) | Plan 9 original |
|---|---|---|---|
| Emulator | mini-5i (arm32, arm64, user mode), mini-qemu (Pi1, then 64-bit) | tiny-arm, tiny-cpu, tiny-machine, *tiny-pi* | `5i`, QEMU's raspi machines |
| Kernel | *mini-9pi* | *tiny-kernel* | `9pi` |
| Core libraries | *(not settled — ix programs are all OCaml, so there may be no separate libc, just what OCaml's stdlib and runtime give us)* | | `libc`, `libthread`, `libbio`, `libregexp`, ... |
| Shell | mini-rc | tiny-shell | `rc` |
| C compiler | mini-cc | tiny-c | `5c` |
| Assembler | mini-asm | tiny-assembler | `5a` |
| Linker | mini-ld | (in tiny-assembler) | `5l` |
| Editor | mini-ed | tiny-editor | `ed` |
| Build system | mini-mk | tiny-build | `mk` |
| Database | mini-chidb | tiny-db | `chidb` (SQLite's teaching twin) |
| Version control | mini-git, mini-diff, mini-merge3 | tiny-vcs | `git9`, `diff`, `patch` |
| Debuggers | *mini-db, mini-acid* | *tiny-debugger* | `db`, `acid` |
| Profilers | *mini-prof* | *tiny-profiler* | `prof`, `tprof`, ... |
| Graphics stack | *mini-draw* | *tiny-draw* | `libdraw`, `libmemdraw`, `devdraw`, ... |
| Windowing system | *mini-rio* | *tiny-windows* | `rio` |
| GUI toolkit | *mini-panel* | *tiny-gui* | `libpanel` |
| Network stack | *mini-ip* | *tiny-net* | `devip`, `libip`, `lib9p` |
| Web browser | *mini-mothra* | *tiny-browser* | `mothra`, `webfs` |
| CLI utilities | *mini-cat, mini-ls, mini-grep, ...* | | `cat`, `ls`, `grep`, `sed`, `awk`, ... |

The list and the names are not final. Each program may also get a
two-letter command name, Unix style (see the history).

## Design

- **Everything is OCaml, the kernel included, and it runs as a real
  binary, not just on the host.** Unlike Nachos, where the "OS" is
  ordinary code running on the host and linked with the simulator,
  mini-9pi has to become an actual ARM binary: a thin layer of C and
  assembly boots the machine and gets a stripped-down OCaml runtime
  going, and the kernel itself is OCaml from there on. The same
  binary boots on mini-qemu (the emulator) and on a real
  Raspberry Pi. We'll try hard to keep that runtime and the kernel
  inside the ARM subset mini-qemu understands, so they stay
  checkable the same way user binaries are. Processes, address
  spaces, context switches, supervisor/user mode and the syscall
  boundary are therefore real, on real (or really emulated) hardware.

  ```
   user program (a.out)                          user mode
   ----------------- SWI / trap / irq -----------------------
   mini-9pi (OCaml + thin C/asm runtime shim)     supervisor mode
   ---------------------------------------------------------------
   ARM CPU + CP15 (MMU, modes): a real Raspberry Pi, or
   mini-qemu emulating one, with disk, timer, framebuffer,
   keyboard and mouse
  ```

- **Most tools are terminal programs.** They read and write files,
  stdin and stdout, and depend on nothing graphical. They follow
  [xix](https://aryx.github.io/xix/)'s capability style (`Cap.*`) for OS access.
- **Some are graphical, Rio (the windowing system) in particular.**
  It needs a framebuffer, a mouse and a raw keyboard, so mini-9pi
  exposes those through emulated Plan 9 `/dev/cons`-style device
  files, the same interface real Plan 9 programs use, and programs
  draw through mini-draw rather than touching a device directly.
- **Only mini-qemu depends on a GUI library:**
  [ocaml-elm-playground](https://github.com/aryx/ocaml-elm-playground)
  (its top-level library and its `gui/` library), through opam, draws
  the machine's framebuffer and feeds it the keyboard and mouse. The
  machine itself is a pure library, so it also runs in a terminal, and
  in a browser via js_of_ocaml. The graphics stack, the windowing
  system and the web browser are ix programs themselves: they run on
  the machine and draw into its framebuffer through mini-draw, so they
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
Claude writes most of the lines. Putting each mini program next to its
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
