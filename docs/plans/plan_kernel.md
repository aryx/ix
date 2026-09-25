# Plan: mini-xv6, an xv6 in OCaml on the Pi1 (`kernel/`)

Companions: [`notes_kernel.md`](../tutorials/notes_kernel.md), the
tutorial (the runtime and what it needs bare-metal, the steps, the
stacks the collector must know, memory as typed views), and
[`notes_kernel_related_work.md`](../related-work/notes_kernel_related_work.md)
(kernels in collected languages, from the Lisp machines and Oberon to
Biscuit; OCaml without an OS, MirageOS; xv6 and its descendants).

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
The steps are the ladder, each a small snapshot showing one mechanism
(OCaml bare-metal, a trap, processes and the collector, the MMU, the
timer); mini-xv6 itself, a program that grows in modules, is
`kernel/xv6/`, and a later Plan 9 kernel's twin `kernel/9pi/` (the
author asked between `step6`/`step9`, `xv6`/`9pi` and `ov6`/`o9pi`;
`o` is xix's prefix, ix names its directories by what they hold).
Step 4 of the list above became steps 4 (the MMU) and 5 (the timer),
then `kernel/xv6/`.

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
  To fix in ocaml-light's configure (for the author:
  [`plan_bugs_ocaml_light.md`](../plan_bugs_ocaml_light.md), with the
  other limits met).
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

**Step 1 done under mini-qemu too** (2026-09-25): the same console as
QEMU's (`kernel/test.sh`, in `make test-pi`). The kernel's C, compiled
by GCC for ARMv6KZ, needed of mini-qemu's arm32 what 9pi and xv6 never
used, now in machine/'s Arm32:

- **VFPv2's data processing**: the GC computes its slices with doubles
  (major_collection_slice, alloc_shr). vmov with the core registers
  (a single, a double and two), vmov/vabs/vneg/vsqrt, the arithmetic
  and multiply-accumulates of singles and doubles, vcmp(e) and vmrs to
  the flags, the conversions (between precisions, from and to 32-bit
  integers, vcvt and vcvtr), vldr/vstr of singles, vldm/vstm/vpush/vpop.
  Singles computed in double and rounded once (exact for + - * / sqrt).
  The multiply-accumulates negate as the architecture does: vmls is
  d + -p, and a negated NaN changes sign (the one difference 500
  random blocks found).
- **rev, rev16, revsh**, and **ARMv5TE's halfword multiplies**
  (smlaXY, smulXY, smlawY, smulwY, smlalXY): GCC -O2 emits smlabb.

Checked by objdump (the forms, words_arm_system.txt; random words of
the VFP's classes) and by the CPU: `random_blocks.py -vfp`, blocks with
the VFP mixed in, d0-d15 and FPSCR's flags compared (3,000 blocks, 0
differ), and the plain blocks with rev and the multiplies. mini-5i
turns the VFP on for a Linux program, as Linux does.

**Step 2 done** (2026-09-25): `kernel/step2/`, a trap and a user program,
under mini-qemu and QEMU the same (`kernel/test.sh`).

- `start.s`: a stack per exception mode, the vectors copied to 0, the
  system call's entry (the user's registers into a 17-word trap frame:
  r0-r12, sp and lr with `stm ^`, the return address, the SPSR) and the
  way back (`user_return`: the frame restored, `movs pc, lr`), which
  also enters user mode the first time.
- `machine.c`: the primitives OCaml declares `external` (words and
  bytes of memory, the PL011, entering user mode, halting) and
  `trap()`, which calls the OCaml function registered as "trap"
  (`Callback.register`; ocaml-light's `callback`, which has no
  exception-safe variant: the OCaml handler catches everything).
- `user.s`: a program making its calls as xv6 arm-pi1's `usys.S` does
  (the arguments pushed, the number in r0, `swi 0x40`): write, exit.
- `Main.ml`: the trap frame as a typed view of memory, the arguments
  read from the user's stack as xv6's `argint`, write and exit.

