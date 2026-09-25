# Plan: tiny-os, an operating system for tiny-machine, by versions (`tiny/tiny-os/`)

Status: **v0 done; the rest for review.** Written 2026-09-25, from the
author: "let's make a plan for this tiny-os (and how it relates to the
different mini-xv6 (in OCaml), mini-9pi (in OCaml), TinyKernel (in
OCaml)). What could be the different versions where we showcase
interesting os/kernel teaching history".

Companions: [`projects.md`](../projects.md), the map of ix's projects;
[`plan_arm.md`](plan_arm.md), where TinyCPU and TinyMachine were
designed (the machine's registers of control, traps, window); and
[`plan_cc.md`](plan_cc.md), for `tiny-c -tm`.

## Context

tiny-os is the one kernel of ix that is not OCaml. It runs on
tiny-machine, the machine designed for teaching (TinyLibCPU's CPU plus
two modes, one trap, a timer, protection by a window, a console), and
it is written in that machine's assembly and in C compiled by
`tiny-c -tm`. v0 exists: a page of assembly, four programs linked with
it, round robin on the timer, the misbehaving ones killed
(`tiny/tiny-os/v0/`, checked by `TinyMachine_test.sh`).

What it is for: to show how operating systems came to be what they
are, one idea at a time, on a machine small enough that each idea is
seen without the hardware's noise. A version is a snapshot, runnable
and tested, that adds one or two of history's ideas to the one before;
reading v*n* against v*n-1* is reading that idea.

## Four kernels, four projects

ix will have several kernels. They are not versions of one another;
each answers a different question.

| kernel | language | machine | its question | its twin, or its model |
|---|---|---|---|---|
| **tiny-os** v0..v*n* (`tiny/tiny-os/`) | TinyCPU assembly, then C (`tiny-c -tm`) | tiny-machine | how did kernels come to be what they are? one idea per version | history's systems, CTSS to xv6 and Plan 9; xv6 as the destination |
| **mini-xv6** | OCaml (the README's design: a real ARM binary, a thin C/asm shim, the OCaml runtime) | the Pi (mini-qemu, real boards) | can xv6 be written in OCaml, faithfully, and still boot? | xv6's ARM ports, the ones mini-qemu boots; its `usertests` as the test |
| **mini-9pi** | OCaml, the same way | the Pi | the same for Plan 9's kernel, running Plan 9's binaries | 9pi (principia), the Kernel row of the README's series |
| **TinyKernel** (`tiny/TinyKernel.ml`) | OCaml | not decided | not decided: the author's "something else" | not decided |

The line between them: **tiny-os is guest code on a designed
machine**, readable as C and assembly are, a history lesson in
versions. **mini-xv6 and mini-9pi are OCaml kernels on real ARM**, each
a faithful twin of a real kernel, testing the README's claim that a
kernel can be OCaml and still a real binary. What tiny-os teaches
feeds them: by v*n*, tiny-os has the structure of xv6 (a process table,
fork/exec/wait, a file system with a buffer cache, pipes), so mini-xv6
is then that structure again, in OCaml, on the Pi's hardware.

TinyKernel is left open here. Two candidates, for the author to take
or leave: (a) the free variant of mini-9pi, in OCaml, on tiny-pi (the
Pi1's devices, TinyLibArm's core), as tiny-os is on tiny-machine; or
(b) a kernel in OCaml *hosted* by an OCaml emulator of tiny-machine's
privileged half (the Nachos road, which the README declines for
mini-9pi, but which one free variant could take to compare).

## Principles

1. **One idea per version, from history, named.** Each version says
   which system introduced its idea, when, and why; its header and
   this plan say it, and `notes_tiny_os.md` (to write) tells it.
2. **Every version stays runnable and tested.** `make -C v`*n* `run`;
   its laws in `TinyMachine_test.sh` (or a `tiny-os` test of its own
   when they outgrow it). A later machine feature must not break an
   earlier version: the machine grows compatibly.
3. **A version is a copy of the one before, changed.** No shared
   kernel code between versions: each directory is read alone, and
   `diff -r v`*n-1*` v`*n* is the lesson. The user side (`libc/`) is
   shared, and grows.
4. **The machine grows only when a version needs it**, as history's
   hardware did: relocation when programs are loaded, a disk when
   there are files, paging when memory is virtual. Each machine
   feature is designed in TinyMachine as its first features were
   (plan_arm.md), small, with a law.
5. **C where history went to C.** v0 is assembly, as the first
   kernels were; the kernel moves to C at the version where Unix did
   (1973), which is the version where it pays: a loader and a system
   call table. What C cannot say (the trap's entry, the registers of
   control) stays in a page of `.tm`.
6. **The same user program runs on tiny-cpu and under tiny-os**, as
   far as their system calls agree (exit, write, read): the user side
   has one ABI, tiny-cpu's.

## Principia's bootstrapping appendix, and the order of the versions

The author's `Principia.nw` ends with "Bootstrapping from Scratch"
(`~/principia/docs/principia/Principia.nw`, `\chapter{Bootstrapping
from Scratch}`): how Plan 9 could be rebuilt with no software at all,
each program named by its version and the language it is written in,
each step motivated by what was inconvenient in the step before. Its
kernels:

| the appendix's kernel | what it adds | what made it needed |
|---|---|---|
| `KERNEL0-M-CARD` | an interactive program loader: a prompt, a program's place on the tape typed, loaded at `0x1000`, run; the program jumps back to `0x100` | nothing to load programs but a human |
| `KERNEL1-ASM` | a file system: programs and data by name; the kernel copies itself high to stay out of the way | keeping a map of the tape by hand, and programs overwriting each other |
| `KERNEL2-ASMs` | multitasking: a preemptive scheduler on a timer, virtual memory so every program still loads at `0x1000`, then fork and exec; Unix's first edition, in assembly | one program at a time: quit the editor to assemble |
| `KERNEL3-C/ASM` | the kernel rewritten in C, what C cannot say kept in assembly, a `libc.h`; Unix's fourth edition | the assembly's size |

and it ends with "Summary of Plan 9 ancestor programs": `KERNEL3` as a
close ancestor of `9`, "derived by just removing many features".

tiny-os can take the same road on a real (emulated) machine, and in
that order, which is history's too: resident monitors and loaders
(GM-NAA I/O, 1956; IBSYS) before file systems, before time-sharing
(CTSS, 1961), before a kernel in C (1973). Two orders, then:

- **A, the order below as first written**: today's v0 (time-sharing, in
  assembly) stays v0; C and a loader next, then processes, sleeping,
  files, pages, Plan 9.
- **B, the appendix's order**: v0 the loader (`KERNEL0`: a prompt on
  the console, a program chosen from the image's table and loaded at
  its address, run to its end, the prompt again), v1 the file system
  (`KERNEL1`: a disk, programs by name), v2 time-sharing in assembly
  (`KERNEL2`: today's v0, renamed, grown with fork and exec), v3 the
  kernel in C (`KERNEL3`), then sleeping, pages, Plan 9 as below. Each
  version opens with what hurt in the one before, as the appendix
  does.

**B is my recommendation**: it is the appendix made runnable, it is
history's order, and each step has its reason in the previous step's
inconvenience rather than in a syllabus. Its cost is small: today's v0
moves to `v2/` (its tests follow), and two small versions come before
it; the disk (v1) comes earlier than in A, and the console's input
with it (a loader needs a prompt).

The appendix also bootstraps the *tools* on the machine itself (an
editor, assemblers, a linker, a C compiler, written in the machine's
own languages). tiny-os's tools are ix's OCaml programs on the host,
cross-development, as Unix's first kernel was assembled on a GE-635
and principia's `9` is built on Linux by goken. A later track could
make tiny-os self-hosting in the appendix's spirit: TinyCPU's
assembler, in C, running under tiny-os, assembling tiny-os.

## The versions

The versions in order A, as first written; in order B they are
renumbered as above, and the loader and the file system come first.
Each with what it adds, the machine feature it needs if any, the
history it shows, and its laws. Sizes are estimates.

### v0 — the monitor that shares time (done)

A page of assembly: the trap (registers saved into the process), two
system calls (exit, write, the buffer checked against the window),
round robin on the timer, a program that executes a privileged
instruction or leaves its window killed with its reason, halt when
none is left. Programs linked with the kernel: there is no loader.

- History: **CTSS** (Corbató, MIT, 1961-63), time-sharing by a timer
  interrupt on a 7094 extended with a protection register and an
  interval timer; the **Atlas supervisor** (Manchester, 1962), the
  "extracode" trap as the system call; the fence and **bounds
  registers** of the 1960s (the 360's storage keys, the PDP-10's
  bounds).
- Machine: as designed (plan_arm.md).
- Laws: `TinyMachine_test.sh` (every letter, both faults caught, the
  interleaving, the same output twice).

### v1 — the kernel in C, and programs loaded

The kernel rewritten in C, the trap's entry and `csrr`/`csrw`/`eret`
in a page of `.tm`; the system calls a table (a `switch`, tiny-c has
no function pointers); programs compiled separately with `tiny-c -tm`,
not linked with the kernel: the image carries them after it, and a
loader copies each into its window at boot. A process table, static
(NPROC slots).

- History: **Unix rewritten in C** (Ritchie and Thompson, 1973, the
  Fourth Edition): the kernel in a language one can read, the few
  lines of assembly kept for what C cannot say (`m40.s`, then
  `m45.s`, the heart of Lions' commentary on the Sixth Edition,
  1976-77).
- Machine: **relocation**, the window's base added to every user
  address (today's window only checks). A program is then linked at 0
  and runs in any window: what the 7094's relocation register did for
  CTSS, and the PDP-11/20's lack of it made the first Unix swap whole
  processes. A bit of `status` turns it on, so v0 runs unchanged.
- Laws: the programs of v0, now in C, print what v0's did; each also
  runs on tiny-cpu alone and prints the same (principle 6); a program
  that loops forever does not stop the others.
- Size: a kernel of about 300 lines of C and 60 of `.tm`.

### v2 — processes: fork, exec, wait, exit, and a shell

`fork` copies the window into a free one (no paging yet: the whole
process copied, as Unix V1 did); `exec` loads a program over the
caller's from the image's table of programs; `wait` and `exit` with a
status; `sbrk` within the window. The first process is `init`, which
runs a shell reading commands from the console.

- History: **Unix's process model** (Thompson, 1969-71; Ritchie and
  Thompson, "The UNIX Time-Sharing System", 1974): fork and exec as
  two calls, which is why a shell is a small program; **Project
  Genie's** fork (Berkeley, 1964-65) before it.
- Machine: **console input** (a byte to read, and an interrupt when
  one arrives: a cause of its own), so the shell can wait for a line
  without spinning.
- Laws: the shell runs a script of commands (fork, exec, wait) and
  prints what tiny-cpu running the same programs one by one prints;
  a fork bomb bounded by NPROC; the exit statuses as the script
  expects.
- Size: +300 lines of kernel, a shell of 150 lines of C.

### v3 — sleeping: sleep, wakeup, and the console by interrupts

A process that waits sleeps on a channel and is woken, instead of the
kernel spinning: the console's reader, `wait`, and later the disk.
The scheduler runs what is runnable, and idles (the machine's `wfi`,
or a halt-until-interrupt) when nothing is.

- History: **sleep and wakeup** in Unix V6 (and the famous "You are
  not expected to understand this" of its context switch, `swtch`,
  1975); **Dijkstra's THE** (1968) and its semaphores as the other
  answer, noted, not built.
- Machine: an instruction that waits for an interrupt (or the time
  jumping to `timecmp` when nothing runs), so an idle machine's time
  is not burned.
- Laws: the time spent with every process asleep is counted and is
  the idle time's; a reader blocked on the console does not slow the
  others (their output unchanged by it).

### v4 — files: a disk, inodes, directories, file descriptors, pipes

A block device, a buffer cache, inodes, directories, paths, file
descriptors (`open`, `read`, `write`, `close`, `dup`), `pipe`; the
programs now in the file system (`exec` by path), built into a disk
image by a host tool (xv6's `mkfs`, in OCaml or C).

- History: **the Unix file system** (Thompson, 1969; Ritchie and
  Thompson 1974): the inode, the directory as a file, the file
  descriptor, and **the pipe** (McIlroy, 1973), which makes the shell
  a language; "everything is a file" as the consequence.
- Machine: **a disk**, blocks read and written by the kernel through
  registers at addresses (programmed I/O first; DMA and an interrupt
  when the transfer is done, later).
- Laws: `ls | wc` in the shell; a file written, read back after a
  reboot of the machine with the same disk image; `mkfs`'s image and
  the kernel's view of it agree (a host checker).
- Size: the largest step, +800 lines, as xv6's `fs.c`, `bio.c`,
  `file.c`, `pipe.c`, `sysfile.c` are.

### v5 — virtual memory: pages

Page tables in place of windows: each process its own address space
from 0, the kernel mapped above; `fork` copies pages (then, as an
option, copy-on-write); `sbrk` grows by pages; a stray access is a
page fault with its address.

- History: **Atlas** (Kilburn, 1962), the first paging, "one-level
  store"; **Multics** (1965-69) and segments; the VAX and **4BSD**
  (1979-80) bringing paging to Unix; copy-on-write in **Mach** (1986).
  xv6's design is reached here: from this version on, tiny-os is
  shaped as xv6 is, on a smaller machine.
- Machine: **paging**, the simplest that is real: 4 KB pages, one
  level (the 1 MB memory is 256 pages; a table of 256 entries, a
  valid, a user and a writable bit), a `satp`-like register of
  control, a fault cause with the address in `tval`. The window stays,
  for v0 to v4.
- Laws: a process's pages are its own (another's address faults); the
  pages in use return to the free list when processes exit (counted);
  copy-on-write's fork copies no page until a write (counted).

### v6 — Plan 9's ideas: namespaces and file servers

Each process its own namespace (`bind`, `mount`), the kernel's
devices as file trees (`/dev/cons`, `/proc`), a user-level file server
reached through a pipe speaking a small 9P.

- History: **Plan 9** (Pike, Presotto, Thompson, Trickey, Winterbottom,
  Bell Labs, 1990-95): everything is a file *server*, and the
  namespace per process; what principia's books explain, and what
  mini-9pi will be, faithfully, in OCaml.
- Machine: nothing new.
- Laws: two processes see different files at the same path; `cat
  /proc/`*n*`/status`; a file served by a user program read by `cat`.

### A road not taken, optionally: v2m, the microkernel

From v1, the other branch: a kernel that only passes messages and
schedules, the process manager and the file system as user
processes. The same machine, the same programs, two structures.

- History: **Brinch Hansen's RC 4000 nucleus** (1969), the first;
  **Mach** (1985); **Minix** (Tanenbaum, 1987) and the
  Tanenbaum-Torvalds debate (1992); **L4** (Liedtke, 1993) on the
  cost of messages.
- Laws: v2's shell script, the same output; the messages per system
  call counted, the price of the structure.

## What the tools need

- **tiny-c**: enough for a kernel. Function pointers would make the
  system call table and the device switch xv6's (`syscalls[]`,
  `devsw[]`); a `switch` does without them for v1 and v2. Structures
  by value are not needed (xv6 passes pointers). Unions, enums: not
  needed. A way to call `.tm` from C and back is already there (the
  calling convention is one).
