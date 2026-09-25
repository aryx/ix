# Plan: tiny-os, an operating system for tiny-machine: v0, then v6, xv6 on it (`tiny/tiny-os/`)

Status: **v0 done; v6 for review.** Written 2026-09-25, rewritten the
same day. The author, on the first version (seven small versions, one
historical idea each): "I wonder if this v0 v1 ... is annoying and it
might be better to go from v0 to "v6" that is a xv6 clone for tm";
then, for this one: "it's good that we stress-test the other tiny-xxx
and adding extensions there because v6 need them (like paging,
function pointers, enum). Hopefully it will not add too much code and
hopefully those additions can be encapsulated to not pollute too much
the original (simpler) code. Also let's use fake spinlocks and make
the code multicore ready, even if it complicates things, even if
single CPU in tiny machine, because we could change that, and multi
core has good teaching value ... We probably want a swp instruction
also in the tinymachine then or something related".

Companions: [`projects.md`](../projects.md), the map of ix's projects;
[`plan_arm.md`](plan_arm.md), where TinyCPU and TinyMachine were
designed; [`plan_cc.md`](plan_cc.md), for `tiny-c -tm`.

## Context

tiny-os is the one kernel of ix that is not OCaml. It runs on
tiny-machine (TinyLibCPU's CPU plus two modes, one trap, a timer,
protection by a window, a console) and is written in its assembly and
in C compiled by `tiny-c -tm`.

- **v0** exists (`tiny/tiny-os/v0/`): a page of assembly, four
  programs linked with it, round robin on the timer, the misbehaving
  ones killed; checked by `TinyMachine_test.sh`.
- **v6** is the next and last: **xv6 on tiny-machine**, in C, with the
  structure and the names of MIT's xv6. Its riscv32 fork
  (`~/xv6/forks/riscv32`, 6,388 lines of kernel) is the model: 32
  bits, Sv32 pages. v6 passes xv6's `usertests`. The name is the pun
  xv6 is itself: Unix's Sixth Edition, re-done.

Nothing in between. The history the intermediate versions were to
show goes where it is read anyway: v6 is built in steps, each a commit
(the trap and the scheduler, processes, files, pages), and the
tutorial (`notes_tiny_os.md`, to write) tells each step's history
(CTSS, Unix V1 to V6, Atlas, Multics, 4BSD). Principia's
bootstrapping appendix, considered for the order of the versions, is
a project of its own (tiny-bootstrap, not planned; `projects.md`).

## Four kernels, four projects