The point it checks: the trap enters on the kernel's stack where the
kernel left it when it entered user mode, below the OCaml frames that
did; the handler runs there through the runtime's callback, and a full
major collection at each trap finds its roots (the callback's link
back to the runtime's saved stack state). One kernel stack is enough
while there is one program; step 3 gives each process its own.

**Step 3 done** (2026-09-25): `kernel/step3/`, processes on their own
kernel stacks, the collector seeing all of them, under mini-qemu and
QEMU the same. **No change to ocaml-light's runtime was needed**: its
`roots.c` already has what systhreads uses, `scan_roots_hook` and
`do_local_roots`.

- `machine.c`: per slot a trap frame (start.s uses the running one's,
  `cur_tf`), a 16KB kernel stack and a context. `k_swtch`, an OCaml
  external, saves the runtime's view of the stack (the five globals
  `caml_c_call` and the collector use: `caml_bottom_of_stack`,
  `caml_last_return_address`, `caml_gc_regs`, `caml_exception_pointer`,
  `local_roots`) with the registers, and puts its own back when the
  process resumes; being an external, it switches right where
  `caml_c_call` has recorded the process's last OCaml frame.
  `scan_stacks`, the runtime's `scan_roots_hook`, walks every stack
  that does not run with `do_local_roots`. A new process starts in a C
  trampoline on its empty stack (its view empty: the callback's link
  says there is nothing above) and enters OCaml by `callback`.
- `start.s`: the trap frame through `cur_tf`; `swtch` (r4-r11, d8-d15,
  sp, lr).
- `Main.ml`: a process table (a variant for the state), xv6's
  round-robin scheduler on the boot stack, `sched` from inside a system
  call; write, getpid, exit, and sleep (no timer yet: the CPU given up
  n times). `user.s`: three rounds of "process P, round R" with sleep
  between, then exit(10P).
- **The check**: around every switch the sleeping process holds young
  values only its kernel stack refers to, while the scheduler
  allocates and forces a minor and a major collection; all 9 checks
  pass. **With the hook left out**, the first resume finds its values
  gone (a sum of 3675 for 1225) and the next round takes a data abort:
  the check fails when it should.

The risk the plan put first -- a collected language's kernel with a
kernel stack per process -- is retired. Step 4 is xv6 itself.

**Step 4 done** (2026-09-25): `kernel/step4/`, the MMU, under mini-qemu
and QEMU the same. xv6 arm-pi1's layout: user programs from 0 below
1GB, the kernel at KERNBASE (0x80000000), the devices at 0xFE000000,
the vectors at 0xFFFF0000.