- **tiny-machine**: relocation (v1), console input and its interrupt
  (v2), wait-for-interrupt (v3), a disk (v4), paging (v5), each
  behind a bit or an address so that earlier versions run unchanged.
- **libc/**: grows with the system calls (fork, exec, wait, open,
  read, pipe...), one ABI with tiny-cpu for the calls they share.
- **A host tool** for v4: the disk image's builder (`mkfs`), OCaml
  (a tiny program of its own) or C for tiny-cpu.

## Order, and what to decide first

1. **v1**, with relocation in the machine: the step that makes the
   rest possible (C, a loader, separate programs).
2. **v2** and **v3**: processes and sleeping, the core of any
   Unix.
3. **v4**: files, the largest.
4. **v5**: pages, where xv6 is reached.
5. **v6**, and the optional microkernel branch.

For the author to decide:

- **The order**: A, or B (the bootstrapping appendix's, recommended);
  and the cut (fewer, larger steps; the microkernel branch in, or
  out; the self-hosting track).
- **Paging in the machine** (v5): one level as proposed, or two
  (xv6's RISC-V Sv32 shape, closer to what mini-xv6 will meet on ARM).
- **TinyKernel**: candidate (a), (b), or something else.
- **mini-xv6**: its place in the README's series (the Kernel row has
  mini-9pi; xv6 is not a Plan 9 program).

## Related work

To write, `notes_tiny_os_related_work.md`: the teaching kernels and
where each stops (Xinu, Comer, 1984; Minix, 1987; Nachos, 1992; OS/161;
Pintos, 2004; xv6, 2006; Oberon, Wirth and Gutknecht, 1987-92; "OS in
1,000 lines", 2024), Lions' commentary and the Unix history repository
(Spinellis) as the model for a history in versions, and Nand2Tetris's
OS as the made-up machine's.

## Status

- 2026-09-25: v0 done (plan_arm.md, "TinyMachine.ml done" and after);
  this plan written, for review.
