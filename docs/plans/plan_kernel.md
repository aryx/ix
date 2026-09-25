# Plan: mini-xv6, an xv6 in OCaml on the Pi1 (`kernel/`)

The author (2026-09-25), after tiny-os v6 (tiny/tiny-os/v6/, an xv6 in
2,600 lines of C on TinyMachine): "do you think a mini-xv6, in OCaml,
following again xv6 would be clearer and shorter? [...] can we design
DSL in OCaml for low level memory adjustments and precise page table
byte setting? Also we will need to adapt the runtime and probably rely
on ~/ocaml-light/ [...] I already tried in the past to write an xv6
like kernel in OCaml in ~/xix/kernel/". Then: "let's try first your
derisk approach; but let's use ocaml-light [...] set it up like I did
in xix", on the Pi1 ("Pi1 is simpler than Pi4 arguably").

## The analysis, in short

- **Where OCaml wins**: three quarters of xv6 is data structures and
  error handling (processes, sleep and wakeup, the buffer cache, the
  log, inodes, directories, paths, file descriptors, pipes, exec, the
  system calls): variants with their data (`Sleeping of chan`,
  `Zombie of status`; a file `Pipe | Inode | Device`), exceptions for
  xv6's "return -1 and undo" plumbing, pattern matching for its type
  tags and null pointers. Half to two thirds of the C, and clearer.
- **The low quarter** (page tables, trap frames, on-disk structures,
  device registers): an embedded DSL, not a language: typed views over
  raw memory (a few externals for 8/16/32-bit loads and stores), a
  `Pte` module turning an entry into a record and back, declarative
  layouts (field, offset, width). The assembly stays: the vectors, the
  trap frame, the context switch.
- **The cost**: the kernel stands on ocaml-light's runtime (13k lines
  of C: a copying minor heap, an incremental major heap), booted
  bare-metal by a few hundred lines of C stubs, and the GC must know
  every kernel stack (xv6 sleeps in the middle of a system call, on
  the process's own kernel stack).
- **What ~/xix/kernel teaches** (2017, surveyed): bytecode, started last
  by a C Plan 9 kernel doing the low-level work; printing and green
  threads switched by the timer worked; the OCaml kernel (3,300 lines:
  memory, processes, scheduler, time) never ran a process; files,
  devices and system call entry were empty. It stalled on plumbing
  before a user program ran: the steps below put a user program first.

## Decisions

1. **The Pi1** (ARMv6, one core): its devices and MMU are the
   simplest, it is mini-qemu's most mature board (9pi, xv6 arm-pi1),
   the author owns one, and TinyMachinePi runs on it too.
2. **Native code** (ocaml-light's arm backend, `configure -target-arch
   arm`), not bytecode: bytecode interpreted under mini-qemu's 30 MIPS
   would be tens of times slower again.
3. **Every address below 1GB**: the Pi1's RAM (0-512MB) and devices
   (0x20000000) fit OCaml's 31-bit ints, the kernel identity-mapped at
   the bottom, user space above it; so addresses and page table
   entries are plain ints; `Int32` for the rare full 32-bit words.
4. **A kernel that is not preemptible**: interrupts on only in the
   scheduler's idle loop (as tiny-os v6): an interrupt never lands in
   the GC.
5. **ocaml-light's runtime as xix set it up**: its C, freestanding,
   with stubs for the C library (the console's write, a malloc over a
   fixed region, the rest a panic), linked with the OCaml program.

## The steps (de-risking first)

1. **OCaml running bare-metal**: a kernel.img loaded at 0x8000 whose
   OCaml `main` prints to the PL011, under mini-qemu and QEMU's
   raspi1ap (and TinyMachinePi's loader convention, so the board too).
2. **A trap and a user program**: the vectors, user mode, one system
   call (write), back.
3. **Processes on their own kernel stacks**, the GC's roots right
   across a switch.
4. **xv6's structure**: fork, exec, wait; files on xv6's fs.img
   format; then xv6 arm-pi1's own user programs, and usertests, run on
   mini-xv6, their output compared with xv6's C kernel's under
   mini-qemu: a mini twin.

Each step is kept in its own directory, `kernel/step1/`, `step2/`...,
as tiny-os keeps v0 to v6 (the author: "maybe we can save the code for
this derisk somewhere under kernel/ [...] I think it's good teaching").

## Status

2026-09-25: plan written.

**Step 1 done under QEMU** (2026-09-25): `kernel/step1/` (Main.ml,
start.s, libc.c, kernel.ld, a Makefile; `kernel/ocaml-light.sh` builds
the cross compiler). A 106KB kernel.img at 0x8000 prints, allocates in
the minor and major heaps (a list of 100,000), runs a full major
collection, catches an exception and uses Printf, under QEMU's
raspi1ap. What it took:

- ocaml-light's `configure -target-arch arm` (its arm backend, the
  stdlib compiled for it), in a clone: ~/ocaml-light untouched.
- **ocaml-light's `-output-obj` calls the host's `ld -r`** even for a
  cross target (utils/config.ml's native_partial_linker): worked
  around with an `ld` pointing at arm-linux-gnueabihf-ld first in PATH.
  To fix in ocaml-light's configure (for the author).
- The runtime's C (asmrun/ and byterun/, less main.c) compiled
  freestanding for ARMv6KZ with the VFP, hard-float (the arm backend's
  convention); PIE, _FORTIFY_SOURCE and 64-bit offsets turned off.
- **libc.c**, as xix's fakes.c: stdout and stderr to the PL011, a bump
  malloc after the kernel, sprintf for the integers (string_of_int and
  Printf need it), the rest a panic naming itself (files, signals, the
  maths, strtod).
- **Not libgcc**: Ubuntu's armhf libgcc is Thumb-2 for ARMv7, which an
  ARMv6 cannot run; the runtime's first division (`blx __udivsi3` in
  major_collection_slice) jumped into Thumb, took an undefined
  instruction, and the zeros below 0x8000 slid execution back to
  _start: the runtime started again and again until the heap ran out
  ("not enough memory for the initial heap"). libc.c has its own
  divisions (the ABI's __aeabi_* and the older __divsi3, __modsi3 that
  ocaml-light's backend calls).
- ocaml-light's `List.init` is not tail recursive: 100,000 frames
  overflowed the 64KB stack, silently (no guard page) down through the
  bss and below 0 before a data abort.

**Under mini-qemu, not yet**: the GC computes its slices with doubles
(major_collection_slice, alloc_shr), and mini-qemu's arm32 has only the
VFP's loads and stores. Next: VFPv2's data processing in machine/'s
Arm32 (vmov, vcvt, vadd..vdiv, vcmp, vpush/vpop, vmrs to the flags;
about 20 operations), checked against the CPU by random blocks.