- `start.s`: the kernel linked at KERNBASE + 0x8000, loaded at 0x8000;
  the boot, at the physical addresses, fills the kernel's table (1MB
  sections, ARMv6's format: the RAM, the devices, the first MB as
  itself for the jump), maps the vectors' page at 0xFFFF0000 through a
  coarse table, turns the MMU on (M, XP, V) and jumps high; then TTBCR
  N = 2 (TTBR0 for below 1GB, a process's 4KB table; TTBR1 the
  kernel's). Aborts from user mode go to the kernel, which kills the
  process; from the kernel they stop the machine.
- `machine.c`: physical memory by physical address (KERNBASE added in
  C: OCaml never holds a kernel address), the trap frame by word,
  TTBR0 switched, the program's image, a user's fault handed to OCaml
  with its address (an Int32: it may be the kernel's) and status.
- `Main.ml`: page table entries as records (`L1_fault | Coarse of int`,
  `L2_fault | Page of page`, `perm`), encoded and decoded in one place;
  a page allocator (a list of physical addresses); walk, map, a
  checked copyin, a space freed; a process's space made from the
  image (its pages at 0, a guard page, a stack page); the scheduler
  switching TTBR0; a fault killing the process.
- `user.s`, linked at 0: process 1 reads the kernel's memory (killed,
  a section permission fault), process 2 gives write() an unmapped
  pointer (refused, -1) and reads it itself (killed, a translation
  fault), process 3 runs and exits; all 49,152 pages back at the end.

Found on the way:

- **1GB is not an OCaml int on the Pi1**: `0x40000000`, written as the
  user's bound, wrapped to min_int, and every user address looked out
  of range. The rule is "every address *below* 1GB": the bound itself
  is out; the check is `va >= 0`.
- **TTBCR before TTBR0**: the boot first pointed TTBR0 at the empty
  user table, then set N = 2; in between, the kernel's own addresses
  went through the empty table. QEMU let it pass (its TLB still held
  them), mini-qemu faulted (it empties its TLB on every TTBR write) --
  the stricter emulator found the kernel's bug.
- OCaml 1.07 has no inline records, field punning, `; _` in record
  patterns, labeled arguments, `_` as a `for` variable, `_` in number
  literals, `String.iter`: the kernel is written in 1.07's OCaml.

**Step 5 done** (2026-09-25): `kernel/step5/`, the timer, under
mini-qemu and QEMU the same. The BCM2835's system timer (compare 3, as
xv6 arm-pi1) every 10ms on IRQ 3; the IRQ taken from user mode only
(the kernel runs with IRQs masked, so an interrupt never lands in the
kernel or the collector); with nothing to run, the scheduler waits with
`wfi`, IRQs still masked (a pending interrupt ends it anyway), and
handles the tick itself. A tick wakes the sleepers whose time has come
and preempts the running process (xv6's yield); `sleep(n)` is n ticks,
`kill` marks a process, which dies on its way back to user mode.
`user.s`: process 1 spins without a system call (only preemption lets
the others run), process 2 sleeps 5 ticks then kills it, process 3
runs three rounds 2 ticks apart; the order of their lines depends on
tick counts only (the same under QEMU's clock, which follows the
host's time, and mini-qemu's, which follows the instructions), 7 ticks
in all.

The ladder is done: OCaml bare-metal, a trap, processes and the
collector, the MMU, the timer. Next: `kernel/xv6/`, mini-xv6 itself.

**mini-xv6 done** (2026-09-25): `kernel/xv6/`, xv6 in OCaml, running xv6
arm-pi1's own user programs from its own `fs.img` (linked into the
kernel, xv6's RAM disk): init, sh, the utilities and **usertests, all
of them passing** under QEMU (9s) and mini-qemu (`make
usertests-mini`: 2,439s, 41 minutes, the transcript the C kernel's). A
shell session (ls, cat, echo, mkdir, ln, wc, rm, grep, forktest, a
failing cat, sh -c) prints **byte for byte what xv6's C kernel prints**
under mini-qemu and QEMU (`kernel/xv6/expected`, made from the C
kernel by `make expected`); usertests' transcript is the C kernel's
too, the same pids and lines, but for timing (validatetest's race
between a child's fault and its parent's kill) and where memory runs
out (`allocuvm out of memory`: the C kernel has 128MB, mini-xv6 192MB).
`make check` (in `kernel/test.sh`, so `make test-pi`); `mini-pi
mini-xv6` boots it.

The modules, in dependency order, each with its `.mli` (the
documentation), 956 lines of OCaml without comments or blank lines:

| module | xv6 | lines |
| --- | --- | --- |
| Types | the headers' structs (proc.h, file.h) as variants and records | 40 |
| Machine | machine.c's primitives; C's bytes (le16, le32) | 44 |
| Mmu | kalloc.c, vm.c: pages, spaces, the user's bytes | 122 |
| Proc | proc.c: the table, sleep and wakeup, the scheduler | 55 |
| Fs | fs.c, and sysfile.c's create, link, unlink | 237 |
| File | file.c, pipe.c, console.c | 132 |
| Exec | exec.c | 75 |
| Syscall | syscall.c, sysproc.c, sysfile.c, fork/exit/wait | 193 |
| Main | trap.c, main.c | 58 |

and in C and assembly the machine: `machine.c` (222: the primitives,
the kernel stacks' switch and the collector's view of them) and
`start.s` (198: the boot, the tables, the vectors), plus `libc.c` (206)
for the runtime. xv6 arm-pi1's kernel is 4,286 lines of C and assembly
(USB keyboard and framebuffer console included); tiny-os v6, xv6
simplified in C, about 2,600.

What xv6 has and mini-xv6 does not, and why:

- **No locks**: one core, and a kernel never interrupted (IRQs arrive
  in user mode only: step 5); a check and the sleep after it cannot be
  separated by a wakeup, so sleep needs no lock to release.
- **No buffer cache** (bio.c): the disk is RAM; a block is its address.
  An inode's fields are read and written on the disk too (`Fs.get`,
  `Fs.set` over a `field` view): no in-memory copy, no I_VALID, no
  iupdate. What stays in memory is what the disk cannot say: the
  inodes in use and their references (NINODE of them, as xv6).
- **No log** (log.c): a RAM disk is lost whole with the machine, never
  half written; filewrite's chunking for the log's size goes with it.
- **No initcode**: the kernel execs /init itself in the first
  process's start.
- **Bytes cross as strings**: a read returns what it read and the
  system call copies it to the user; xv6 reads and writes the user's
  memory in place. A negative count is refused (-1); xv6's result
  depends on the file.
- ^P's process listing is not done. The fault message is xv6's up to
  the user's CPSR, then the fault's address (not xv6's kernel CPSR and
  IFAR).

Found on the way:

- **xv6 arm-pi1's C kernel panics on `>`**: "write outside of trans".
  The O_TRUNC its sys_open was given (for the shared sh.c) calls itrunc
  outside a log transaction, so any redirection kills it (in ~/xv6, left
  untouched; the comparison session avoids `>`, mini-xv6's own run of it
  works).
- **A word from the user is not an int**: an argument, read as 32 bits,
  may not fit OCaml's 31. `Machine.get_le32` keeps the words from -1GB
  to 1GB exact and makes the others max_int, which every bound refuses
  (an address 0x80001000 must not alias 0x1000).
- OCaml 1.07 has no or-patterns binding variables (`Inode_file ip |
  Device (ip, _)`).
- xv6 runs user mode with FIQs unmasked (userinit's spsr 0x10): the
  fault message showed it (0x60000010), and mini-xv6 now does the same.

**Two boards, one xv6** (2026-09-25): the same kernel on the Pi4,
`make BOARD=pi4` (`mini-pi mini-xv6-pi1`, `mini-xv6-pi4`). The author:
handle arm64 "just like for the assembler, linker, compiler, we handle
the 2 archs", which "would force to make the code more portable and less
architecture specific, finding the right arch abstraction"; and, the
two xv6 ports being different xv6s (arm-pi1 descends from x86's xv6,
arm64-pi4 from xv6-riscv), "one of the goal in xv6-multiarch was to
gradually merge all those forks in a single codebase ... of course
having arch specific part, but trying to merge things", with
"xv6-riscv modern semantic".

So the kernel is written once, and what differs is the board's:

- `kernel/xv6/*.ml` (1,036 lines of OCaml, comments and blank lines
  left out), `runtime.c` (136: the processes' kernel side, the
  collector's view of their stacks, the calls into OCaml), `libc.c`
  (209): the same on both.
- `pi1/`, `pi4/`: `Arch.ml` (27, 39 lines) behind one `Arch.mli`, and
  the machine: `machine.c` (112, 134), `start.s` (198, 231), `board.h`,
  `kernel.ld`.

`Arch` holds what the machines really differ in, and no more: a
translation table's levels and how an entry says "a table" or "a page"
(Mmu is one radix walk over them: the Pi1's 2 levels of ARMv6
descriptors, the Pi4's 3 of ARMv8's); the trap frame's pc, sp and
system call number; where the arguments are (the Pi1's user stub
pushes them on its stack, the Pi4's are in x0-x5); the ELF class; a
user word's size, and C's int and uint of a register (identities on
the Pi1, whose OCaml ints are narrower than its words); the user's
address limit; the pages the processes get. What looked like a board's
parameter but is not: the block size (512 on arm-pi1's fs.img, 1024 on
arm64-pi4's), which Fs reads from the disk (where block 1's magic is).

**One semantics, xv6-riscv's**, for both, which is where the ports
differed (a list for xv6-multiarch's convergence):

| | arm-pi1 (x86 xv6's) | arm64-pi4, and mini-xv6 on both |
| --- | --- | --- |
| exit, wait | the status ignored | exit(status); wait(&status); a killed process exits -1 |
| the user's memory | checked against sz, read and written in place (the guard page too) | through its page table, the user's pages only (copyin, copyout, copyinstr), MAXPATH 128 |
| exec's stack | word-aligned, a fake return pc, r0 left argc | one page, 16-byte aligned, argc the result; the process named after the path's last element |
| read, write faults | the whole buffer checked first | a piece at a time: a pipe or the console stops where it got to, a file read is -1, a file write -1 after its full chunks |
| sbrk | the size an int | growproc's `uint`: a size wrapping below leaves it (sbrk8000) |
| the console | CR before LF, ^D echoed "^D", a raw LF dropped | as it is |
| a fault | `pid N name: trap 4 ... --kill proc` | `usertrap(): unexpected ec %p %p pid=%d` then elr, far (the Pi1 says it as arm64 does: class 0x24 or 0x20, its FSR as the syndrome) |
| readi past the end | -1 | 0 |

**Checked**, each board against its port's C kernel (`make check`, in
`kernel/test.sh`):

- the Pi1: the shell session byte for byte as arm-pi1's C kernel under
  mini-qemu and QEMU, and usertests (arm-pi1's, 29 tests) passing under
  QEMU and mini-qemu (3,454s, sharing the CPU with the Pi4's run) with
  the new semantics, the transcript the C kernel's;
- the Pi4: the session byte for byte as arm64-pi4's C kernel under
  mini-qemu and QEMU, and **usertests (xv6-riscv's, 62 tests) passing**
  under QEMU (47s) and mini-qemu (638s), the transcript the C kernel's
  line for line but for the fault messages' status codes (a level 1
  permission fault where the C kernel reports a level 3 translation
  fault: it maps itself with pages, mini-xv6 with 1GB blocks) and pids
  after forkforkfork (which forks for as long as a race lets it).

**mini-qemu's arm64 got the scalar floating point** (machine/Arm64.ml):
the OCaml runtime computes with doubles (the collector's slices,
`float`), and arm64 has no soft-float. The forms the kernel uses, and
their neighbours: fadd, fsub, fmul, fdiv, fnmul, the multiply-adds,
fmov, fabs, fneg, fsqrt, fcvt, fcmp(e), fcsel, the conversions with the
integers, fmov of an immediate and with the core registers, the loads
and stores of s, d (singles and pairs) and q (a variadic function's
stores of v0-v7), movi, sshr and ushr of a d. On an aarch64 host
OCaml's float operations are these instructions, so natively they are
exact, NaNs included. Checked by `random_blocks.py -64fp` against this
machine's CPU (10,000 blocks, 0 differ; it found the multiply-add of
singles rounding twice, then its NaN taken from a factor before the
addend, both fixed) and `decode_check.py -64fp` against objdump (5,000
words, 0 differ).

Found on the way:

- **The Pi4's PL011 is off**: nothing enables it (the Pi1's firmware
  path did), and QEMU drops what a disabled one is sent: `board_init`
  sets CR first.
- **GCC vectorizes the runtime's C** (Advanced SIMD): the Pi4 build
  says `-fno-tree-vectorize`, and libc.c's `%d` reads an int, not a
  long (an int's register's upper half is undefined on arm64).
- **An interrupt ended at the GIC before OCaml runs**: the process may
  give up the CPU in the handler, and an interrupt left active would
  keep the scheduler's `wfi` from ever seeing the next tick.
- `Machine.le32` shifted logically: on the Pi1, -1 became `ff ff ff
  7f` (harmless as exec's fake return pc; a wait status of -1 needs it
  right).
- ocaml-light's arm32 build takes Int64's C type from the aarch64 host
  (`long`, 32 bits on the target): the Pi1 uses no Int64
  ([`plan_bugs_ocaml_light.md`](../plan_bugs_ocaml_light.md), issue 4);
  the fault's registers cross from C formatted.
- **make's built-in rules deleted ~/xv6/forks/arm64-pi4/fs.img**: its
  `fs.img.o` (newer) matched the `%: %.o` rule, make tried to "rebuild"
  the image, and the failed link removed it. Restored from `fs.img.o`'s
  data (`objcopy -O binary -j .data`), byte for byte the copy linked
  into the port's own kernel, its mtime put back before `fs.img.o`'s;
  the Makefile now has no built-in rules and an empty rule for the
  source image. A lesson for any Makefile that names files it must not
  build.

xv6 arm64-pi4's kernel is 4,562 lines of C and assembly; mini-xv6's,
for both boards, 1,036 of OCaml, 66 of Arch, and 345 of shared C with
318 (Pi1) and 374 (Pi4) of the board's C and assembly.

**The console on the screen** (2026-09-25): mini-xv6 draws its console
on the framebuffer, on both boards (`Screen.ml`, 49 lines): xv6
arm-pi1's `gpuputc` and `initframebuf` pixel for pixel -- 1024 x 768 x
16 bits asked on the mailbox's channel 1 (machine.c's `fb_init`, the
request by the board's VideoCore alias, 0x40000000 or 0xC0000000), a
character an 8 x 16 cell of arm-pi1's font (`font1.bin`, embedded as
fs.img is), 15 rows drawn white on black, the screen scrolled a row at
the bottom. Everything the console prints goes there too
(`Machine.screen`). `make check` takes a screendump after the session
(`session.py --screendump`, QMP): the screen is the same under
mini-qemu and QEMU on both boards, and on the Pi1 **the same as xv6
arm-pi1's C kernel's** (`expected-pi1.ppm.gz`, 15KB, made by `make
expected`: the session scrolls both kernels' differing boot lines off).
The Pi1's boot now maps all 512MB (QEMU's framebuffer is at 0x1c100000,
above the 448MB it mapped); libc's memmove copies a word at a time
when it can (a scroll moves 1.5MB). `mini-pi -g mini-xv6-pi1` (or
`-pi4`) shows it in a window, the input still the terminal's.

**A USB keyboard and mouse** (2026-09-25; the author: "the keyboard in
the graphics window does not seem to work ... let's add usb keyboard
for mini-xv6, and a mouse"). Both boards have the DWC2 controller (the
Pi1's only one; the Pi4's second, QEMU's raspi4b models it, its own
ports being on the xHCI), so one driver:

- `usb.c` (58 lines, shared): the controller's two operations, the host
  started (the root port powered and reset) and one transfer on channel
  0 polled to its end through a DMA page -- in C because DWC2's
  registers use bits 31 and 30, past the Pi1's OCaml ints;
- `Usbhost.ml` (127 lines): the protocol, as CSUD finds its keyboard,
  simpler: the hub on the root port (QEMU puts one there) given an
  address and configured, each of its ports powered and reset, each
  device's configuration read for a boot HID interface (a keyboard, a
  mouse) and its interrupt endpoint, the device set up (address,
  configuration, boot protocol, idle 0). Everything polled: at each
  tick, each device's interrupt endpoint read (a NAK: nothing new; the
  kernel is never interrupted, so polling is its style). The keyboard's
  keys newly down are the console's input, as the UART's characters are
  (`File.intr`: a US layout, Shift, Control); the mouse moves the
  screen's cursor (`Screen.pointer`: an arrow drawn by inverting the
  pixels under it, hidden while the console draws). No mouse device
  file: xv6's userland has no reader for one, nor a mknod.

`make check` types a session on the USB keyboard and moves the mouse
(`session.py --usb --move`: QMP's send-key and input-send-event): its
text the same as on the serial line, its screen the same under
mini-qemu and QEMU, on both boards. `mini-pi -g mini-xv6-pi1` (or
`-pi4`) attaches both: type in the window.

Found on the way:

- **mini-qemu's Pi1 lost its timer** in an idle kernel: a WFI set a flag
  and the batch went on; the time skipped at the batch's end could fall
  between mini-xv6's tick reading the counter and writing the next
  compare, which was then already past: no tick ever again (after some
  seconds idle; the tests kept the CPU busy or finished first). Now a
  WFI ends the batch where it is (plan_pi.md).
- **QEMU's QMP serves one client** (`-qmp unix:...,server,nowait`), and
  takes no second one after the first closes: session.py's screendump,
  on a connection of its own after the keys', waited forever under QEMU
  (mini-qemu accepts any number). One connection a session.
- The SETUP packet: the request packed as bmRequestType << 8 |
  bRequest must go out bmRequestType first, its direction bit 15.
- OCaml 1.07: no labeled arguments (again), no negative number
  patterns, no `include` in a structure; and an `if ... then match`
  swallowing the outer match's last case (a Match_failure on the Pi4).