| kernel | language | machine | its question | its model |
|---|---|---|---|---|
| **tiny-os** v0, v6 (`tiny/tiny-os/`) | TinyCPU assembly, then C (`tiny-c -tm`) | tiny-machine | xv6's design, on a machine designed to show it, the hardware's noise gone | xv6 (riscv32) |
| **mini-xv6** | OCaml (the README's design: a real ARM binary, a thin C/asm shim, the OCaml runtime) | the Pi (mini-qemu, real boards) | can xv6 be written in OCaml, faithfully, and still boot on real hardware? | xv6's ARM ports; `usertests` |
| **mini-9pi** | OCaml, the same way | the Pi | the same for Plan 9's kernel, running Plan 9's binaries | 9pi (principia) |
| **TinyKernel** (`tiny/TinyKernel.ml`) | OCaml | not decided | the author's "something else" | not decided |

tiny-os v6 and mini-xv6 are the same kernel twice, and each helps the
other: v6 is xv6's structure in C on a simple machine, readable next
to the original file by file; mini-xv6 is that structure in OCaml on
the Pi's real hardware. With v6 first, mini-xv6 has a reference that
runs, each of whose subsystems has been read and adapted once.

## Principles

1. **xv6's structure and names.** One file for one of xv6's (`proc.c`,
   `trap.c`, `vm.c`, `kalloc.c`, `spinlock.c`, `sleeplock.c`, `bio.c`,
   `log.c`, `fs.c`, `file.c`, `pipe.c`, `exec.c`, `syscall.c`,
   `sysproc.c`, `sysfile.c`, `console.c`, `printf.c`, `string.c`,
   `main.c`), the same functions, in the same order where it can be; a
   difference is the machine's (the disk, the interrupts) or the
   compiler's (below), and is said where it is. A `diff` against the
   riscv32 fork should be read, not wide.
2. **Multicore-ready, even on one core.** Real spinlocks (an atomic
   swap, `acquire`/`release`, `push_off`/`pop_off`), `struct cpu
   cpus[NCPU]` and `mycpu()`, the locking discipline of xv6 (the
   process table's lock, `p->lock`, `wait_lock`, their order), `NCPU` a
   parameter. With one core the locks are never contended, but they
   are taken, and the code is right for more: the machine may get
   cores (phase 5), and concurrency is half of what a kernel teaches.
3. **The tools grow because v6 needs them, and v6 stress-tests them.**
   tiny-c gets the C that xv6 uses (enum, function pointers, goto,
   function-like macros...); tiny-machine gets the hardware (pages, an
   atomic swap, a disk, interrupts). Each extension is **small and
   encapsulated**: its own section of the file, a flag or an opcode
   that leaves the older behavior untouched, its lines counted in its
   commit, and its law. The simple versions stay readable: TinyCPU's
   instruction set does not change (the new instructions are
   TinyMachine's, as csrr, csrw and eret are); tiny-c without the new
   features compiles as it does today (arm64's output byte for byte on
   `TinyC_tests/`).
4. **Every new C feature is checked on both back ends.** A feature
   added to tiny-c for v6 goes into its arm64 back end too, and a test
   program in `TinyC_tests/` uses it: compared with 7c's run, and with
   `-tm`'s. xv6 stress-tests tiny-c; 7c checks the stress.
5. **What C cannot say is in `.tm`**, a page of it: the entry, the
   trap vector and its register save, `swtch`, the registers of
   control (xv6's `static inline` `r_satp()` and friends become `.tm`
   routines, or tiny-c built-ins if that is smaller).
6. **The laws are xv6's**: its `usertests` (ported), its shell running
   a script; and the machine's (determinism: the same image, the same
   output, on every run).

## What tiny-c needs (phase 1)

Counted in the riscv32 kernel (`kernel/*.c *.h`):

| feature | uses in xv6 | how | where it lands |
|---|---|---|---|
| `enum` | the process's and a file's states (`proc.h`, `file.h`) | names of int constants; the type an int | the parser, 20 lines |
| function pointers | `devsw[].read/write`, the system call table `syscalls[]` | a pointer-to-function type; a call through an expression, a new IR `CallInd`; arm64 `BL (R)`, TinyCPU `jalr` | the parser and both back ends, 50 lines |
| `goto` and labels | 29 (`exec.c`'s `bad:`, `fs.c`, `sysfile.c`) | the IR has labels and jumps already; a name per label, in a function's scope | 20 lines |
| function-like macros | 29 (`PGROUNDUP`, `PX`, `PTE2PA`, `major`) | `#define F(a, b) ...` expanded on tokens | the preprocessor, 40 lines |
| `#if`, `#ifdef` | 10 | the preprocessor's conditions, constants only | 30 lines |
| a structure copied | 1 (`file.c`: `ff = *f`) | by words, or rewritten as a `memmove` in v6 (a line, said) | 0, or 30 |
| `static inline` | 41, all wrappers of `asm volatile` | `inline` ignored; the wrappers become `.tm` routines | 1 line |
| `asm volatile`, `__sync_*` | 45 | not in tiny-c: `.tm` routines (the registers of control, `amoswap`) | 0 |
| `uint64` | 14 | a 32-bit machine: `uint32` in v6, as the riscv32 fork mostly has already | 0 |

About 200 lines in all, each feature its own commit with its test in
`TinyC_tests/` (both back ends, against 7c). Compiling xv6 will find
what this table missed; each find is added the same way.

## What tiny-machine needs (phase 2)

Each behind something that keeps v0 running unchanged (v0's test runs
after every step):

- **More memory.** 2^20 bytes is 256 pages; xv6 wants a few MB (its
  kernel, the processes, the buffer cache). TinyMachine's memory
  becomes a parameter (16 MB), TinyLibCPU's `memsize` a field of the
  machine instead of a constant; TinyCPU keeps its 2^20 and its
  modulo.
- **Pages: Sv32**, RISC-V's 32-bit scheme, because xv6's `vm.c` is
  written for it (`walk()` with two levels of 10 bits, 4 KB pages; the
  entry's V, R, W, X, U bits; A and D not kept). A `satp` register of
  control turns it on (off: physical addresses, as v0 uses); a page
  fault is a cause, with the address in `tval`. The fetch goes through
  it too: TinyLibCPU's `step` fetches from memory directly today
  ("code is never a device's"), so it gets a **fetch hook**, the
  fifth, the one change to the library's interface, defaulting to
  memory.
- **An atomic swap**, `amoswap d, a, (b)` (d gets the old value of the
  word at b, which becomes a): RISC-V's `amoswap.w`, ARM's old `swp`.
  With one core any instruction is atomic; with several (phase 5) it
  is the one that must be, and the spinlock is built on it. A fence
  is not needed while the cores interleave instruction by instruction
  (sequential consistency); the machine's header says so, as the
  reason it is absent.
- **`hartid`**, a register of control, 0 on one core (xv6's `cpuid()`,
  `r_tp()`).
- **Interrupts from devices**: `ip` and `ie` registers of control (a
  bit per source: the timer, the console, the disk), in place of
  xv6's PLIC, whose claim and complete become reading `ip` and the
  device clearing its bit.
- **The console, input too**: a byte to read, and an interrupt when
  one arrives (xv6's `uart.c` becomes a page; `console.c` is kept).
- **A disk**: registers at addresses (the block, the memory address,
  read or write, go), the transfer done at once in the emulator, an
  interrupt after; the disk an image file (`tiny-machine -d fs.img`).
  xv6's `virtio_disk.c` (400 lines) becomes about 80.

About 250 lines in `TinyMachine.ml`, 20 in `TinyLibCPU.ml`.

## The kernel (phases 3 and 4)

Ported in xv6's own order of dependence, each step a commit that runs:

1. `entry.tm`, `start`: a stack per core, supervisor mode, the trap
   vector; `printf` on the console; `kalloc` (a free list of pages);
   `panic`.
2. `vm.c`: the kernel's page table (identity for its memory and the
   devices), then a process's; `satp` on.
3. `trap.c`, `kernelvec.tm`, `trampoline.tm`: traps from the kernel
   and from user mode, the timer's interrupt; `proc.c` and
   `swtch.tm`: the process table, `scheduler`, `sched`, `yield`,
   `sleep`/`wakeup`, `fork`, `exit`, `wait`, `kill`; the first
   process, from `initcode`.
4. `syscall.c`, `sysproc.c`: the table, the arguments from the trap
   frame.
5. `bio.c`, `log.c`, `fs.c`, `file.c`, `pipe.c`, `sysfile.c`,
   `exec.c`: the file system on the disk, `exec` of the format below.
6. The user side: `ulib` (xv6's, on `libc/`'s calling convention),
   `init`, `sh`, `cat`, `echo`, `grep`, `ls`, `mkdir`, `rm`, `ln`,
   `wc`, `kill`, `forktest`, `usertests`, compiled by `tiny-c -tm`;
   and `mkfs`, building the disk image on the host.

Two choices of form, for review:

- **The executable format.** xv6 execs ELF. tiny-cpu's images have no
  header. v6 needs a small one (the entry, the text and data sizes,
  the bss): an ELF subset, or a header of our own (a.out's words, as
  Unix V6's). a.out's is the smaller and the historical one.
- **`mkfs`** runs on the host: xv6's `mkfs.c` compiled by tiny-c for
  tiny-cpu (which then needs the host's file calls, open, read,
  write, lseek, as `sys`), or rewritten in OCaml (`mkfs.ml`, a tiny
  tool). The first stress-tests tiny-c again; the second is simpler.

Estimated: 5,000 lines of C (the riscv32 fork's 6,388, less virtio,
the PLIC and the 64-bit), 250 of `.tm`; the user side 3,000.

## Multicore (phase 5)

tiny-machine with `-smp N`: N cores sharing memory, each with its
registers and registers of control (`hartid` its number), stepped
**one instruction each in turn**, or in an order drawn from a seed
(`-seed S`). Deterministic either way, so a race comes back from its
seed, which is what makes concurrency teachable on this machine (real
hardware's races do not come back when looked at). v6 with `NCPU = N`,
unchanged but for the constant.

Laws: `usertests` on 1, 2 and 4 cores; the same output over many
seeds; a spinlock made non-atomic (a load then a store in place of
`amoswap`) fails on some seed, and the seed is printed.

## What history, and where it is told

Not in versions but in the tutorial, one section per subsystem of v6,
each with the system that introduced it:

| v6's part | its history |
|---|---|
| the trap, the timer, time-sharing | CTSS (1961-63), the Atlas supervisor (1962) |
| processes, fork, exec, wait; the shell | Project Genie (1964), Unix (1969-74) |
| sleep and wakeup; the scheduler | Unix V6's `swtch` (1975); THE's semaphores (Dijkstra, 1968), the other answer |
| the file system, inodes, pipes | Unix (Thompson, 1969; McIlroy's pipe, 1973) |
| the log | journaling: Cedar (1987), ext3, then xv6's own |
| pages | Atlas (1962), Multics (1965-69), 4BSD (1979-80) |
| locks, several cores | Dijkstra's mutual exclusion (1965), test-and-set (the IBM 360, 1964), SMP Unix (the 1980s) |
| v0 against v6 | a monitor against a kernel: what 15 years of history added |

## Order, and the decisions

1. **Phase 1, tiny-c** (enum, function pointers, goto, macros, `#if`),
   each against 7c.
2. **Phase 2, tiny-machine** (memory, Sv32 and the fetch hook,
   amoswap, hartid, interrupts, console input, the disk), each with v0
   still passing.
3. **Phases 3 and 4, the kernel and the user side**, in xv6's order,
   until `usertests` passes.
4. **Phase 5, several cores.**

For the author to decide:

- **Sv32** (xv6's `vm.c` as it is) or a smaller scheme of our own.
  Sv32 is recommended: it is the real one, 32-bit, and v6 then diffs
  cleanly against the riscv32 fork.
- **The executable format**: a.out's header (recommended) or an ELF
  subset.
- **`mkfs`**: in C on tiny-cpu, or in OCaml.
- **The log** (`log.c`, crash recovery): in (xv6 has it, and crash
  tests could follow) or out of a first v6.
- **TinyKernel**: still open.

## Related work

To write, `notes_tiny_os_related_work.md`: the teaching kernels and
where each stops (Xinu, Comer, 1984; Minix, 1987; Nachos, 1992;
OS/161; Pintos, 2004; xv6, 2006; Oberon, Wirth and Gutknecht,
1987-92; "Operating System in 1,000 Lines", 2024), Lions' commentary
as xv6's ancestor, and the riscv32 xv6 fork as v6's model.

## Status

- 2026-09-25: v0 done (plan_arm.md, "TinyMachine.ml done" and after).
- 2026-09-25: a plan of seven versions written, then replaced by this
  one (v0, then v6, xv6 on tiny-machine; the history in the tutorial;
  multicore-ready; the tools extended for it, encapsulated). For
  review.
